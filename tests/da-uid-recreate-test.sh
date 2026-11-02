#!/usr/bin/env bash
#
# da-uid-recreate-test.sh — disaster-style restore onto a re-created account (DA test box)
# Project: KISS-Backup-Client
# Summary: Proves the restore re-owns files when an account comes back with NEW ids, and
#   that the OLD ids (now owned by someone else) end up on nothing of the account's. Runs
#   end to end and prints PASS/FAIL — no copy-pasting. Picks up from wherever it is:
#     1. finds the newest backup that still has <user> in its /etc/passwd (+ the old ids);
#     2. deletes <user> in DA if it still exists;
#     3. removes the placeholder for now — this DA build counts Unix users against the
#        license, so it would block the re-create;
#     4. re-creates <user> (tests/da-make-test-user.sh);
#     5. moves <user> to new ids (usermod/groupmod — as on a rebuilt server) and puts a
#        placeholder user on the old ids, so they belong to someone else;
#     6. dry run, then a real mirror restore from that backup (CLI, --yes);
#     7. checks: no file left on an old id, marker file + DB back (both changed after the
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

step "3. free DA's license slot (this DA build counts Unix users too)"
if id "$HOLD" >/dev/null 2>&1; then userdel "$HOLD" && echo "removed $HOLD for now"; fi
getent group "$HOLD" >/dev/null && groupdel "$HOLD"

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
echo "DA created $U as uid $(id -u "$U") gid $(id -g "$U")"

step "5. move $U to new ids (as on a rebuilt server), old ids to a placeholder"
if [ "$(id -u "$U")" = "$OU" ] || [ "$(id -g "$U")" = "$OG" ]; then
    nu=$((OU + 10)); while getent passwd "$nu" >/dev/null; do nu=$((nu + 1)); done
    ng=$((OG + 10)); while getent group "$ng" >/dev/null; do ng=$((ng + 1)); done
    cg="$(id -g "$U")"
    groupmod -g "$ng" "$U" || { echo "groupmod failed" >&2; exit 1; }
    usermod -u "$nu" -g "$ng" "$U" || { echo "usermod failed" >&2; exit 1; }
    # usermod re-owns the home; also hand over the account's other files on the old ids.
    # Separate passes: only the old uid -> new uid, only the old group -> new group
    # (files in 'access' / 'mail' keep their group).
    find /home/"$U" /etc/virtual/"$DOM" "/var/named/$DOM.db" -xdev -uid "$OU" -exec chown -h "$nu" {} + 2>/dev/null
    find /home/"$U" /etc/virtual/"$DOM" "/var/named/$DOM.db" -xdev -gid "$cg" -exec chgrp -h "$ng" {} + 2>/dev/null
fi
getent group "$OG" >/dev/null || groupadd -g "$OG" "$HOLD"
id "$HOLD" >/dev/null 2>&1 || useradd -M -s /sbin/nologin -u "$OU" -g "$OG" "$HOLD" \
    || { echo "placeholder useradd failed" >&2; exit 1; }
id "$HOLD"
NU="$(id -u "$U")"; NG="$(id -g "$U")"
echo "$U is now uid $NU gid $NG (was $OU/$OG)"
[ "$NU" != "$OU" ] && ok "new uid differs from the backup" || bad "same uid $NU — test can't prove the remap"
# The fresh account starts with the same marker values the backup has — change them, so the
# checks can only pass if the restore really put the backup back.
echo fresh > "/home/$U/domains/$DOM/public_html/kbtest.txt"
mysql -e "UPDATE ${U}_kbtest.t SET v=7"

step "6a. dry run"
kiss-backup restore-unit "$U" --snapshot "$SNAP" --mirror --dry-run > /root/uid-test-dry.log 2>&1
grep 'owner:' /root/uid-test-dry.log
grep -q "user $U was $OU in the backup, is $NU now" /root/uid-test-dry.log \
    && ok "preview reports the moved uid" || bad "preview didn't report the uid move (see /root/uid-test-dry.log)"

step "6b. restore (mirror, with safety snapshot)"
kiss-backup restore-unit "$U" --snapshot "$SNAP" --mirror --yes > /root/uid-test-restore.log 2>&1
tail -6 /root/uid-test-restore.log
grep -q "restore of $U done" /root/uid-test-restore.log && ok "restore finished" || bad "restore failed (see /root/uid-test-restore.log)"

step "7. checks"
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
# DA's mail login file may carry the account's uid:gid INSIDE it — a restore brings back the
# backup's text, so a moved uid there would make mail logins act as the old id's new owner.
pw="/etc/virtual/$DOM/passwd"
if [ -s "$pw" ]; then
    if awk -F: -v o="$OU" '$3 == o' "$pw" | grep -q .; then
        bad "$pw still names the old uid $OU inside the file (mail would run as $HOLD): $(awk -F: '{print $1":"$3":"$4}' "$pw" | head -3)"
    else ok "$pw does not carry the old uid"; fi
else echo "note: no $pw (no mail accounts on $DOM yet) — uid inside it not tested"; fi

printf '\n%s\n' "$([ "$fail" -eq 0 ] && echo 'ALL PASSED' || echo 'SOME CHECKS FAILED')"
echo "Remove the placeholder afterwards with:  bash tests/da-uid-recreate-test.sh --cleanup"
exit "$fail"
