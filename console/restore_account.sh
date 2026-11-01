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
#   restore_account.sh --browse (Browse a backup: mount the repo read-only (restic mount,
#                                FUSE) and open mc — backup left, live right — for single-file
#                                fetches. Nothing is staged: a copied file is read from the
#                                repo on demand. Unmounted when mc exits.)
#

set -u

ENGINE="${ENGINE:-/usr/local/lib/kiss-backup/restic_backup.sh}"
TITLE="Restore an account"
BROWSE=0
[ "${1:-}" = --browse ] && { BROWSE=1; TITLE="Browse a backup"; }

# Same palette as console.sh, but only if unset — inherits the launcher's when run from
# kiss-console, and is self-sufficient standalone (newt's default theme makes the
# focused button hard to tell apart).
: "${NEWT_COLORS:=
root=,black
border=brown,black
window=white,black
title=brightyellow,black
button=black,yellow
actbutton=black,yellow
compactbutton=white,black
listbox=white,black
actlistbox=white,black
sellistbox=white,black
actsellistbox=black,yellow
entry=white,black
label=white,black
checkbox=white,black
actcheckbox=black,yellow
roottext=brown,black
textbox=white,black
acttextbox=black,yellow
helpline=brightyellow,black
}"
export NEWT_COLORS

ui() { whiptail --title "$TITLE" "$@" 3>&1 1>&2 2>&3; }
msg() { whiptail --title "$TITLE" --msgbox "$1" "${2:-12}" 72; }
# Yes/No as a VERTICAL two-row menu that starts on "No" — never whiptail --yesno. Over
# SSH the horizontal <Yes>/<No> toggle can show the highlight on the opposite button
# (an "OK" that cancels, a "No" that proceeds); vertical menus render correctly. Enter
# alone, a stray key or any desync can only cancel. (Same fix as headless'
# account_console confirm(), vps-baseline be6939e.)
confirm() {
    local choice
    choice="$(whiptail --title "$TITLE" --notags --default-item no \
        --menu "$1" "${3:-16}" 72 2 \
        no  "No — cancel, change nothing" \
        yes "${2:-Yes — proceed}" 3>&1 1>&2 2>&3)" || return 1
    [ "$choice" = yes ]
}
# Show a file in a scrollable box (sized to the terminal).
show() {
    local rows cols; rows="$(tput lines 2>/dev/null || echo 24)"; cols="$(tput cols 2>/dev/null || echo 80)"
    whiptail --title "$TITLE — $1" --scrolltext --textbox "$2" "$((rows - 2))" "$((cols - 4))"
}

command -v whiptail >/dev/null 2>&1 || { echo "whiptail not installed" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "needs root" >&2; exit 1; }

[ "$BROWSE" -eq 0 ] || command -v mc >/dev/null 2>&1 \
    || { echo "mc (Midnight Commander) not installed — re-run the installer or: dnf install mc" >&2; exit 1; }

mp=""; mpid=""
unmount() {
    [ -n "$mp" ] || return 0
    fusermount -u "$mp" 2>/dev/null || fusermount3 -u "$mp" 2>/dev/null || umount "$mp" 2>/dev/null
    [ -n "$mpid" ] && { kill "$mpid" 2>/dev/null; wait "$mpid" 2>/dev/null; }
    rmdir "$mp" 2>/dev/null; mp=""
}
out="$(mktemp)"; trap 'unmount; rm -f "$out"' EXIT

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
verb=Restore; [ "$BROWSE" -eq 1 ] && verb=Browse
snap="$(ui --menu "$verb $unit from which backup?" 22 72 14 "${smenu[@]}")" || exit 0
args=("$unit")
[ "$snap" = latest ] || args+=(--snapshot "$snap")

# Browse: mount the repo read-only (nothing copied locally), then mc with the backup on
# the left and the live account on the right. F5 reads just that file from the repo.
if [ "$BROWSE" -eq 1 ]; then
    loc="$("$ENGINE" browse-unit "${args[@]}" 2>"$out" | head -1)"
    sid="${loc%%$'\t'*}"; first="${loc#*$'\t'}"
    [[ "$sid" =~ ^[0-9a-f]{8}$ ]] || { show "could not find $unit in that backup" "$out"; exit 1; }
    mp="$(mktemp -d /run/kiss-backup-browse.XXXXXX)" || exit 1
    "$ENGINE" mount "$mp" >"$out" 2>&1 &
    mpid=$!
    whiptail --title "$TITLE" --infobox "Opening the backup (read-only, nothing is copied)..." 7 60
    for _ in $(seq 60); do
        [ -d "$mp/ids" ] && break
        kill -0 "$mpid" 2>/dev/null || break
        sleep 1
    done
    left="$mp/ids/$sid$first"
    if [ ! -d "$left" ]; then
        show "could not open the backup" "$out"
        exit 1
    fi
    right="$first"; [ -d "$right" ] || right="$(dirname "$first")"
    msg "$unit's backup ($sid) is open read-only.\n\nLeft panel:  the BACKUP\nRight panel: the LIVE account\n\nCopy a file across with F5 (keep 'Preserve attributes' ticked) — only that file is fetched from the repo. Quit mc with F10 to close the backup." 15
    mc --nosubshell "$left" "$right"
    exit 0
fi

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

# 4. Merge or mirror — starts on the adapter's recommended mode (DirectAdmin: merge;
#    velocity/headless: mirror, its exact-match restore). Always passed explicitly.
defmode=merge
"$ENGINE" adapter-info 2>/dev/null | grep -q '"default_restore_mode":"mirror"' && defmode=mirror
mode="$(ui --notags --default-item "$defmode" --menu \
    "How should $unit be put back?$( [ "$defmode" = mirror ] && printf '\n\nRecommended here: EXACTLY as it was (an injected file can'"'"'t survive).')" 14 72 2 \
    merge  "Merge — restore items, keep anything newer$( [ "$defmode" = merge ] && printf ' (recommended)')" \
    mirror "Exactly as it was — DELETE files/tables created since$( [ "$defmode" = mirror ] && printf ' (recommended)')")" || exit 0
args+=("--$mode")

# 5. Preview.
"$ENGINE" restore-unit "${args[@]}" --dry-run >"$out" 2>&1
rc=$?
show "preview (nothing changed yet)" "$out"
[ "$rc" -eq 0 ] || { msg "The preview failed — nothing was changed.\nThe output above shows why." 9; exit 1; }

# 6. Confirm + restore.
confirm "Restore $unit now, as previewed?\n\nA safety copy of the account's current state is taken first, so this can be undone (pick that safety copy as the backup to restore)." \
    "Yes — restore $unit now" 15 || exit 0
"$ENGINE" restore-unit "${args[@]}" --yes >"$out" 2>&1
rc=$?
show "result" "$out"
if [ "$rc" -eq 0 ]; then msg "Restore of $unit finished." 8
else msg "The restore FAILED (exit $rc). The output above shows where; a kept workdir is named in it." 10; fi
