#!/usr/bin/env bash
#
# verify-granular-db-restore.sh
# -----------------------------
# Proves the NON-NEGOTIABLE backups requirement: granular point-in-time restore
# of ONE database out of a whole-instance mariadb-backup (mariabackup) physical
# chain, with every OTHER database on the instance left provably untouched.
#
# METHOD = "restore-aside" (robust, schema-agnostic, matches the real-world
# Acronis recovery the maintainer has done): prepare the full+incremental chain
# to a scratch datadir, start a THROWAWAY mariadbd on it, mariadb-dump just the
# victim DB at that point-in-time, then import it back into the live instance.
# This handles FULLTEXT indexes, foreign keys, triggers, etc. NATIVELY — no
# per-table transportable-tablespace surgery (the lighter but fragile method;
# see vendor_docs/mariadb/, partial-backup "Restoring Tables with Full-Text
# Indexes"). Grounded in vendor_docs/mariadb/. See docs/backups_handover.md §3.1.
#
# REPRESENTATIVE: the victim is a REAL clone of test4_wp (verified 2026-06-21 to
# carry 1 FULLTEXT index + 2 foreign keys + a MEMORY table) — the exact schema
# edge cases a synthetic DB would have dodged.
#
# SAFETY: only creates/drops the scratch DB gtest_a and writes under $SCRATCH.
# It never modifies test4_wp (read by the hot backup; asserted UNCHANGED at the
# end). Run as root on a TEST box. Idempotent: re-running cleans its own state.
#
# Usage:  sudo bash verify-granular-db-restore.sh
#
set -uo pipefail

# ---- config ---------------------------------------------------------------
SRC_DB="test4_wp"                       # real DB to clone (also the witness)
VICTIM="gtest_a"                        # the DB we roll back to a known point
SCRATCH="/root/bkp-granular-test"
# The prepared scratch datadir must live where the mysql user can TRAVERSE to it
# (NOT under /root, which is 0700) — else the throwaway mariadbd gets EACCES.
RESTORE="/var/lib/granular-restore"     # prepared scratch datadir (temp instance)
MB="mariadb-backup"
DUMP="mariadb-dump"; command -v "$DUMP" >/dev/null 2>&1 || DUMP="mysqldump"
MYSQL="mysql -N -B"
TSOCK="$RESTORE/tmpd.sock"; TPID="$RESTORE/tmpd.pid"; TMPD_PID=""

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
step() { printf '\n=== %s ===\n' "$1"; }
die()  { printf '\n\033[31mABORT:\033[0m %s\n' "$1" >&2; cleanup_tmpd; exit 1; }
cleanup_tmpd() {
  [ -S "$TSOCK" ] && mysqladmin --no-defaults -S "$TSOCK" shutdown 2>/dev/null || true
  [ -n "$TMPD_PID" ] && kill "$TMPD_PID" 2>/dev/null || true
}

command -v "$MB" >/dev/null 2>&1 || die "$MB not found"
$MYSQL -e "USE ${SRC_DB};" 2>/dev/null || die "source DB ${SRC_DB} not present"
"$MB" --version 2>&1 | head -1

# Helpers
marker_now() { $MYSQL -e "SELECT label FROM ${1}._snap_marker ORDER BY id DESC LIMIT 1;"; }
ft_count()   { $MYSQL -e "SELECT COUNT(DISTINCT table_name) FROM information_schema.statistics WHERE table_schema='${1}' AND index_type='FULLTEXT';"; }
fk_count()   { $MYSQL -e "SELECT COUNT(*) FROM information_schema.referential_constraints WHERE constraint_schema='${1}';"; }
tbl_count()  { $MYSQL -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${1}';"; }
# A real InnoDB table from the source, chosen dynamically (no hard-coded names).
WTBL="$($MYSQL -e "SELECT table_name FROM information_schema.tables WHERE table_schema='${SRC_DB}' AND engine='InnoDB' ORDER BY table_name LIMIT 1;")"
# Cheap tamper fingerprint for the witness: table count + checksum of $WTBL.
witness_fp() { printf '%s|%s' "$(tbl_count "$SRC_DB")" "$($MYSQL -e "CHECKSUM TABLE ${SRC_DB}.\`${WTBL}\`;" 2>/dev/null | awk '{print $2}')"; }

# ---------------------------------------------------------------------------
step "0. Clean slate"
cleanup_tmpd
rm -rf "$SCRATCH" "$RESTORE"; mkdir -p "$SCRATCH"
$MYSQL -e "DROP DATABASE IF EXISTS ${VICTIM};"

# ---------------------------------------------------------------------------
step "1. Clone the REAL ${SRC_DB} -> ${VICTIM} (carries FULLTEXT + FKs + MEMORY)"
$MYSQL -e "CREATE DATABASE ${VICTIM};"
# Hot, consistent, no site impact (--single-transaction); pipe = no scratch .sql.
$DUMP --single-transaction --routines --triggers --events "$SRC_DB" | mysql "$VICTIM"
$MYSQL -e "CREATE TABLE ${VICTIM}._snap_marker (id INT AUTO_INCREMENT PRIMARY KEY, label VARCHAR(32), ts DATETIME DEFAULT NOW()) ENGINE=InnoDB;
           INSERT INTO ${VICTIM}._snap_marker(label) VALUES ('snap1');"
echo "victim: tables=$(tbl_count "$VICTIM")  fulltext=$(ft_count "$VICTIM")  fks=$(fk_count "$VICTIM")  marker=$(marker_now "$VICTIM")"
WITNESS_BEFORE="$(witness_fp)"

# ---------------------------------------------------------------------------
step "2. mariadb-backup FULL (whole instance)"
t0=$(date +%s)
$MB --backup --target-dir="$SCRATCH/full" --user=root >/dev/null 2>"$SCRATCH/full.log" \
  || { tail -8 "$SCRATCH/full.log"; die "full backup failed"; }
echo "full: $(( $(date +%s) - t0 ))s, $(du -sh "$SCRATCH/full" | cut -f1)"

# ---------------------------------------------------------------------------
step "3. Churn + INCREMENTAL 1  (the 'known good point' = snap2)"
$MYSQL -e "INSERT INTO ${VICTIM}._snap_marker(label) VALUES ('snap2');"
$MB --backup --target-dir="$SCRATCH/inc1" --incremental-basedir="$SCRATCH/full" --user=root \
  >/dev/null 2>"$SCRATCH/inc1.log" || { tail -8 "$SCRATCH/inc1.log"; die "inc1 failed"; }
echo "snap2: marker=$(marker_now "$VICTIM"), inc1=$(du -sh "$SCRATCH/inc1" | cut -f1)"

# ---------------------------------------------------------------------------
step "4. More churn + INCREMENTAL 2  (current = snap3)"
$MYSQL -e "INSERT INTO ${VICTIM}._snap_marker(label) VALUES ('snap3');"
$MB --backup --target-dir="$SCRATCH/inc2" --incremental-basedir="$SCRATCH/inc1" --user=root \
  >/dev/null 2>"$SCRATCH/inc2.log" || { tail -8 "$SCRATCH/inc2.log"; die "inc2 failed"; }
echo "snap3: marker=$(marker_now "$VICTIM"), inc2=$(du -sh "$SCRATCH/inc2" | cut -f1)"

# ---------------------------------------------------------------------------
step "5. Prepare chain to snap2 ONLY (full + inc1), into a scratch datadir"
cp -a "$SCRATCH/full" "$RESTORE"
$MB --prepare --target-dir="$RESTORE" >/dev/null 2>"$SCRATCH/prep-base.log" \
  || { tail -15 "$SCRATCH/prep-base.log"; die "prepare base failed"; }
$MB --prepare --target-dir="$RESTORE" --incremental-dir="$SCRATCH/inc1" \
  >/dev/null 2>"$SCRATCH/prep-inc1.log" || { tail -15 "$SCRATCH/prep-inc1.log"; die "prepare inc1 failed"; }
# Deliberately STOP — inc2 (snap3) is NOT applied. $RESTORE now == snap2 state.
chown -R mysql:mysql "$RESTORE"
# Best-effort SELinux label so a strict box lets mysqld_t use this as a datadir
# (no-op / harmless where SELinux is permissive or disabled).
chcon -R -t mysqld_db_t "$RESTORE" 2>/dev/null || true

# ---------------------------------------------------------------------------
step "6. Start throwaway mariadbd on the scratch datadir, dump ${VICTIM} @ snap2"
mariadbd --no-defaults --datadir="$RESTORE" --socket="$TSOCK" --pid-file="$TPID" \
  --skip-grant-tables --skip-networking --innodb-buffer-pool-size=128M \
  --user=mysql >"$SCRATCH/tmpd.log" 2>&1 &
TMPD_PID=$!
for _ in $(seq 1 90); do [ -S "$TSOCK" ] && break; sleep 1; done
[ -S "$TSOCK" ] || { tail -20 "$SCRATCH/tmpd.log"; die "throwaway mariadbd never came up"; }
mysql --no-defaults -S "$TSOCK" -N -e "SELECT 1;" >/dev/null || { tail -20 "$SCRATCH/tmpd.log"; die "temp instance not answering"; }
TMP_MARK=$(mysql --no-defaults -S "$TSOCK" -N -B -e "SELECT label FROM ${VICTIM}._snap_marker ORDER BY id DESC LIMIT 1;")
echo "temp instance sees ${VICTIM} marker = ${TMP_MARK} (expect snap2)"
"$DUMP" --no-defaults -S "$TSOCK" --single-transaction --routines --triggers --events \
  --databases "$VICTIM" > "$SCRATCH/${VICTIM}.snap2.sql" 2>"$SCRATCH/dump.log" \
  || { tail -8 "$SCRATCH/dump.log"; die "dump of ${VICTIM} from temp instance failed"; }
cleanup_tmpd; TMPD_PID=""
echo "snap2 dump: $(du -sh "$SCRATCH/${VICTIM}.snap2.sql" | cut -f1)"

# ---------------------------------------------------------------------------
step "7. Simulate loss + import ${VICTIM} back into the LIVE instance"
$MYSQL -e "DROP DATABASE ${VICTIM};"           # the loss / corruption event
mysql < "$SCRATCH/${VICTIM}.snap2.sql"          # dump carries CREATE DATABASE + USE

# ---------------------------------------------------------------------------
step "8. Verdict"
V_MARK=$(marker_now "$VICTIM")
[ "$V_MARK" = "snap2" ] && ok "${VICTIM} rolled back to snap2 (point-in-time correct, not snap3)" \
                        || bad "${VICTIM} marker == '${V_MARK}', expected snap2"
V_FT=$(ft_count "$VICTIM");  [ "$V_FT" = "1" ] && ok "${VICTIM} FULLTEXT index survived restore (=1)" \
                                               || bad "${VICTIM} FULLTEXT count == ${V_FT}, expected 1"
V_FK=$(fk_count "$VICTIM");  [ "$V_FK" = "2" ] && ok "${VICTIM} foreign keys survived restore (=2)" \
                                               || bad "${VICTIM} FK count == ${V_FK}, expected 2"
$MYSQL -e "SELECT 1 FROM ${VICTIM}.\`${WTBL}\` LIMIT 1;" >/dev/null 2>&1 \
  && ok "${VICTIM} real WP data is queryable post-restore (${WTBL})" || bad "${VICTIM} data not queryable"
WITNESS_AFTER="$(witness_fp)"
[ "$WITNESS_AFTER" = "$WITNESS_BEFORE" ] && ok "${SRC_DB} (real tenant) UNCHANGED — zero collateral" \
                                         || bad "${SRC_DB} fingerprint changed (${WITNESS_BEFORE} -> ${WITNESS_AFTER})"

# ---------------------------------------------------------------------------
step "9. Footprint"
echo "scratch (backups): $(du -sh "$SCRATCH" | cut -f1)   restore datadir: $(du -sh "$RESTORE" 2>/dev/null | cut -f1)"
df -h /var/lib/mysql | tail -1

printf '\n========== RESULT: %d passed, %d failed ==========\n' "$PASS" "$FAIL"
echo "Clean up:  rm -rf $SCRATCH $RESTORE ; mysql -e 'DROP DATABASE IF EXISTS ${VICTIM};'"
[ "$FAIL" -eq 0 ]
