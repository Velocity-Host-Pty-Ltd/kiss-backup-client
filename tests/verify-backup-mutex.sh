#!/usr/bin/env bash
#
# verify-backup-mutex.sh
# ----------------------
# Proves the cross-engine backup/restore mutex (/run/lock/vps-backup.lock) that keeps a
# scheduled backup from snapshotting a half-restored DB/docroot:
#   * while an op holds the lock, a SCHEDULED op (restic_backup_v1.sh) DEFERS — exit 0,
#     logs "deferred", and does NO work (it bails before any mysqldump/restic),
#   * an OPERATOR op (backup_ondemand_v1.sh) WAITS its short window then REFUSES (non-zero)
#     rather than running into the held lock,
#   * the lock frees once the holder exits.
#
# SAFE: holds the lock with a throwaway `sleep` (no backup runs), and only exercises the
# engines' DEFER / REFUSE fast-paths — both bail BEFORE touching any data. Run as root on a
# test box. Idempotent; leaves only the (0-byte, advisory) lock file under /run/lock.
#
# Usage:  sudo bash verify-backup-mutex.sh [account]      # default account: test4
#
set -uo pipefail

LOCK="${BACKUP_LOCK:-/run/lock/vps-backup.lock}"
SCHED="${SCHED:-/usr/local/bin/vps-tooling/restic_backup_v1.sh}"
OND="${OND:-/usr/local/bin/vps-tooling/backup_ondemand_v1.sh}"
ACCOUNT="${1:-test4}"
HOLD=10

PASS=0; FAIL=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }
command -v flock >/dev/null 2>&1 || { echo "flock not found (mutex can't be tested)" >&2; exit 1; }
[ -x "$SCHED" ] || { echo "scheduled engine missing: $SCHED" >&2; exit 1; }
[ -x "$OND" ]   || { echo "on-demand engine missing: $OND" >&2; exit 1; }

echo "=== holding the mutex for ${HOLD}s (simulated in-progress op) ==="
flock -n "$LOCK" -c "sleep $HOLD" &
HOLDER=$!
sleep 0.5

echo "--- scheduled op should DEFER (exit 0, 'deferred', no work) ---"
out="$("$SCHED" db-dump 2>&1)"; rc=$?
printf '%s\n' "$out" | tail -3
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qi deferred; } \
    && ok "scheduled db-dump deferred while the lock was held" \
    || bad "scheduled db-dump did NOT defer cleanly (rc=$rc)"

echo "--- operator op should WAIT then REFUSE (non-zero) ---"
t0=$SECONDS
out="$(ONDEMAND_LOCK_WAIT=2 "$OND" checkpoint "$ACCOUNT" --kind db 2>&1)"; rc=$?
dt=$((SECONDS - t0))
printf '%s\n' "$out" | tail -2
{ [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "in progress"; } \
    && ok "operator checkpoint refused after waiting (~${dt}s, rc=$rc)" \
    || bad "operator checkpoint did NOT refuse on a held lock (rc=$rc)"

wait "$HOLDER" 2>/dev/null || true
echo "--- lock should now be FREE ---"
flock -n "$LOCK" -c true && ok "mutex released after the holder exited" || bad "mutex still held after holder exit"

printf '\n========== RESULT: %d passed, %d failed ==========\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
