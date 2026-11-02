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
#   MYSQL_BIN                     mysql client (root via unix_socket)
#
# Workdir (from the engine): <wd>/paths (the paths restored in place), <wd>/dbs/<db>.sql,
#   <wd>/idmap ("u|g <old-id> <new-id> <name>" per user/group whose id moved since the backup).
# Env: KBC_DRY_RUN=1 (show only), KBC_RESTORE_MODE=merge|mirror.

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

# Restored files carry their backup-time numeric ids. Where a user or group's id moved since
# (re-created account, rebuilt server — the engine's <wd>/idmap, matched by name), re-own the
# restored files that carry an old id. One pass per path, each file mapped from its ORIGINAL
# ids, so chained moves (A->B, B->C) can't double-map. Files whose ids didn't move (other
# owners, root) are untouched. Normally the map is empty and this is a no-op.
rc_remap_owner() {
    local u="$1" wd="$2" dry="$3" kind old new p fu fg f nu ng cnt=0
    local -A um=() gm=()
    [ -s "$wd/idmap" ] || return 0
    local -a expr=()
    while read -r kind old new _; do
        [[ "$old$new" =~ ^[0-9]+$ ]] && [ "$old" != 0 ] && [ "$new" != 0 ] || continue
        if [ "$kind" = u ]; then um[$old]="$new"; expr+=(-o -uid "$old")
        elif [ "$kind" = g ]; then gm[$old]="$new"; expr+=(-o -gid "$old"); fi
    done < "$wd/idmap"
    [ "${#expr[@]}" -gt 0 ] || return 0
    expr=("${expr[@]:1}")                       # drop the leading -o
    # Dry run: nothing is restored yet, so there is nothing to count — the engine's
    # preview already lists each moved id.
    [ "$dry" = 1 ] && { err "owner: $(wc -l < "$wd/idmap") id change(s) would be applied to the restored files"; return 0; }
    while IFS= read -r p; do
        [ -e "$p" ] || continue
        while IFS= read -r -d '' fu && IFS= read -r -d '' fg && IFS= read -r -d '' f; do
            nu="${um[$fu]:-$fu}"; ng="${gm[$fg]:-$fg}"
            [ "$nu:$ng" = "$fu:$fg" ] && continue
            cnt=$((cnt + 1))
            chown -h "$nu:$ng" "$f" || die 3 "chown $f failed"
        done < <(find "$p" -xdev \( "${expr[@]}" \) -printf '%U\0%G\0%p\0')
    done < <(rc_staged_paths "$u" "$wd" 2>/dev/null)
    err "owner: $cnt restored file(s) re-owned to today's ids"
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
