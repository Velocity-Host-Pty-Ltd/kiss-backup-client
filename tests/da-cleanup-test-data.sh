#!/usr/bin/env bash
#
# da-cleanup-test-data.sh — remove what the DirectAdmin box tests leave behind
# Project: KISS-Backup-Client
# Summary: Lists, then (after one confirmation) removes the test account and its leftovers:
#   - the DA account <user> (through DA: home, mail, DNS zone, <user>_* databases);
#   - the placeholder user kbhold (tests/da-uid-recreate-test.sh);
#   - the tests' logs in /root, restore status/logs for <user>, leftover restore workdirs;
#   - the older marker test on 'admin': /home/admin/kbtest.txt + database admin_kbtest;
#   then refreshes DA's user cache so the freed licence slot counts as free.
#   Backups already in the repository are NOT touched (they age out under retention).
#
# Usage:  bash tests/da-cleanup-test-data.sh [user] [--yes]     # default user: kbuser
#
set -uo pipefail

U=kbuser; YES=0
for a in "$@"; do case "$a" in --yes) YES=1 ;; *) U="$a" ;; esac; done
HERE="$(cd "$(dirname "$0")" && pwd)"
DA=/usr/local/directadmin
ST=/var/lib/kiss-backups
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[[ "$U" =~ ^[a-z][a-z0-9]{0,15}$ ]] && [ "$U" != admin ] || { echo "refusing user '$U'" >&2; exit 1; }

items=()
[ -d "$DA/data/users/$U" ]                 && items+=("DA account $U (home, mail, DNS, ${U}_* databases)")
id kbhold >/dev/null 2>&1                  && items+=("placeholder user kbhold")
logs=(/root/uid-test-dry.log /root/uid-test-restore.log /root/mail-test-restore.log /root/kill-test.log /root/cagefs-test-restore.log /root/ckpt-test.log /root/ckpt-test-full.log /root/ckpt-test-points-db.txt /root/ckpt-test-points-files.txt)
for f in "${logs[@]}"; do [ -e "$f" ] && items+=("$f"); done
for f in "$ST/restore-status/$U".* ; do [ -e "$f" ] && items+=("$f"); done
for d in "$ST/restore/$U".* ; do [ -d "$d" ] && items+=("$d (leftover restore workdir)"); done
[ -e /home/admin/kbtest.txt ]              && items+=("/home/admin/kbtest.txt")
mysql -N -B -e "SHOW DATABASES LIKE 'admin\\_kbtest'" 2>/dev/null | grep -q . && items+=("database admin_kbtest")

if [ "${#items[@]}" -eq 0 ]; then echo "nothing to clean up"; exit 0; fi
echo "Will remove:"; printf '  - %s\n' "${items[@]}"
echo "(backups in the repository are kept)"
if [ "$YES" -ne 1 ]; then
    read -r -p "Go ahead? [y/N] " ans
    [ "$ans" = y ] || [ "$ans" = Y ] || { echo "nothing removed"; exit 0; }
fi

if [ -d "$DA/data/users/$U" ]; then
    bash "$HERE/da-make-test-user.sh" --delete "$U" >/dev/null && echo "removed DA account $U" \
        || echo "FAILED to remove DA account $U — remove it in DirectAdmin" >&2
fi
if id kbhold >/dev/null 2>&1; then userdel kbhold && echo "removed kbhold"; fi
getent group kbhold >/dev/null && groupdel kbhold
for f in "${logs[@]}"; do rm -f "$f"; done
rm -f "$ST/restore-status/$U".*
for d in "$ST/restore/$U".* ; do [ -d "$d" ] && rm -rf "$d"; done
rm -f /home/admin/kbtest.txt
mysql -e "DROP DATABASE IF EXISTS admin_kbtest" 2>/dev/null
echo "removed logs, restore status, admin's kbtest marker + database"

# A deleted account kept counting against the DA licence until the cache was rebuilt.
echo "action=cache&value=showallusers" >> "$DA/data/task.queue"
"$DA/dataskq" d >/dev/null 2>&1; systemctl restart directadmin
echo "DA user cache rebuilt — accounts now: $(ls "$DA/data/users" | tr '\n' ' ')"
