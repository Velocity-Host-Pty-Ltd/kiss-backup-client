#!/usr/bin/env bash
#
# da-uid-recreate-test.sh — disaster-style restore onto a re-created account (DA test box)
# Project: KISS-Backup-Client
# Summary: Proves the restore re-owns files when an account comes back with NEW ids, and
#   that the OLD ids (now owned by someone else) end up on nothing of the account's. Runs
#   end to end and prints PASS/FAIL — no copy-pasting. Picks up from wherever it is:
#     1. finds the newest backup that still has <user> in its /etc/passwd (+ the old ids);
#     2. deletes <user> in DA if it still exists;
#     3. creates a placeholder user that takes the old uid (and gid) if they're free;
#     4. re-creates <user> (tests/da-make-test-user.sh) — waits out DA's account limit
#        while a delete is still in its task queue;
#     5. dry run, then a real mirror restore from that backup (CLI, --yes);
#     6. checks: no file left on an old id, marker file + DB back (both changed after the
#        re-create, so only the restore can bring them back), mail + DNS present.
#   TEST BOXES ONLY — it deletes and re-creates the account.
#
# Usage:  bash tests/da-uid-recreate-test.sh [user]          # default kbuser
#         bash tests/da-uid-recreate-test.sh --cleanup        # remove the placeholder user
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
U=kbuser; HOLD=kbhold
[ "${1:-}" = --cleanup ] && { userdel "$HOLD" 2>/dev/null && echo "removed $HOLD" || echo "no $HOLD"; exit 0; }
[ -n "${1:-}" ] && U="$1"
DOM="$U.test"
DA=/usr/local/directadmin
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -d "$DA" ] || { echo "not a DirectAdmin box" >&2; exit 1; }

fail=0
step() { printf '\n== %s\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }

# shellcheck disable=SC1091
. /etc/kiss-backup/backup.env
export RESTIC_PASSWORD_FILE="${BACKUP_PASSFILE:-/etc/restic/backup.pass}" RESTIC_CACHE_DIR=/var/cache/restic
R() { /usr/local/bin/restic -r "$BACKUP_REPO" "$@"; }

step "1. newest backup that still has $U"
SNAP=""; OU=""; OG=""
while read -r id _; do
    line="$(R dump "$id" /etc/passwd 2>/dev/null | grep "^$U:")" || continue
    SNAP="$id"; OU="$(cut -d: -f3 <<<"$line")"; OG="$(cut -d: -f4 <<<"$line")"; break
done < <(R snapshots --compact --tag "${BACKUP_TAG:-$(hostname -s)}" 2>/dev/null \
            | awk '/^[0-9a-f]{8} / && $5 != "db-dump" && $5 != "pre-restore" {print $1}' | tac)
[ -n "$SNAP" ] || { echo "no backup contains $U in /etc/passwd — nothing to test" >&2; exit 1; }
echo "snapshot $SNAP: $U was uid $OU gid $OG"

step "2. delete $U if it exists"
if [ -d "$DA/data/users/$U" ]; then
    bash "$HERE/da-make-test-user.sh" --delete "$U" >/dev/null || { echo "delete failed" >&2; exit 1; }
    echo "deleted"
else echo "already gone"; fi

step "3. placeholder $HOLD on the old ids"
if ! id "$HOLD" >/dev/null 2>&1; then
    args=(-M -s /sbin/nologin)
    getent passwd "$OU" >/dev/null || args+=(-u "$OU")
    getent group "$OG" >/dev/null || { groupadd -g "$OG" "$HOLD"; args+=(-g "$OG"); }
    useradd "${args[@]}" "$HOLD" || { echo "useradd failed" >&2; exit 1; }
fi
id "$HOLD"

step "4. re-create $U (waits for DA's account limit, up to 3 min)"
for i in 1 2 3 4 5 6 7; do
    out="$(bash "$HERE/da-make-test-user.sh" "$U" 2>&1)" && break
    if grep -q 'License is limited' <<<"$out" && [ "$i" -lt 7 ]; then
        echo "DA still counts the deleted account — waiting 30 s ($i/6)"; sleep 30; continue
    fi
    echo "$out"
    echo "DA accounts now: $(ls "$DA/data/users" | tr '\n' ' ')" >&2
    exit 1
done
NU="$(id -u "$U")"; NG="$(id -g "$U")"
echo "$U is now uid $NU gid $NG (was $OU/$OG)"
[ "$NU" != "$OU" ] && ok "new uid differs from the backup" || bad "same uid $NU — test can't prove the remap"
# The fresh account starts with the same marker values the backup has — change them, so the
# checks can only pass if the restore really put the backup back.
echo fresh > "/home/$U/domains/$DOM/public_html/kbtest.txt"
mysql -e "UPDATE ${U}_kbtest.t SET v=7"

step "5a. dry run"
kiss-backup restore-unit "$U" --snapshot "$SNAP" --mirror --dry-run > /root/uid-test-dry.log 2>&1
grep 'owner:' /root/uid-test-dry.log
grep -q "user $U was $OU in the backup, is $NU now" /root/uid-test-dry.log \
    && ok "preview reports the moved uid" || bad "preview didn't report the uid move (see /root/uid-test-dry.log)"

step "5b. restore (mirror, with safety snapshot)"
kiss-backup restore-unit "$U" --snapshot "$SNAP" --mirror --yes > /root/uid-test-restore.log 2>&1
tail -6 /root/uid-test-restore.log
grep -q "restore of $U done" /root/uid-test-restore.log && ok "restore finished" || bad "restore failed (see /root/uid-test-restore.log)"

step "6. checks"
n="$(find /home/"$U" /etc/virtual/"$DOM" -xdev -uid "$OU" 2>/dev/null | wc -l)"
[ "$n" = 0 ] && ok "no file left on the old uid $OU" || bad "$n file(s) still on old uid $OU"
if [ "$OG" != "$NG" ]; then
    n="$(find /home/"$U" -xdev -gid "$OG" 2>/dev/null | wc -l)"
    [ "$n" = 0 ] && ok "no file left on the old gid $OG" || bad "$n file(s) still on old gid $OG"
fi
f="/home/$U/domains/$DOM/public_html/kbtest.txt"
[ "$(cat "$f" 2>/dev/null)" = v1 ] && [ "$(stat -c %U "$f")" = "$U" ] \
    && ok "kbtest.txt back (v1, owned by $U)" || bad "kbtest.txt: $(ls -l "$f" 2>&1)"
[ "$(stat -c %G "/home/$U" 2>/dev/null)" = access ] \
    && ok "/home/$U keeps DA's 'access' group" || bad "/home/$U group is $(stat -c %G "/home/$U" 2>&1)"
[ "$(mysql -N -B -e "SELECT v FROM ${U}_kbtest.t" 2>/dev/null)" = 1 ] \
    && ok "DB ${U}_kbtest back (v=1)" || bad "DB value: $(mysql -N -B -e "SELECT v FROM ${U}_kbtest.t" 2>&1)"
[ -e "/etc/virtual/$DOM" ] && ok "mail config /etc/virtual/$DOM present" || bad "no /etc/virtual/$DOM"
[ -e "/var/named/$DOM.db" ] && ok "DNS zone /var/named/$DOM.db present" || bad "no /var/named/$DOM.db"

printf '\n%s\n' "$([ "$fail" -eq 0 ] && echo 'ALL PASSED' || echo 'SOME CHECKS FAILED')"
echo "Remove the placeholder afterwards with:  bash tests/da-uid-recreate-test.sh --cleanup"
exit "$fail"
