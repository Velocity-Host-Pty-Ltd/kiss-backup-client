#!/usr/bin/env bash
#
# da-cagefs-test.sh — restore of a caged (CloudLinux CageFS) DirectAdmin account
# Project: KISS-Backup-Client
# Summary: Proves a restore works for an account inside CageFS, seen from INSIDE the cage:
#     1. installs + initialises CageFS if it isn't (dnf install cagefs; cagefsctl --init —
#        builds the shared skeleton, takes a few minutes);
#     2. creates the test account if missing (tests/da-make-test-user.sh) and cages it;
#     3. backs up; changes the marker file (v2) and plants a file;
#     4. restores the account's files (mirror, CLI);
#     5. checks as the user inside the cage (cagefs_enter_user): marker back to v1, planted
#        file gone; and the cage itself still works (the user's view isn't broken);
#     6. runs tests/da-mail-restore-test.sh, whose CageFS check now applies.
#   Prints PASS/FAIL. CloudLinux + DirectAdmin TEST BOXES ONLY — installs CageFS.
#   /var/cagefs (the per-user cage data) is not backed up: CageFS rebuilds it.
#
# Usage:  bash tests/da-cagefs-test.sh [user] [domain]       # default kbuser kbuser.test
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
U="${1:-kbuser}"; DOM="${2:-$U.test}"
DA=/usr/local/directadmin
F="/home/$U/domains/$DOM/public_html/kbtest.txt"
P="/home/$U/domains/$DOM/public_html/planted.php"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
grep -qi cloudlinux /etc/os-release 2>/dev/null || [ -e /etc/cloudlinux-release ] \
    || { echo "not CloudLinux — CageFS needs CloudLinux" >&2; exit 1; }

fail=0
step() { printf '\n== %s\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }

step "1. CageFS installed + initialised"
CFS="$(command -v cagefsctl || ls /usr/sbin/cagefsctl 2>/dev/null || true)"
if [ -z "$CFS" ]; then
    echo "installing cagefs ..."
    dnf -y -q install cagefs || { echo "dnf install cagefs failed (licence / repo?)" >&2; exit 1; }
    CFS="$(command -v cagefsctl || echo /usr/sbin/cagefsctl)"
fi
if [ ! -d /usr/share/cagefs-skeleton/bin ]; then
    echo "initialising CageFS (builds the skeleton — a few minutes) ..."
    "$CFS" --init >/root/cagefs-init.log 2>&1 || { echo "cagefsctl --init failed — see /root/cagefs-init.log" >&2; exit 1; }
fi
ok "CageFS ready ($(rpm -q cagefs))"
ENTER="$(command -v cagefs_enter_user || ls /sbin/cagefs_enter_user /bin/cagefs_enter_user 2>/dev/null | head -1)"
[ -n "$ENTER" ] || { echo "no cagefs_enter_user" >&2; exit 1; }

step "2. test account, caged"
[ -d "$DA/data/users/$U" ] || bash "$HERE/da-make-test-user.sh" "$U" "$DOM" >/dev/null \
    || { echo "could not create $U" >&2; exit 1; }
"$CFS" --enable "$U" >/dev/null 2>&1
"$CFS" --list-enabled 2>/dev/null | grep -qx "$U" && ok "$U is caged" || bad "$U not in cagefsctl --list-enabled"
inside() { "$ENTER" "$U" "$@" 2>/dev/null; }
[ "$(inside cat "$F")" = v1 ] && ok "inside the cage $U sees kbtest.txt = v1" || bad "inside the cage: '$(inside cat "$F")'"

step "3. backup, then damage"
systemctl start kiss-backup.service && ok "backup taken" || bad "kiss-backup.service failed"
echo v2 > "$F"; echo '<?php // planted' > "$P"; chown "$U:$U" "$F" "$P"
echo "kbtest.txt -> v2, planted.php added"

step "4. restore $U's files (mirror)"
kiss-backup restore-unit "$U" --files-only --mirror --yes > /root/cagefs-test-restore.log 2>&1
tail -3 /root/cagefs-test-restore.log
grep -q "restore of $U done" /root/cagefs-test-restore.log && ok "restore finished" || bad "restore failed (see /root/cagefs-test-restore.log)"

step "5. checks from inside the cage"
"$CFS" --list-enabled 2>/dev/null | grep -qx "$U" && ok "$U still caged after the restore" || bad "$U no longer caged"
[ "$(inside cat "$F")" = v1 ] && ok "inside the cage kbtest.txt is back to v1" || bad "inside the cage kbtest.txt: '$(inside cat "$F")'"
inside test -e "$P" && bad "planted.php still visible inside the cage" || ok "planted.php gone (inside the cage too)"
inside ls / >/dev/null && ok "the cage still works (user can list its /)" || bad "cagefs_enter_user $U failed after the restore"

step "6. mail test (with the CageFS check)"
bash "$HERE/da-mail-restore-test.sh" "$U" "$DOM" | sed 's/^/    /'
[ "${PIPESTATUS[0]}" -eq 0 ] && ok "mail test ALL PASSED" || bad "mail test had failures (above)"

printf '\n%s\n' "$([ "$fail" -eq 0 ] && echo 'ALL PASSED' || echo 'SOME CHECKS FAILED')"
echo "Clean up afterwards with:  bash tests/da-cleanup-test-data.sh"
exit "$fail"
