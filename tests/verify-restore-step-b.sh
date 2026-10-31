#!/usr/bin/env bash
#
# verify-restore-step-b.sh
# ------------------------
# Proves the on-demand guided-restore "Step B" (the actual overwrite) END TO END
# by driving the REAL engine subcommands — backup_ondemand_v1.sh restore-files /
# restore-db — not a reimplementation. Two non-negotiables are asserted:
#
#   FILES  in-place restore is EXACT-MATCH, not a merge: a file that did NOT exist
#          in the restore point is REMOVED (the hack-recovery requirement — an
#          injected backdoor can't survive a clean-state restore), a deleted file
#          comes back byte-identical, and a modified file is rolled back.
#   DB     a logical dump is VERIFIED COMPLETE, then the DB is drop-recreated and
#          reimported: a table that wasn't in the dump is GONE afterwards, every
#          original table is back, and row data survives the drop+reimport.
#
# Both paths must leave a `pre-restore-*` auto-checkpoint behind (a restore is
# itself rollback-able — never a blind overwrite).
#
# METHOD (nets to ZERO): checkpoint the account's CURRENT state, perturb it with
# identifiable markers (plant a backdoor file, delete + modify real files; create
# a marker DB table), restore back to that checkpoint, then assert the markers are
# gone and the real data is intact. Post-run the account == its pre-run state
# (plus two additive restic snapshots: the test checkpoint + the pre-restore one).
#
# SAFETY: run as root on a TEST box. It overwrites the account's live docroot + DBs
# with a checkpoint of THEIR OWN current state, so the net change is zero. If the
# script dies mid-perturbation, recover by hand:
#   backup_ondemand_v1.sh restore-files <acct> <SNAP_F>
#   backup_ondemand_v1.sh restore-db    <acct> <SNAP_D>
# (the IDs are printed as the test runs). Idempotent: re-running cleans its markers.
#
# Footprint: drives real restic + a full DB drop/reimport — expect several minutes
# and transient stage space under /var/lib/vps-backups/restore.
#
# Usage:  sudo bash verify-restore-step-b.sh [account]      # default account: test4
#
set -uo pipefail

ACCOUNT="${1:-test4}"
ENGINE="${ENGINE:-/usr/local/bin/vps-tooling/backup_ondemand_v1.sh}"
TENANT_DIR="${TENANT_DIR:-/var/log/tenant-management}"
MYSQL="mysql -N -B"

PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS+1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL+1)); }
step() { printf '\n=== %s ===\n' "$1"; }
die()  { printf '\n\033[31mABORT:\033[0m %s\n' "$1" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -x "$ENGINE" ] || die "engine not found/executable: $ENGINE (deploy it, or set ENGINE=)"

# Resolve docroot + DB prefix the same way the engine does (record is the source,
# disk is the witness). prefix == account by design (handover §8).
record_field() {
    grep -m1 "\"$1\"[[:space:]]*:" "$2" 2>/dev/null \
        | sed -E 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/'
}
INFO="${TENANT_DIR}/${ACCOUNT}_info.json"
[ -r "$INFO" ] || die "no tenant record for '$ACCOUNT' at $INFO"
DOCROOT="$(record_field docroot "$INFO")"; DOCROOT="${DOCROOT:-/home/${ACCOUNT}/public_html}"
PREFIX="$(record_field db_prefix "$INFO")"; PREFIX="${PREFIX:-$ACCOUNT}"
[ -d "$DOCROOT" ] || die "docroot missing on disk: $DOCROOT"

# Newest snapshot ID carrying a given on-demand label (parse the engine's own `list`).
snap_by_label() { "$ENGINE" list "$ACCOUNT" | awk -v l="label:$1" 'index($0,l){print $1; exit}'; }
# Does any pre-restore-* checkpoint of the given kind exist now?
have_pre_restore() { "$ENGINE" list "$ACCOUNT" | grep -q "label:pre-restore-"; }

printf 'verify-restore-step-b  account=%s  docroot=%s  prefix=%s\n' "$ACCOUNT" "$DOCROOT" "$PREFIX"
"$ENGINE" list "$ACCOUNT" >/dev/null 2>&1 || die "engine cannot list '$ACCOUNT' (repo unreachable / backups not configured?)"

# ===========================================================================
step "1. FILES — checkpoint current docroot"
LBL_F="stepb-files-verify"
"$ENGINE" checkpoint "$ACCOUNT" --kind files --label "$LBL_F" >/dev/null || die "files checkpoint failed"
SNAP_F="$(snap_by_label "$LBL_F")"
[ -n "$SNAP_F" ] && ok "files checkpoint captured (snapshot $SNAP_F)" || { bad "could not find files checkpoint"; SNAP_F=""; }

if [ -n "$SNAP_F" ]; then
    step "2. FILES — perturb the live docroot (backdoor + delete + modify)"
    JUNK="$DOCROOT/zzz-stepb-backdoor.php"
    VICT="$(find "$DOCROOT" -maxdepth 1 -type f ! -name 'zzz-stepb-*' | sort | sed -n 1p)"
    MOD="$(find "$DOCROOT"  -maxdepth 1 -type f ! -name 'zzz-stepb-*' | sort | sed -n 2p)"
    [ -n "$VICT" ] && [ -n "$MOD" ] || die "need >=2 files directly in $DOCROOT to run the files test"
    VICT_SUM="$(sha256sum "$VICT" | awk '{print $1}')"
    MOD_SUM="$(sha256sum "$MOD"  | awk '{print $1}')"
    printf '<?php /* fake injected backdoor */ ?>\n' > "$JUNK"
    rm -f "$VICT"
    printf '\n/* stepb perturbation */\n' >> "$MOD"
    printf '  planted %s, deleted %s, modified %s\n' "${JUNK##*/}" "${VICT##*/}" "${MOD##*/}"

    step "3. FILES — restore-files (in-place, if-changed --delete)"
    "$ENGINE" restore-files "$ACCOUNT" "$SNAP_F" || bad "restore-files exited non-zero"

    step "4. FILES — assertions"
    [ ! -e "$JUNK" ] && ok "injected backdoor REMOVED (exact-match --delete)" \
                     || bad "backdoor survived the restore: $JUNK"
    if [ -e "$VICT" ] && [ "$(sha256sum "$VICT" | awk '{print $1}')" = "$VICT_SUM" ]; then
        ok "deleted file restored byte-identical (${VICT##*/})"
    else
        bad "deleted file not faithfully restored (${VICT##*/})"
    fi
    if [ "$(sha256sum "$MOD" | awk '{print $1}')" = "$MOD_SUM" ]; then
        ok "modified file rolled back to snapshot (${MOD##*/})"
    else
        bad "modified file not rolled back (${MOD##*/})"
    fi
    have_pre_restore && ok "pre-restore auto-checkpoint exists (files restore is rollback-able)" \
                     || bad "no pre-restore checkpoint after files restore"
fi

# ===========================================================================
step "5. DB — checkpoint current databases"
account_dbs() { $MYSQL -e 'SHOW DATABASES' | grep -E "^${PREFIX}_" | grep -Ev '^(information_schema|performance_schema|mysql|sys)$' || true; }
table_set()   { for d in $(account_dbs); do $MYSQL -e "SHOW TABLES FROM \`$d\`" | sed "s/^/$d|/"; done | sort; }

DBS="$(account_dbs)"
if [ -z "$DBS" ]; then
    printf '  (account has no %s_* databases — skipping DB test)\n' "$PREFIX"
else
    LBL_D="stepb-db-verify"
    "$ENGINE" checkpoint "$ACCOUNT" --kind db --label "$LBL_D" >/dev/null || die "db checkpoint failed"
    SNAP_D="$(snap_by_label "$LBL_D")"
    [ -n "$SNAP_D" ] && ok "db checkpoint captured (snapshot $SNAP_D)" || { bad "could not find db checkpoint"; SNAP_D=""; }

    if [ -n "$SNAP_D" ]; then
        TBLS_BEFORE="$(table_set | sha256sum | awk '{print $1}')"
        TARGET_DB="$(printf '%s\n' "$DBS" | sed -n 1p)"
        WTBL="$($MYSQL -e "SHOW TABLES FROM \`$TARGET_DB\`" | sed -n 1p)"
        WCNT_BEFORE=""
        [ -n "$WTBL" ] && WCNT_BEFORE="$($MYSQL -e "SELECT COUNT(*) FROM \`$TARGET_DB\`.\`$WTBL\`")"

        step "6. DB — perturb (create a marker table not in the dump)"
        $MYSQL -e "CREATE TABLE IF NOT EXISTS \`$TARGET_DB\`.\`_stepb_marker\` (id INT)" \
            && printf '  created %s._stepb_marker\n' "$TARGET_DB" || die "could not create marker table"

        step "7. DB — restore-db (verify dump -> drop-recreate -> import)"
        "$ENGINE" restore-db "$ACCOUNT" "$SNAP_D" || bad "restore-db exited non-zero"

        step "8. DB — assertions"
        if $MYSQL -e "SHOW TABLES FROM \`$TARGET_DB\` LIKE '_stepb_marker'" | grep -q _stepb_marker; then
            bad "marker table survived (drop-recreate did not happen)"
        else
            ok "marker table GONE — DB drop-recreated from the verified dump"
        fi
        [ "$(table_set | sha256sum | awk '{print $1}')" = "$TBLS_BEFORE" ] \
            && ok "table set restored exactly (all originals back, marker removed)" \
            || bad "table set differs from the checkpoint"
        if [ -n "$WTBL" ]; then
            WCNT_AFTER="$($MYSQL -e "SELECT COUNT(*) FROM \`$TARGET_DB\`.\`$WTBL\`")"
            [ "$WCNT_AFTER" = "$WCNT_BEFORE" ] \
                && ok "row data survived drop+reimport ($TARGET_DB.$WTBL = $WCNT_AFTER rows)" \
                || bad "row count changed ($TARGET_DB.$WTBL: $WCNT_BEFORE -> $WCNT_AFTER)"
        fi
        have_pre_restore && ok "pre-restore auto-checkpoint exists (db restore is rollback-able)" \
                         || bad "no pre-restore checkpoint after db restore"
        # belt-and-braces: ensure no marker left behind even if an assertion path changed
        $MYSQL -e "DROP TABLE IF EXISTS \`$TARGET_DB\`.\`_stepb_marker\`" 2>/dev/null || true
    fi
fi

# ===========================================================================
step "9. Result"
printf '\n========== RESULT: %d passed, %d failed ==========\n' "$PASS" "$FAIL"
echo "Test snapshots left in the repo (additive): label:stepb-files-verify, label:stepb-db-verify, label:pre-restore-*"
echo "List them:  $ENGINE list $ACCOUNT"
[ "$FAIL" -eq 0 ]
