#!/usr/bin/env bash
#
# verify-restore-owner-remap.sh
# -----------------------------
# Unit check for adapters/lib/restore_common.sh rc_remap_owner: given the engine's
# <wd>/idmap (user/group ids that moved since the backup, matched by name), only the
# restored files carrying an old id are re-owned, only inside the unit's areas; an empty
# map, a dry run and a root entry change nothing.
#
# Runs unprivileged: chown is replaced by a logging stub on PATH. The real chown is proven
# on a test box by a restore after re-creating the account (tests/da-uid-recreate-test.sh).
#
# Usage:  bash tests/verify-restore-owner-remap.sh
#
# shellcheck disable=SC2015  # ok/bad always return 0
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

mkdir -p "$T/bin"
printf '#!/bin/sh\necho "chown $*" >> "%s/log"\n' "$T" > "$T/bin/chown"; chmod +x "$T/bin/chown"

U="$(id -u)"; G="$(id -g)"
run() {   # run <dry> <idmap lines...>
    local dry="$1"; shift
    : > "$T/log"; printf '%s\n' "$@" | sed '/^$/d' > "$T/wd/idmap"
    PATH="$T/bin:$PATH" DRY="$dry" WD="$T/wd" LIVE="$T/live" bash -c '
        err() { printf "%s\n" "$*" >&2; }
        die() { shift; err "$*"; exit 3; }
        allowed_roots() { printf "%s\n" "$LIVE/home/u1"; }
        . "'"$HERE"'/../adapters/lib/restore_common.sh"
        rc_remap_owner u1 "$WD" "$DRY"' 2> "$T/err"
}

mkdir -p "$T/wd" "$T/live/home/u1/sub" "$T/live/etc/elsewhere"
touch "$T/live/home/u1/a" "$T/live/home/u1/sub/b" "$T/live/etc/elsewhere/x"
printf '%s\n' "$T/live/home/u1" "$T/live/etc/elsewhere" > "$T/wd/paths"

run 0 ""
[ ! -s "$T/log" ] && ok "empty map → no chown" || bad "empty map chowned: $(cat "$T/log")"

run 1 "u $U 4242 u1" "g $G 4343 u1"
[ ! -s "$T/log" ] && grep -q "would be applied" "$T/err" \
    && ok "dry run reports, changes nothing" || bad "dry run: $(cat "$T/log" "$T/err")"

run 0 "u $U 4242 u1" "g $G 4343 u1"
n="$(grep -c "^chown -h 4242:4343 " "$T/log")"
[ "$n" = 4 ] && ok "user + group moved → all 4 restored entries re-owned" || bad "remap ($n): $(cat "$T/log" "$T/err")"
grep -q elsewhere "$T/log" && bad "touched a path outside the unit's areas" || ok "outside paths untouched"

run 0 "g $G 4343 access"
grep -q "^chown -h $U:4343 " "$T/log" && ! grep -qv "^chown -h $U:4343 " "$T/log" \
    && ok "group-only move keeps the uid" || bad "group-only: $(cat "$T/log")"

run 0 "u 999999 4242 other"
[ ! -s "$T/log" ] && ok "a moved id no file carries → nothing" || bad "unrelated id: $(cat "$T/log")"

run 0 "u 0 4242 root" "u $U 0 x"
[ ! -s "$T/log" ] && ok "root entries ignored" || bad "root: $(cat "$T/log")"

exit "$fail"
