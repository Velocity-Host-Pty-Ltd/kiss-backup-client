#!/usr/bin/env bash
#
# verify-restic-wrap-mariabackup.sh
# ---------------------------------
# Proves the FULL DB-backup pipeline end to end (docs/backups_handover.md §12):
# wrap the physical mariadb-backup chain in RESTIC, then restore the chain
# *through* restic and confirm it still prepares to a correct point-in-time.
#
# Two questions the granular test did NOT answer:
#   1. INTEGRITY — does a physical mariadb-backup full+incremental chain survive a
#      restic store→restore round-trip and still `--prepare` cleanly? (We delete
#      the local copies after backup, so the restore is genuinely FROM restic.)
#   2. DEDUP — how well does restic content-defined-chunk successive *nightly
#      fulls* of the physical datadir? This is the scaling number behind the
#      "nightly full + hourly incremental → restic → dedup" design (§3.1): if a
#      second full re-stores the whole datadir, nightly fulls are unaffordable;
#      if CDC dedups the unchanged pages, they're cheap.
#
# The restic TRANSPORT (local + SFTP→KISS) and mysqldump dedup are already proven
# (backups_restic_test_report.md); this is specifically about the PHYSICAL chain.
#
# SAFETY: only creates/drops scratch DB gtest_rw + writes under /root/restic-wrap-work
# and /var/lib/restic-wrap-restore. Never modifies test4_wp. Run as root on a TEST
# box. Idempotent: re-running cleans its own state.
#
# Usage:  sudo bash verify-restic-wrap-mariabackup.sh
#
set -uo pipefail

# ---- config ---------------------------------------------------------------
CHURN_DB="gtest_rw"
WORK="/root/restic-wrap-work"               # mariabackup target dirs + restic repo
RT="/var/lib/restic-wrap-restore"           # restore target (mysql-traversable)
export RESTIC_REPOSITORY="$WORK/repo"
export RESTIC_PASSWORD="restic-wrap-test"
MB="mariadb-backup"
MYSQL="mysql -N -B"
TSOCK="$RT/tmpd.sock"; TPID="$RT/tmpd.pid"; TMPD_PID=""

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
step() { printf '\n=== %s ===\n' "$1"; }
cleanup_tmpd() {
  [ -S "$TSOCK" ] && mysqladmin --no-defaults -S "$TSOCK" shutdown 2>/dev/null || true
  [ -n "$TMPD_PID" ] && kill "$TMPD_PID" 2>/dev/null || true
}
die()  { printf '\n\033[31mABORT:\033[0m %s\n' "$1" >&2; cleanup_tmpd; exit 1; }

RESTIC="$(command -v restic || true)"
[ -z "$RESTIC" ] && [ -x /usr/local/bin/restic ] && RESTIC=/usr/local/bin/restic
[ -z "$RESTIC" ] && [ -x /usr/local/bin/vps-tooling/restic ] && RESTIC=/usr/local/bin/vps-tooling/restic
[ -n "$RESTIC" ] || die "restic not found"
command -v "$MB" >/dev/null 2>&1 || die "$MB not found"
"$RESTIC" version | head -1; "$MB" --version 2>&1 | head -1

marker_now() { $MYSQL -e "SELECT label FROM ${1}._snap_marker ORDER BY id DESC LIMIT 1;"; }
# Parse restic's "Added to the repository: X (Y stored)" — Y is post-dedup+compress.
stored_of() { sed -n 's/.*(\(.*\) stored).*/\1/p' "$1" | tail -1; }
snapid_of() { sed -n 's/^snapshot \([0-9a-f]\{8\}\) saved.*/\1/p' "$1" | tail -1; }
backup_dir() { # $1=path $2=tag  -> echoes "<stored>|<snapid>"
  "$RESTIC" backup "$1" --tag "$2" >"$WORK/blog-$2.txt" 2>&1 || { cat "$WORK/blog-$2.txt"; die "restic backup $2 failed"; }
  printf '%s|%s' "$(stored_of "$WORK/blog-$2.txt")" "$(snapid_of "$WORK/blog-$2.txt")"
}

# ---------------------------------------------------------------------------
step "0. Clean slate"
cleanup_tmpd
rm -rf "$WORK" "$RT"; mkdir -p "$WORK"
$MYSQL -e "DROP DATABASE IF EXISTS ${CHURN_DB};"

# ---------------------------------------------------------------------------
step "1. Churn DB + restic repo"
$MYSQL -e "CREATE DATABASE ${CHURN_DB};
  CREATE TABLE ${CHURN_DB}.data1 (id INT AUTO_INCREMENT PRIMARY KEY, payload VARBINARY(512)) ENGINE=InnoDB;
  CREATE TABLE ${CHURN_DB}._snap_marker (id INT AUTO_INCREMENT PRIMARY KEY, label VARCHAR(32), ts DATETIME DEFAULT NOW()) ENGINE=InnoDB;
  INSERT INTO ${CHURN_DB}._snap_marker(label) VALUES ('snap1');"
"$RESTIC" init >/dev/null 2>&1 || die "restic init failed"
echo "repo: $RESTIC_REPOSITORY  churn db: ${CHURN_DB} marker=$(marker_now "$CHURN_DB")"

# ---------------------------------------------------------------------------
step "2. mariadb-backup FULL #1 -> restic"
$MB --backup --target-dir="$WORK/full1" --user=root >/dev/null 2>"$WORK/full1.log" \
  || { tail -8 "$WORK/full1.log"; die "full1 failed"; }
R="$(backup_dir "$WORK/full1" full1)"; F1_STORED="${R%%|*}"; F1_ID="${R##*|}"
echo "full1 on-disk $(du -sh "$WORK/full1" | cut -f1)  -> restic stored ${F1_STORED}  (snap ${F1_ID})"

# ---------------------------------------------------------------------------
step "3. Churn -> INCREMENTAL 1 (snap2) -> restic"
$MYSQL -e "INSERT INTO ${CHURN_DB}._snap_marker(label) VALUES ('snap2');"
$MB --backup --target-dir="$WORK/inc1" --incremental-basedir="$WORK/full1" --user=root \
  >/dev/null 2>"$WORK/inc1.log" || { tail -8 "$WORK/inc1.log"; die "inc1 failed"; }
R="$(backup_dir "$WORK/inc1" inc1)"; I1_STORED="${R%%|*}"; I1_ID="${R##*|}"
echo "inc1 on-disk $(du -sh "$WORK/inc1" | cut -f1)  -> restic stored ${I1_STORED}  (snap ${I1_ID})"

# ---------------------------------------------------------------------------
step "4. Churn -> INCREMENTAL 2 (snap3) -> restic"
$MYSQL -e "INSERT INTO ${CHURN_DB}._snap_marker(label) VALUES ('snap3');"
$MB --backup --target-dir="$WORK/inc2" --incremental-basedir="$WORK/inc1" --user=root \
  >/dev/null 2>"$WORK/inc2.log" || { tail -8 "$WORK/inc2.log"; die "inc2 failed"; }
R="$(backup_dir "$WORK/inc2" inc2)"; I2_STORED="${R%%|*}"
echo "inc2 on-disk $(du -sh "$WORK/inc2" | cut -f1)  -> restic stored ${I2_STORED}"

# ---------------------------------------------------------------------------
step "5. Simulate a day of writes (MEASURED), then drop the local chain"
# Real changed InnoDB pages so the FULL #2 dedup number is realistic (not an
# artificial ~100% from a near-identical datadir). Portable generator — no
# SEQUENCE engine / RANDOM_BYTES dependency (both can be absent/disabled): a
# recursive CTE of 512 rows per batch (under the default max_recursive_iterations
# of 1000), 512 B/row, 256 batches ~= 64 MiB.
# MEASURE landing two reliable ways — exact row count AND the real .ibd file
# growth on disk. (NOT information_schema.data_length: for InnoDB it's a lazily
# cached optimizer estimate and reads ~0 right after a bulk insert — that false
# negative tripped an earlier run.)
IBD="/var/lib/mysql/${CHURN_DB}/data1.ibd"
rows_before="$($MYSQL -e "SELECT COUNT(*) FROM ${CHURN_DB}.data1;")"
ibd_before="$(stat -c%s "$IBD" 2>/dev/null || echo 0)"
for b in $(seq 1 256); do
  $MYSQL -e "INSERT INTO ${CHURN_DB}.data1(payload)
    WITH RECURSIVE c(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM c WHERE n<512)
    SELECT REPEAT(UNHEX(MD5(RAND())), 32) FROM c;" 2>"$WORK/churn.log" \
    || { tail -4 "$WORK/churn.log"; die "churn insert failed at batch $b"; }
done
$MYSQL -e "FLUSH TABLES ${CHURN_DB}.data1;"
rows_after="$($MYSQL -e "SELECT COUNT(*) FROM ${CHURN_DB}.data1;")"
ibd_after="$(stat -c%s "$IBD" 2>/dev/null || echo 0)"
CHURN_ROWS=$(( rows_after - rows_before ))
CHURN_MIB=$(( (ibd_after - ibd_before) / 1048576 ))
[ "$CHURN_ROWS" -ge 100000 ] && ok "churn landed: +${CHURN_ROWS} rows, data1.ibd +${CHURN_MIB} MiB on disk" \
                             || bad "churn did NOT land (+${CHURN_ROWS} rows) — full2 dedup is best-case only"
rm -rf "$WORK/full1" "$WORK/inc1" "$WORK/inc2"     # free ~instance-size; restic has them
echo "local chain deleted (restic owns it)"

# ---------------------------------------------------------------------------
step "6. mariadb-backup FULL #2 (next-night sim) -> restic  [DEDUP HEADLINE]"
$MB --backup --target-dir="$WORK/full2" --user=root >/dev/null 2>"$WORK/full2.log" \
  || { tail -8 "$WORK/full2.log"; die "full2 failed"; }
F2_DISK="$(du -sh "$WORK/full2" | cut -f1)"
R="$(backup_dir "$WORK/full2" full2)"; F2_STORED="${R%%|*}"
rm -rf "$WORK/full2"
echo "full2 on-disk ${F2_DISK}  -> restic stored ${F2_STORED}  (vs full1 ${F1_STORED})"

# ---------------------------------------------------------------------------
step "7. Repo integrity + size"
"$RESTIC" check >/dev/null 2>"$WORK/check.log" && ok "restic check: repo intact, no errors" \
  || { tail -8 "$WORK/check.log"; bad "restic check found errors"; }
REPO_TOTAL="$(du -sh "$RESTIC_REPOSITORY" | cut -f1)"
echo "restic repo on disk: ${REPO_TOTAL}  (holds 2 fulls + 2 incrementals of a ${F2_DISK} instance)"

# ---------------------------------------------------------------------------
step "8. Restore chain FROM restic (full1 + inc1), prepare to snap2"
mkdir -p "$RT"
"$RESTIC" restore "$F1_ID" --target "$RT" >/dev/null 2>"$WORK/restore-full1.log" || die "restic restore full1 failed"
"$RESTIC" restore "$I1_ID" --target "$RT" >/dev/null 2>"$WORK/restore-inc1.log" || die "restic restore inc1 failed"
PREP="$RT$WORK/full1"; RINC1="$RT$WORK/inc1"
[ -d "$PREP" ] && ok "chain restored from restic (files back on disk)" || { bad "restored full1 dir missing at $PREP"; PREP=""; }
if [ -n "$PREP" ]; then
  $MB --prepare --target-dir="$PREP" >/dev/null 2>"$WORK/rprep-base.log" \
    || { tail -12 "$WORK/rprep-base.log"; bad "prepare base (from restic) failed"; }
  $MB --prepare --target-dir="$PREP" --incremental-dir="$RINC1" >/dev/null 2>"$WORK/rprep-inc1.log" \
    || { tail -12 "$WORK/rprep-inc1.log"; bad "prepare inc1 (from restic) failed"; }
  chown -R mysql:mysql "$RT"
  chcon -R -t mysqld_db_t "$RT" 2>/dev/null || true

  # Bring it up and prove the point-in-time content is correct (== snap2).
  mariadbd --no-defaults --datadir="$PREP" --socket="$TSOCK" --pid-file="$TPID" \
    --skip-grant-tables --skip-networking --innodb-buffer-pool-size=128M \
    --user=mysql >"$WORK/tmpd.log" 2>&1 &
  TMPD_PID=$!
  for _ in $(seq 1 90); do [ -S "$TSOCK" ] && break; sleep 1; done
  if [ -S "$TSOCK" ]; then
    RMARK="$(mysql --no-defaults -S "$TSOCK" -N -B -e "SELECT label FROM ${CHURN_DB}._snap_marker ORDER BY id DESC LIMIT 1;" 2>/dev/null)"
    [ "$RMARK" = "snap2" ] && ok "restic-restored chain prepares to the correct point (marker=snap2)" \
                           || bad "restored chain marker='${RMARK}', expected snap2"
  else
    tail -15 "$WORK/tmpd.log"; bad "temp mariadbd on restic-restored datadir didn't come up"
  fi
  cleanup_tmpd; TMPD_PID=""
fi

# ---------------------------------------------------------------------------
step "9. Verdict + dedup readout"
echo "restic stored per backup:  full1=${F1_STORED}  inc1=${I1_STORED}  inc2=${I2_STORED}  full2=${F2_STORED}"
echo "  -> full2 = a second nightly full of a ~${F2_DISK} datadir AFTER ~${CHURN_MIB} MiB of measured churn"
echo "  -> full2 stored should be ~ the (compressed) churn delta, NOT the whole ${F2_DISK} — that's CDC"
echo "     dedup of physical fulls working: nightly fulls cost the day's delta, not the datadir."
echo "repo total on disk: ${REPO_TOTAL}"
df -h /var/lib/mysql | tail -1

printf '\n========== RESULT: %d passed, %d failed ==========\n' "$PASS" "$FAIL"
echo "Clean up:  rm -rf $WORK $RT ; mysql -e 'DROP DATABASE IF EXISTS ${CHURN_DB};'"
[ "$FAIL" -eq 0 ]
