#!/bin/bash
#
# Account Restore (console screen)
# Version: 1.0.0
# Script Name: console/restore_account.sh
# Project: KISS-Backup-Client
# Summary: Guided whiptail front end to the engine's per-account restore: pick an
#   account, a snapshot, what to restore and how, see the dry run, confirm, restore.
#
# Purpose:
#   The operator/reseller face of `restic_backup.sh restore-unit` (docs/architecture.md
#   §2.2). It only collects choices and shows output — the engine plans, stages, takes
#   the pre-restore safety snapshot and calls the adapter. Every restore is previewed
#   (--dry-run) before the operator confirms the real run (--yes).
#
# Usage:
#   restore_account.sh          (launched from kiss-console; needs root)
#

set -u

ENGINE="${ENGINE:-/usr/local/lib/kiss-backup/restic_backup.sh}"
TITLE="Restore an account"

ui() { whiptail --title "$TITLE" "$@" 3>&1 1>&2 2>&3; }
msg() { whiptail --title "$TITLE" --msgbox "$1" "${2:-12}" 72; }
# Show a file in a scrollable box (sized to the terminal).
show() {
    local rows cols; rows="$(tput lines 2>/dev/null || echo 24)"; cols="$(tput cols 2>/dev/null || echo 80)"
    whiptail --title "$TITLE — $1" --scrolltext --textbox "$2" "$((rows - 2))" "$((cols - 4))"
}

command -v whiptail >/dev/null 2>&1 || { echo "whiptail not installed" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "needs root" >&2; exit 1; }

out="$(mktemp)"; trap 'rm -f "$out"' EXIT

# 1. Account.
mapfile -t units < <("$ENGINE" list-units 2>"$out")
if [ "${#units[@]}" -eq 0 ]; then
    msg "No accounts to restore.\n\n$(tail -3 "$out")\n\nPer-account restore needs ADAPTER set in /etc/kiss-backup/backup.env (e.g. ADAPTER=directadmin)." 14
    exit 0
fi
menu=()
for u in "${units[@]}"; do
    IFS=$'\t' read -r id name kind <<<"$u"
    menu+=("$id" "$name  [$kind]")
done
unit="$(ui --menu "Which account?" 20 72 12 "${menu[@]}")" || exit 0

# 2. Snapshot — file snapshots and pre-restore safety snapshots, newest first.
#    (DB dumps are matched to the chosen file snapshot by the engine.)
mapfile -t snaps < <("$ENGINE" snapshots --compact 2>/dev/null \
    | awk '/^[0-9a-f]{8} / && $5 != "db-dump" { print }' | tac | head -30)
smenu=("latest" "Most recent backup (recommended)")
for s in "${snaps[@]}"; do
    read -r sid sdate stime _host stag _ <<<"$s"
    label="$sdate $stime"
    [ "$stag" = "pre-restore" ] && label="$label  (safety copy taken before a restore)"
    smenu+=("$sid" "$label")
done
snap="$(ui --menu "Restore $unit from which backup?" 22 72 14 "${smenu[@]}")" || exit 0
args=("$unit")
[ "$snap" = latest ] || args+=(--snapshot "$snap")

# 3. What to restore.
what="$(ui --menu "What should be restored for $unit?" 15 72 4 \
    both    "Files and databases" \
    files   "Files only (website, mail, settings)" \
    dbs     "Databases only" \
    folder  "One folder or file only")" || exit 0
case "$what" in
    files) args+=(--files-only) ;;
    dbs)   args+=(--dbs-only) ;;
    folder)
        path="$(ui --inputbox "Full path of the folder or file to restore (must be inside $unit's home or settings):" \
            11 72 "/home/$unit/domains/")" || exit 0
        [ -n "$path" ] || exit 0
        args+=(--files-only --only "$path") ;;
esac

# 4. Merge or mirror.
if ui --defaultno --yesno "Make it EXACTLY as it was?\n\nYes = mirror: files and tables created since that backup are DELETED.\nNo  = merge (recommended): restored items are put back, newer extras are kept." 13 72; then
    args+=(--mirror)
fi

# 5. Preview.
"$ENGINE" restore-unit "${args[@]}" --dry-run >"$out" 2>&1
rc=$?
show "preview (nothing changed yet)" "$out"
[ "$rc" -eq 0 ] || { msg "The preview failed — nothing was changed.\nThe output above shows why." 9; exit 1; }

# 6. Confirm + restore.
ui --defaultno --yesno "Restore $unit now, as previewed?\n\nA safety copy of the account's current state is taken first, so this can be undone (pick that safety copy as the backup to restore)." 12 72 || exit 0
"$ENGINE" restore-unit "${args[@]}" --yes >"$out" 2>&1
rc=$?
show "result" "$out"
if [ "$rc" -eq 0 ]; then msg "Restore of $unit finished." 8
else msg "The restore FAILED (exit $rc). The output above shows where; a kept workdir is named in it." 10; fi
