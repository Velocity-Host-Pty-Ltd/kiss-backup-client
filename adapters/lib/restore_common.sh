# shellcheck shell=bash
#
# restore_common.sh — shared restore-unit helpers for Layer-2 adapters
# Project: KISS-Backup-Client
# Summary: The file-sync and DB-import halves of `restore-unit` (docs/architecture.md
#   §2.2), shared so every adapter restores the same safe way. Sourced by
#   adapters/<name>/adapter; never by the engine (Layer 1 only execs adapters).
#
# The adapter supplies:
#   err "msg"                     print a diagnostic to stderr
#   die <rc> "msg"                print + exit
#   allowed_roots <unit> <wd>     the absolute areas this unit may restore into
#   v_owner_for_unit <unit>       the account's current uid:gid
#   MYSQL_BIN                     mysql client (root via unix_socket)
#
# Workdir layout (staged by the engine): <wd>/files/<abs path>, <wd>/paths, <wd>/dbs/<db>.sql.
# Env: KBC_DRY_RUN=1 (show only), KBC_RESTORE_MODE=merge|mirror.

# The staged paths (<wd>/paths) that fall inside one of the unit's areas — never
# through '..', never outside, so a crafted workdir can't widen a restore.
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

# Restored files carry the backup-time numeric uid/gid (--numeric-ids). If the account
# was re-created since with a new uid/gid, hand the staged copies that belonged to the old
# owner to the current one — only those ids, so mail:mail / diradmin / root files keep theirs.
# Done in the workdir, before the sync, so live files outside the restore are never touched.
rc_remap_owner() {
    local u="$1" wd="$2" dry="$3" first="" p cur ou og nu ng
    while IFS= read -r p; do
        [ -d "$wd/files$p" ] && { first="$p"; break; }
    done < <(rc_staged_paths "$u" "$wd" 2>/dev/null)
    [ -n "$first" ] || return 0
    cur="$(v_owner_for_unit "$u")" || die 3 "cannot resolve $u's current owner"
    nu="${cur%%:*}"; ng="${cur##*:}"
    ou="$(stat -c %u "$wd/files$first")"; og="$(stat -c %g "$wd/files$first")"
    [[ "$nu$ng$ou$og" =~ ^[0-9]+$ ]] || die 3 "bad owner ids for $u"
    [ "$ou:$og" = "$nu:$ng" ] && return 0
    if [ "$ou" = 0 ] || [ "$nu" = 0 ]; then
        err "owner: $first was $ou:$og in the backup, $u is $nu:$ng now — not remapping root"
        return 0
    fi
    if [ "$dry" = 1 ]; then
        err "owner: $u was $ou:$og in the backup, is $nu:$ng now — files would be handed over"
        return 0
    fi
    while IFS= read -r p; do
        [ -e "$wd/files$p" ] || continue
        [ "$ou" = "$nu" ] || find "$wd/files$p" -xdev -uid "$ou" -exec chown -h "$nu" {} + \
            || die 3 "chown in $p failed"
        [ "$og" = "$ng" ] || find "$wd/files$p" -xdev -gid "$og" -exec chgrp -h "$ng" {} + \
            || die 3 "chgrp in $p failed"
    done < <(rc_staged_paths "$u" "$wd" 2>/dev/null)
    err "owner: $u was $ou:$og in the backup, is $nu:$ng now — restored files handed over"
}

# Sync each staged path back onto itself (merge: overwrite from the snapshot, keep newer
# extras; mirror: --delete, exactly as it was). Never a blanket rsync onto /.
rc_restore_files() {
    local u="$1" wd="$2" mode="$3" dry="$4" p rel
    local -a rs=(-aHAX --numeric-ids)
    [ -d "$wd/files" ] || return 0
    rc_remap_owner "$u" "$wd" "$dry"
    [ "$dry" = 1 ] && rs+=(-n -i)
    [ "$mode" = mirror ] && rs+=(--delete)
    while IFS= read -r p; do
        [ -n "$p" ] || continue
        rel="$wd/files$p"
        [ -e "$rel" ] || continue
        if [ -d "$rel" ]; then
            mkdir -p "$p" 2>/dev/null || [ "$dry" = 1 ] || die 3 "cannot create $p"
            rsync "${rs[@]}" "$rel/" "$p/" || die 3 "rsync failed for $p"
        else
            rsync "${rs[@]}" "$rel" "$p" || die 3 "rsync failed for $p"
        fi
        if [ "$dry" = 1 ]; then err "files: $p would be restored ($mode)"; else err "files: $p restored ($mode)"; fi
    done < <(rc_staged_paths "$u" "$wd")
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
