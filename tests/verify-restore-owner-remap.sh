#!/usr/bin/env bash
#
# verify-restore-owner-remap.sh
# -----------------------------
# Unit check for adapters/lib/restore_common.sh rc_remap_owner: when the account's
# current uid:gid differs from its backup-time owner (KBC_BACKUP_OWNER, from the engine),
# only the restored files that carry the OLD ids are handed over (others — mail:mail, root — keep theirs),
# a dry run reports and changes nothing, and a same-owner or root case is a no-op.
#
# Runs unprivileged: chown/chgrp are replaced by logging stubs on PATH, and the "current"
# owner is faked by the stub v_owner_for_unit. The real chown is proven on a test box by a
# restore after re-creating the account (HANDOVER §14 step 6d).
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
for c in chown chgrp; do
    printf '#!/bin/sh\necho "%s $*" >> "%s/log"\n' "$c" "$T" > "$T/bin/$c"; chmod +x "$T/bin/$c"
done

ME="$(id -u):$(id -g)"
run() {   # run <current-owner> <dry>
    : > "$T/log"
    PATH="$T/bin:$PATH" CUR="$1" DRY="$2" WD="$T/wd" LIVE="$T/live" KBC_BACKUP_OWNER="$ME" bash -c '
        err() { printf "%s\n" "$*" >&2; }
        die() { shift; err "$*"; exit 3; }
        allowed_roots() { printf "%s\n" "$LIVE/home/u1"; }
        v_owner_for_unit() { printf "%s\n" "$CUR"; }
        . "'"$HERE"'/../adapters/lib/restore_common.sh"
        rc_remap_owner u1 "$WD" "$DRY"' 2> "$T/err"
}

mkdir -p "$T/wd" "$T/live/home/u1/sub" "$T/live/etc/elsewhere"
touch "$T/live/home/u1/a" "$T/live/home/u1/sub/b" "$T/live/etc/elsewhere/x"
printf '%s\n' "$T/live/home/u1" "$T/live/etc/elsewhere" > "$T/wd/paths"

run "$ME" 0
[ ! -s "$T/log" ] && ok "same owner → no chown" || bad "same owner chowned: $(cat "$T/log")"

run "4242:4343" 1
[ ! -s "$T/log" ] && grep -q "would be handed over" "$T/err" \
    && ok "dry run reports, changes nothing" || bad "dry run: $(cat "$T/log" "$T/err")"

run "4242:4343" 0
n="$(grep -c '^chown -h 4242 ' "$T/log")"; g="$(grep -c '^chgrp -h 4343 ' "$T/log")"
[ "$n" -ge 1 ] && [ "$g" -ge 1 ] && grep -q "handed over" "$T/err" \
    && ok "new owner → chown + chgrp of old-id files" || bad "remap: $(cat "$T/log" "$T/err")"
grep -q elsewhere "$T/log" && bad "touched a path outside the unit's areas" \
    || ok "outside paths untouched"

run "4242:$(id -g)" 0
grep -q '^chgrp' "$T/log" && bad "chgrp ran though gid unchanged" \
    || { grep -q '^chown' "$T/log" && ok "uid-only change → chown only"; } || bad "uid-only: $(cat "$T/log")"

run "0:0" 0
[ ! -s "$T/log" ] && grep -q "not remapping root" "$T/err" \
    && ok "root target → refused" || bad "root: $(cat "$T/log" "$T/err")"

exit "$fail"
