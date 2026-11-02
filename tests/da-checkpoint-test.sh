#!/usr/bin/env bash
#
# da-checkpoint-test.sh — on-demand checkpoints + restore points, end to end (DirectAdmin)
# Project: KISS-Backup-Client
# Summary: The headless "Backup / Restore a site" model on a real DA box:
#     1. DB checkpoint (label db-ckpt) -> change the DB -> restore the DB from that
#        checkpoint (Databases only, picked by id) -> value back;
#     2. FULL checkpoint (files + DBs, same moment) -> change file + DB, plant a file ->
#        restore from the checkpoint -> files AND databases come from that same checkpoint;
#     3. restore points: the db list has both checkpoints + the scheduled daily dumps, the
#        files list has the full checkpoint but not the DB-only one, labels shown;
#     4. undo: the safety copy taken by step 2's restore is itself a restore point —
#        restoring the DB from it brings the "damaged" value back.
#   Prints PASS/FAIL. TEST BOXES ONLY.
#
# Usage:  bash tests/da-checkpoint-test.sh [user] [domain]     # default kbuser kbuser.test
#
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
U="${1:-kbuser}"; DOM="${2:-$U.test}"; DB="${U}_kbtest"
DA=/usr/local/directadmin
F="/home/$U/domains/$DOM/public_html/kbtest.txt"
P="/home/$U/domains/$DOM/public_html/planted.php"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }

fail=0
step() { printf '\n== %s\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
dbv()  { mysql -N -B -e "SELECT v FROM $DB.t" 2>/dev/null; }
ckid() { sed -n 's/.*checkpoint saved: \([0-9a-f]\{8\}\).*/\1/p' "$1" | tail -1; }

step "0. test account"
[ -d "$DA/data/users/$U" ] || bash "$HERE/da-make-test-user.sh" "$U" "$DOM" >/dev/null \
    || { echo "could not create $U" >&2; exit 1; }
echo v1 > "$F"; chown "$U:$U" "$F"; rm -f "$P"; mysql -e "UPDATE $DB.t SET v=1"
echo "kbtest.txt=v1, $DB.t.v=$(dbv)"

step "1. database checkpoint -> change -> restore the DB from it"
kiss-backup checkpoint "$U" --kind db --label db-ckpt > /root/ckpt-test.log 2>&1
C1="$(ckid /root/ckpt-test.log)"
[ -n "$C1" ] && ok "DB checkpoint saved ($C1)" || { bad "DB checkpoint: $(tail -3 /root/ckpt-test.log)"; exit 1; }
mysql -e "UPDATE $DB.t SET v=2"
kiss-backup restore-unit "$U" --dbs-only --db-snapshot "$C1" --mirror --yes --no-safety-snapshot >> /root/ckpt-test.log 2>&1
[ "$(dbv)" = 1 ] && ok "DB back to 1 from the DB checkpoint" || bad "DB is $(dbv) after restoring $C1"

step "2. full checkpoint -> damage files + DB -> restore both from it"
kiss-backup checkpoint "$U" --kind full --label full-ckpt >> /root/ckpt-test.log 2>&1
C2="$(ckid /root/ckpt-test.log)"
[ -n "$C2" ] && [ "$C2" != "$C1" ] && ok "full checkpoint saved ($C2)" || { bad "full checkpoint failed"; exit 1; }
echo v9 > "$F"; echo '<?php // planted' > "$P"; chown "$U:$U" "$F" "$P"; mysql -e "UPDATE $DB.t SET v=9"
kiss-backup restore-unit "$U" --snapshot "$C2" --mirror --yes > /root/ckpt-test-full.log 2>&1
grep -q "databases from $C2" /root/ckpt-test-full.log && ok "DBs paired with the same checkpoint ($C2)" \
    || bad "DBs not taken from the checkpoint: $(grep 'databases from' /root/ckpt-test-full.log)"
[ "$(cat "$F")" = v1 ] && ok "kbtest.txt back to v1" || bad "kbtest.txt is $(cat "$F")"
[ ! -e "$P" ] && ok "planted.php removed" || bad "planted.php still there"
[ "$(dbv)" = 1 ] && ok "DB back to 1" || bad "DB is $(dbv)"

step "3. restore-point lists"
kiss-backup points "$U" db > /root/ckpt-test-points-db.txt 2>&1
kiss-backup points "$U" files > /root/ckpt-test-points-files.txt 2>&1
head -6 /root/ckpt-test-points-db.txt | sed 's/^/    db:    /'
head -4 /root/ckpt-test-points-files.txt | sed 's/^/    files: /'
grep -q "^$C1	.*checkpoint	db-ckpt$" /root/ckpt-test-points-db.txt && ok "db list: DB checkpoint with label" || bad "db list misses $C1"
grep -q "^$C2	.*checkpoint	full-ckpt$" /root/ckpt-test-points-db.txt && ok "db list: full checkpoint" || bad "db list misses $C2"
grep -q "scheduled daily DB dump" /root/ckpt-test-points-db.txt && ok "db list: scheduled daily dumps" || bad "db list has no scheduled dumps"
grep -q "^$C2	" /root/ckpt-test-points-files.txt && ok "files list: full checkpoint" || bad "files list misses $C2"
grep -q "^$C1	" /root/ckpt-test-points-files.txt && bad "files list shows the DB-only checkpoint" || ok "files list: DB-only checkpoint not shown"

step "4. undo via the safety copy"
S="$(awk -F'\t' '$3 ~ /^safety copy/ {print $1; exit}' /root/ckpt-test-points-db.txt)"
[ -n "$S" ] && ok "step 2's safety copy is a DB restore point ($S)" || bad "no safety copy in the db list"
if [ -n "$S" ]; then
    kiss-backup restore-unit "$U" --dbs-only --db-snapshot "$S" --mirror --yes --no-safety-snapshot >> /root/ckpt-test.log 2>&1
    [ "$(dbv)" = 9 ] && ok "undo: DB back to the pre-restore value 9" || bad "DB is $(dbv) after restoring the safety copy"
    mysql -e "UPDATE $DB.t SET v=1"
fi

printf '\n%s\n' "$([ "$fail" -eq 0 ] && echo 'ALL PASSED' || echo 'SOME CHECKS FAILED')"
echo "Logs: /root/ckpt-test*.log  —  clean up with: bash tests/da-cleanup-test-data.sh"
exit "$fail"
