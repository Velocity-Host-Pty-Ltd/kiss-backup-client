#!/usr/bin/env bash
#
# verify-restic-forget-prune.sh
# -----------------------------
# Verifies restic RETENTION end to end (docs/backups_handover.md §12 + §13):
#   * the GFS policy (§13 default "B": --keep-hourly 24 --keep-daily 14
#     --keep-weekly 8 --keep-monthly 12) keeps the right SHAPE of snapshots,
#   * `forget` and `prune` are SEPARATE (forget drops snapshot refs instantly /
#     metadata-only; prune is what actually reclaims disk) — and how long prune
#     takes (the scheduling concern: prune locks the repo),
#   * `--keep-within <duration>` semantics.
#
# Method: fabricate a YEAR-plus timeline with `restic backup --time` (no waiting)
# — hourly for 2 days, daily for 3 months, monthly for 14 months — each snapshot
# holding UNIQUE 1 MiB of data (no cross-snapshot dedup) so a forgotten snapshot
# leaves reclaimable data and prune's effect is measurable.
#
# SAFE: self-contained under $WORK; touches no databases, no system state. Local
# restic repo. Run on any box with restic; idempotent (cleans its own $WORK).
#
# Usage:  bash verify-restic-forget-prune.sh
#
set -uo pipefail

WORK="/root/restic-fp-test"
SRC="$WORK/src"
export RESTIC_REPOSITORY="$WORK/repo"
export RESTIC_PASSWORD="restic-fp-test"

# GFS policy "B" (handover §13 default).
KEEP=(--keep-hourly 24 --keep-daily 14 --keep-weekly 8 --keep-monthly 12)

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
step() { printf '\n=== %s ===\n' "$1"; }
die()  { printf '\n\033[31mABORT:\033[0m %s\n' "$1" >&2; exit 1; }

RESTIC="$(command -v restic || true)"
[ -z "$RESTIC" ] && [ -x /usr/local/bin/restic ] && RESTIC=/usr/local/bin/restic
[ -z "$RESTIC" ] && [ -x /usr/local/bin/vps-tooling/restic ] && RESTIC=/usr/local/bin/vps-tooling/restic
[ -n "$RESTIC" ] || die "restic not found"
"$RESTIC" version | head -1

snap_count() { "$RESTIC" snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l; }
repo_bytes() { du -sb "$RESTIC_REPOSITORY" | cut -f1; }
oldest_snap() { "$RESTIC" snapshots --json 2>/dev/null | grep -o '"time":"[0-9-]\{10\}' | sed 's/.*"//' | sort | head -1; }
newest_snap() { "$RESTIC" snapshots --json 2>/dev/null | grep -o '"time":"[0-9-]\{10\}' | sed 's/.*"//' | sort | tail -1; }
mib() { awk -v b="$1" 'BEGIN{printf "%.1f", b/1048576}'; }

# ---------------------------------------------------------------------------
step "0. Clean slate + repo"
rm -rf "$WORK"; mkdir -p "$SRC"
"$RESTIC" init >/dev/null 2>&1 || die "restic init failed"

# ---------------------------------------------------------------------------
step "1. Fabricate a 14-month snapshot timeline (--time backdating)"
take() { # $1 = "N unit ago"
  local when; when="$(date -d "$1 ago" '+%Y-%m-%d %H:%M:%S')" || return 1
  head -c 1048576 /dev/urandom > "$SRC/data.bin"   # unique 1 MiB per snapshot
  "$RESTIC" backup "$SRC" --time "$when" --tag fp >/dev/null 2>&1
}
n=0
for h in $(seq 1 48);  do take "$h hours";  n=$((n+1)); done   # hourly, last 2 days
for d in $(seq 2 90);  do take "$d days";   n=$((n+1)); done   # daily, ~3 months
for m in $(seq 3 14);  do take "$m months"; n=$((n+1)); done   # monthly, ~1yr+
CREATED="$(snap_count)"
echo "attempted ${n} backups; repo holds ${CREATED} snapshots"
echo "timeline: newest=$(newest_snap)  oldest=$(oldest_snap)  size=$(mib "$(repo_bytes)") MiB"
[ "$CREATED" -ge 140 ] && ok "timeline built (${CREATED} snapshots across ~14 months)" \
                       || bad "only ${CREATED} snapshots created (expected ~149)"

# ---------------------------------------------------------------------------
step "2. forget DRY-RUN (GFS policy B) — what would it keep/remove?"
"$RESTIC" forget "${KEEP[@]}" --dry-run 2>&1 | grep -iE 'keep|remove|would' | tail -6 || true

# ---------------------------------------------------------------------------
step "3. forget (real, NO prune) — should be fast + metadata-only"
BYTES_BEFORE="$(repo_bytes)"
t0=$(date +%s)
"$RESTIC" forget "${KEEP[@]}" >/dev/null 2>"$WORK/forget.log" || { tail -8 "$WORK/forget.log"; die "forget failed"; }
FORGET_S=$(( $(date +%s) - t0 ))
KEPT="$(snap_count)"
BYTES_AFTER_FORGET="$(repo_bytes)"
echo "kept ${KEPT}/${CREATED} snapshots in ${FORGET_S}s; repo $(mib "$BYTES_BEFORE") -> $(mib "$BYTES_AFTER_FORGET") MiB"
# forget removes snapshot refs but NOT pack data — size barely moves until prune.
DELTA_FORGET=$(( (BYTES_BEFORE - BYTES_AFTER_FORGET) / 1048576 ))
[ "$DELTA_FORGET" -le 5 ] && ok "forget is metadata-only — repo size ~unchanged (${DELTA_FORGET} MiB) until prune" \
                          || bad "forget reclaimed ${DELTA_FORGET} MiB on its own (unexpected)"
# Shape: GFS keeps a bounded set (<= 24+14+8+12 = 58) spanning ~1 year.
[ "$KEPT" -lt "$CREATED" ] && [ "$KEPT" -le 60 ] && ok "GFS bounded the set (${KEPT} kept, <=58 expected)" \
                                                 || bad "kept ${KEPT} — expected a bounded GFS set (<=~58)"
echo "after forget: newest=$(newest_snap)  oldest=$(oldest_snap)  (monthly tier should reach ~12 months back)"

# ---------------------------------------------------------------------------
step "4. prune — the step that reclaims disk; measure time + reclaim"
t0=$(date +%s)
"$RESTIC" prune >/dev/null 2>"$WORK/prune.log" || { tail -12 "$WORK/prune.log"; die "prune failed"; }
PRUNE_S=$(( $(date +%s) - t0 ))
BYTES_AFTER_PRUNE="$(repo_bytes)"
RECLAIMED=$(( (BYTES_AFTER_FORGET - BYTES_AFTER_PRUNE) / 1048576 ))
echo "prune ${PRUNE_S}s; repo $(mib "$BYTES_AFTER_FORGET") -> $(mib "$BYTES_AFTER_PRUNE") MiB (reclaimed ~${RECLAIMED} MiB)"
FORGOTTEN=$(( CREATED - KEPT ))
[ "$RECLAIMED" -ge $(( FORGOTTEN / 2 )) ] && ok "prune reclaimed ~${RECLAIMED} MiB (~${FORGOTTEN} forgotten snaps x ~1 MiB)" \
                                          || bad "prune reclaimed only ${RECLAIMED} MiB for ${FORGOTTEN} forgotten snaps"
"$RESTIC" check >/dev/null 2>"$WORK/check.log" && ok "restic check clean after forget+prune" \
                                               || { tail -8 "$WORK/check.log"; bad "check found errors post-prune"; }

# ---------------------------------------------------------------------------
step "5. --keep-within semantics (secondary)"
# On the now-pruned repo, show how many a duration-based policy would keep.
KW="$("$RESTIC" forget --keep-within 30d --dry-run 2>&1 | grep -ioE 'keep [0-9]+ snapshots' | grep -oE '[0-9]+' | head -1)"
echo "--keep-within 30d would keep ${KW:-?} snapshots (everything timestamped within 30 days)"

# ---------------------------------------------------------------------------
step "6. Verdict"
echo "forget: ${FORGET_S}s (metadata)   prune: ${PRUNE_S}s (reclaim ~${RECLAIMED} MiB)"
echo "snapshots: ${CREATED} created -> ${KEPT} kept by GFS policy B"
df -h "$WORK" 2>/dev/null | tail -1

printf '\n========== RESULT: %d passed, %d failed ==========\n' "$PASS" "$FAIL"
echo "Clean up:  rm -rf $WORK"
[ "$FAIL" -eq 0 ]
