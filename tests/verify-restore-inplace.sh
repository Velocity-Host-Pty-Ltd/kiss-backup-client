#!/usr/bin/env bash
#
# verify-restore-inplace.sh
# -------------------------
# Drives the REAL engine `restore-unit` against a throwaway local restic repo with a stub
# adapter, unprivileged, in a temp dir. Asserts the in-place restore (architecture §2.2):
#   - mirror: a deleted file comes back, a modified one is rolled back, an extra is deleted;
#   - --delete stays inside the unit — a sibling account's new file survives;
#   - merge keeps extras; the dry run changes nothing;
#   - a safety snapshot (tag pre-restore) is taken unless --no-safety-snapshot;
#   - a unit path that is a whole backup root is refused;
#   - a repo failure leaves <unit>.failed; the next good restore clears it.
#
# Needs restic (RESTIC_BIN=/path/to/restic, default: restic on PATH).
# Usage:  bash tests/verify-restore-inplace.sh
#
# shellcheck disable=SC2015  # ok/bad always return 0
set -uo pipefail

HERE="$(cd "$(dirname "$0")/.." && pwd)"
RBIN="${RESTIC_BIN:-$(command -v restic)}"
[ -x "$RBIN" ] || { echo "restic not found — set RESTIC_BIN" >&2; exit 2; }
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail=0
ok()  { printf 'PASS  %s\n' "$1"; }
bad() { printf 'FAIL  %s\n' "$1"; fail=1; }

B="$T/box"
mkdir -p "$B/home/u1/sub" "$B/home/u2" "$B/etc" "$T/cfg" "$T/adapters/stub"
echo a > "$B/home/u1/a"; echo b > "$B/home/u1/b"; echo c > "$B/home/u1/sub/c"
echo x > "$B/home/u2/x"; echo e > "$B/etc/e"; echo t > "$T/pass"
ln -s "$HERE/adapters/lib" "$T/adapters/lib"

cat > "$T/failrestic" <<EOF
#!/bin/sh
case " \$* " in *" restore "*) case " \$* " in *" --dry-run "*) ;; *) echo "Fatal: connection lost" >&2; exit 1 ;; esac ;; esac
exec "$RBIN" "\$@"
EOF
chmod +x "$T/failrestic"

env_file() { cat > "$T/cfg/backup.env" <<EOF
BACKUP_REPO=$T/repo
BACKUP_PASSFILE=$T/pass
RESTIC_BIN=$1
BACKUP_PATHS="$B/home $B/etc"
ADAPTER=stub
BACKUP_RESTORE_ROOT=$T/rr/restore
BACKUP_RESTORE_STATE=$T/rr/status
BACKUP_LOCK=$T/rr/lock
BACKUP_DB_DUMP_DIR=$T/dumps
NOTIFY_BIN=/bin/true
BACKUP_RESTORE_ATTEMPTS=1
EOF
}
env_file "$RBIN"; mkdir -p "$T/rr"

cat > "$T/adapters/stub/adapter" <<'EOF'
#!/usr/bin/env bash
set -u
err() { printf '%s\n' "$*" >&2; }
die() { local rc="$1"; shift; err "$*"; exit "$rc"; }
B="$STUB_BOX"
. "$(dirname "$(readlink -f "$0")")/../lib/restore_common.sh"
allowed_roots() { printf '%s\n' "$B/home/$1"; }
v_owner_for_unit() { printf '%s:%s\n' "$(id -u)" "$(id -g)"; }
case "$1" in
  info) echo '{"adapter":"stub","contract":"1","capabilities":["owner-for-unit"],"default_restore_mode":"merge"}' ;;
  list-units) printf 'u1\tu1\tuser\nu2\tu2\tuser\nroot\troot\tuser\n' ;;
  paths-for-unit) if [ "$2" = root ]; then printf '%s\n' "$B/home"; else printf '%s\n' "$B/home/$2"; fi ;;
  dbs-for-unit) : ;;
  owner-for-unit) v_owner_for_unit "$2" ;;
  restore-unit) md="$(rc_mode "$3")" || exit $?; read -r _mode dry <<<"$md"; rc_remap_owner "$2" "$3" "$dry" ;;
esac
EOF
chmod +x "$T/adapters/stub/adapter"

export KBC_CONFIG_DIR="$T/cfg" KBC_ADAPTER_DIR="$T/adapters" STUB_BOX="$B" RESTIC_CACHE_DIR="$T/cache"
E="$HERE/engine/restic_backup.sh"
R() { "$RBIN" -r "$T/repo" -p "$T/pass" "$@"; }

R init -q >/dev/null && R backup -q "$B/home" "$B/etc" >/dev/null || { echo "repo setup failed" >&2; exit 2; }

perturb() { rm -f "$B/home/u1/a"; echo CHANGED > "$B/home/u1/b"; echo n > "$B/home/u1/new"; echo n2 > "$B/home/u2/new2"; }
perturb

"$E" restore-unit u1 --mirror --dry-run > "$T/out" 2>&1
[ ! -e "$B/home/u1/a" ] && [ -e "$B/home/u1/new" ] && grep -q '^.*deleted .*/home/u1/new' "$T/out" \
    && ok "dry run previews the delete, changes nothing" || bad "dry run: $(tail -5 "$T/out")"

"$E" restore-unit u1 --mirror --yes > "$T/out" 2>&1
[ -e "$B/home/u1/a" ] && [ "$(cat "$B/home/u1/b")" = b ] && [ ! -e "$B/home/u1/new" ] \
    && ok "mirror: deleted file back, change rolled back, extra removed" || bad "mirror: $(tail -5 "$T/out")"
[ -e "$B/home/u2/new2" ] && [ -e "$B/etc/e" ] && ok "--delete stayed inside u1" || bad "--delete reached outside u1"
R snapshots --compact --tag pre-restore 2>/dev/null | grep -q pre-restore \
    && ok "safety snapshot taken" || bad "no pre-restore snapshot"
[ -z "$(find "$T/rr/restore" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)" ] \
    && ok "no workdir left behind" || bad "workdir left: $(ls "$T/rr/restore")"

perturb
n="$(R snapshots --compact --tag pre-restore 2>/dev/null | grep -c pre-restore)"
"$E" restore-unit u1 --merge --yes --no-safety-snapshot > "$T/out" 2>&1
[ -e "$B/home/u1/a" ] && [ -e "$B/home/u1/new" ] && ok "merge keeps extras" || bad "merge: $(tail -5 "$T/out")"
[ "$(R snapshots --compact --tag pre-restore 2>/dev/null | grep -c pre-restore)" = "$n" ] \
    && ok "--no-safety-snapshot skips it" || bad "safety snapshot taken despite --no-safety-snapshot"

"$E" restore-unit root --mirror --dry-run > "$T/out" 2>&1 \
    && bad "whole-root unit path accepted" || { grep -q "whole backup root" "$T/out" && ok "whole-root unit path refused"; }

# Checkpoints + restore points (headless "a checkpoint is a checkpoint").
"$E" restore-unit u1 --mirror --yes --no-safety-snapshot > /dev/null 2>&1      # u1 back to the backup
"$E" checkpoint u1 --kind files --label pre-change > "$T/out" 2>&1
ck="$(sed -n 's/.*checkpoint saved: \([0-9a-f]\{8\}\).*/\1/p' "$T/out")"
[ -n "$ck" ] && ok "checkpoint saved ($ck)" || bad "checkpoint: $(tail -3 "$T/out")"
"$E" checkpoint u2 --kind files --label other-account > /dev/null 2>&1
"$E" points u1 files > "$T/pts" 2>&1
grep -q "^$ck	.*checkpoint	pre-change$" "$T/pts" && ok "points lists the checkpoint with its label" || bad "points: $(cat "$T/pts")"
grep -q "other-account" "$T/pts" && bad "points shows another account's checkpoint" || ok "another account's checkpoint is not listed"
grep -q "scheduled backup" "$T/pts" && ok "points lists the scheduled backups too" || bad "no scheduled backups in points"
[ "$(head -1 "$T/pts" | cut -f1)" = "$ck" ] && ok "newest first" || bad "order: $(head -2 "$T/pts")"
echo damaged > "$B/home/u1/b"; echo x > "$B/home/u1/after-ckpt"
"$E" restore-unit u1 --snapshot "$ck" --mirror --yes --no-safety-snapshot > "$T/out" 2>&1
[ "$(cat "$B/home/u1/b")" = b ] && [ ! -e "$B/home/u1/after-ckpt" ] \
    && ok "restore from the checkpoint (mirror)" || bad "checkpoint restore: $(tail -4 "$T/out")"
"$E" restore-unit u1 --mirror --yes > /dev/null 2>&1
"$E" points u1 files | grep -q "safety copy" && ok "a restore's safety copy is a restore point" || bad "safety copy not in points"

env_file "$T/failrestic"
"$E" restore-unit u1 --merge --yes --no-safety-snapshot > "$T/out" 2>&1 \
    && bad "failing repo reported success" || { [ -s "$T/rr/status/u1.failed" ] && ok "repo failure → u1.failed"; } \
    || bad "no failure marker: $(tail -3 "$T/out")"
env_file "$RBIN"
"$E" restore-unit u1 --merge --yes --no-safety-snapshot > "$T/out" 2>&1
[ ! -e "$T/rr/status/u1.failed" ] && ok "good restore clears the marker" || bad "marker not cleared"

exit "$fail"
