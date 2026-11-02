# shellcheck shell=bash
#
# restore_common.sh — shared restore-unit helpers for Layer-2 adapters
# Project: KISS-Backup-Client
# Summary: The post-restore half of `restore-unit` (docs/architecture.md §2.2): hand
#   restored files to a re-created account's new uid/gid, and import the staged DB
#   dumps. The engine has already put the files back in place (restic restore). Shared
#   so every adapter does it the same safe way. Sourced by adapters/<name>/adapter;
#   never by the engine (Layer 1 only execs adapters).
#
# The adapter supplies:
#   err "msg"                     print a diagnostic to stderr
#   die <rc> "msg"                print + exit
#   allowed_roots <unit> <wd>     the absolute areas this unit may restore into
#   v_owner_for_unit <unit>       the account's current uid:gid
#   MYSQL_BIN                     mysql client (root via unix_socket)
#
# Workdir (from the engine): <wd>/paths (the paths restored in place), <wd>/dbs/<db>.sql.
# Env: KBC_DRY_RUN=1 (show only), KBC_RESTORE_MODE=merge|mirror,
#      KBC_BACKUP_OWNER=<uid:gid> the unit's owner as recorded in the backup (may be empty).

# The restored paths (<wd>/paths) that fall inside one of the unit's areas — never
# through '..', never outside, so a crafted workdir can't widen the owner hand-over.
rc_staged_paths() {
    local u="$1" wd="$2" p a ok roots
    [ -r "$wd/paths" ] || return 0
    roots="$(allowed_roots "$u" "$wd")"
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        case "$p" in /*) ;; *) err "skipping non-absolute path $p"; continue ;; esac
        case "/$p/" in */../*|*/./*) err "skipping unsafe path $p"; continue ;; esac
        ok=0
        while IFS= read -r a; do
            [ -n "$a" ] || continue
            { [ "$p" = "$a" ] || [[ "$p" == "$a"/* ]]; } && { ok=1; break; }
        done <<< "$roots"
        if [ "$ok" -eq 1 ]; then printf '%s\n' "$p"; else err "skipping $p — outside $u's areas"; fi
    done < "$wd/paths"
}

# Restored files carry the backup-time numeric uid/gid (restic restores ids, as root). If
# the account was re-created since, or this is a rebuilt server, the current ids differ:
# hand the files that carry the OLD ids to the current ones — only those ids, so files
# owned by others (user:mail mail dirs, root, diradmin) keep theirs. Normally a no-op.
rc_remap_owner() {
    local u="$1" wd="$2" dry="$3" p cur ou og nu ng old="${KBC_BACKUP_OWNER:-}"
    [ -n "$old" ] || return 0
    cur="$(v_owner_for_unit "$u")" || die 3 "cannot resolve $u's current owner"
    nu="${cur%%:*}"; ng="${cur##*:}"; ou="${old%%:*}"; og="${old##*:}"
    [[ "$nu$ng$ou$og" =~ ^[0-9]+$ ]] || die 3 "bad owner ids for $u ($old -> $cur)"
    [ "$ou:$og" = "$nu:$ng" ] && return 0
    if [ "$ou" = 0 ] || [ "$nu" = 0 ]; then
        err "owner: $u was $ou:$og in the backup, is $nu:$ng now — not remapping root"
        return 0
    fi
    if [ "$dry" = 1 ]; then
        err "owner: $u was $ou:$og in the backup, is $nu:$ng now — files would be handed over"
        return 0
    fi
    while IFS= read -r p; do
        [ -e "$p" ] || continue
        [ "$ou" = "$nu" ] || find "$p" -xdev -uid "$ou" -exec chown -h "$nu" {} + \
            || die 3 "chown in $p failed"
        [ "$og" = "$ng" ] || find "$p" -xdev -gid "$og" -exec chgrp -h "$ng" {} + \
            || die 3 "chgrp in $p failed"
    done < <(rc_staged_paths "$u" "$wd" 2>/dev/null)
    err "owner: $u was $ou:$og in the backup, is $nu:$ng now — restored files handed over"
}

# A mysqldump that finished writes "-- Dump completed" as its last comment; a truncated
# or failed dump doesn't. Never drop or overwrite a live database from a partial dump.
rc_dump_complete() { tail -c 512 "$1" 2>/dev/null | grep -q -- '-- Dump completed'; }

# Import each staged dump whose name starts with <prefix>_ (the unit's ownership rule).
# mirror drops + recreates the DB first (grants survive — they live in mysql.db by name).
rc_restore_dbs() {
    local prefix="$1" wd="$2" mode="$3" dry="$4" f db
    [ -d "$wd/dbs" ] || return 0
    for f in "$wd"/dbs/*.sql; do
        [ -e "$f" ] || continue
        db="$(basename "$f" .sql)"
        if ! [[ "$db" == "${prefix}_"* && "$db" =~ ^[A-Za-z0-9_]+$ ]]; then
            err "skipping $db — not owned by $prefix"; continue
        fi
        if ! rc_dump_complete "$f"; then
            err "skipping $db — its dump is incomplete (no '-- Dump completed' trailer); live DB left as is"
            continue
        fi
        if [ "$dry" = 1 ]; then err "db: $db would be imported ($mode)"; continue; fi
        if [ "$mode" = mirror ]; then
            "$MYSQL_BIN" -e "DROP DATABASE IF EXISTS \`$db\`" || die 3 "drop $db failed"
        fi
        "$MYSQL_BIN" -e "CREATE DATABASE IF NOT EXISTS \`$db\`" || die 3 "create $db failed"
        "$MYSQL_BIN" "$db" < "$f" || die 3 "import $db failed"
        err "db: $db imported ($mode)"
    done
}

# Common restore-unit preamble: validate the workdir + mode. Echoes "<mode> <dry>".
rc_mode() {
    local wd="$1" mode="${KBC_RESTORE_MODE:-merge}" dry="${KBC_DRY_RUN:-0}"
    [ -d "$wd" ] || die 1 "workdir $wd not found"
    case "$mode" in merge|mirror) ;; *) die 1 "KBC_RESTORE_MODE must be merge or mirror" ;; esac
    printf '%s %s\n' "$mode" "$dry"
}
