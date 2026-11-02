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
BROWSE=0; CKPT=0
case "${1:-}" in
    --browse)     BROWSE=1; TITLE="Browse a backup" ;;
    --checkpoint) CKPT=1;   TITLE="Back up an account now" ;;
esac
# Who is at the keyboard — recorded in the job's log (audit: who restored / checkpointed).
ACTOR="${SUDO_USER:-$(logname 2>/dev/null || id -un)}"

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

# Restore-point picker (headless: "a checkpoint is a checkpoint"): scheduled backups,
# this account's checkpoints and safety copies, newest first, from `points <unit> files|db`.
# Echoes the chosen id; $1 = files|db, $2 = prompt, $3 = optional extra first entry "tag|text".
pick_point() {
    local scope="$1" prompt="$2" extra="${3:-}" id when src label n=0
    local -a pm=()
    [ -n "$extra" ] && pm+=("${extra%%|*}" "${extra#*|}")
    while IFS=$'\t' read -r id when src label; do
        [ -n "$id" ] || continue
        [[ "$id" == hourly:* ]] && continue          # hourly DB restore: CLI only for now
        n=$((n + 1)); [ "$n" -gt 40 ] && break
        [ -n "$label" ] && [ "$label" != pre-restore ] && src="$src: $label"
        pm+=("$id" "$when  $src")
    done < <("$ENGINE" points "$unit" "$scope" 2>/dev/null)
    if [ "${#pm[@]}" -eq 0 ]; then msg "No $scope restore points for $unit yet." 8; return 1; fi
    ui --menu "$prompt" 22 76 14 "${pm[@]}"
}

# Run the engine as its own systemd job (survives an SSH drop) and follow its log file.
# run_job <job-name> <done-pattern> <engine args...>; returns 0 if the pattern appeared.
run_job() {
    local job="$1" done_re="$2"; shift 2
    local logdir="${BACKUP_RESTORE_STATE:-/var/lib/kiss-backups/restore-status}" log last
    log="$logdir/$unit.log"
    install -d -m 0755 "$logdir"; : > "$log"
    # stderr inherits stdout's handle; a second file: on the same path would overwrite it.
    if ! systemd-run --quiet --collect --unit="$job" -p Type=exec -p StandardOutput="file:$log" \
            -E KBC_ACTOR="$ACTOR" "$ENGINE" "$@" >"$out" 2>&1; then
        show "could not start" "$out"; return 1
    fi
    running() { case "$(systemctl show -p ActiveState --value "$job" 2>/dev/null)" in active|activating|reloading|deactivating) return 0 ;; esac; return 1; }
    sleep 1
    while running; do
        last="$(grep -v '^ *restic: ' "$log" 2>/dev/null | tail -1 | cut -c21-200)"
        whiptail --title "$TITLE" --infobox "Working on $unit ...\n\n${last:-starting}\n\n(Safe to close this screen - the job keeps running.\n Its log: $log)" 12 76
        sleep 3
    done
    cp "$log" "$out"
    show "result" "$out"
    grep -q "$done_re" "$out"
}

# --- Back up an account now: an on-demand checkpoint (headless "Backup" -> scope -> label) ---
if [ "$CKPT" -eq 1 ]; then
    kind="$(ui --menu "Back up $unit now - what?" 14 72 3 \
        full  "Files and databases (same moment - best before risky changes)" \
        db    "Databases only" \
        files "Files only")" || exit 0
    label="$(ui --inputbox "A label for this checkpoint (e.g. pre-plugin-update):" 10 72 "")" || exit 0
    confirm "Save a checkpoint of $unit now?\n\n  what:  $kind\n  label: ${label:-manual}\n\nIt goes into the backup repository and shows up as a restore point." \
        "Yes - back up $unit now" 14 || exit 0
    if run_job "kiss-checkpoint-$unit" "checkpoint saved" checkpoint "$unit" --kind "$kind" --label "${label:-manual}"; then
        msg "Checkpoint of $unit saved.\n\nIt is listed under Restore an account as 'checkpoint: ${label:-manual}'." 10
    else msg "The checkpoint FAILED. The output above shows why." 9; fi
    exit 0
fi

# --- Browse: pick a files restore point ---
args=("$unit")
if [ "$BROWSE" -eq 1 ]; then
    snap="$(pick_point files "Browse $unit from which restore point?" "latest|Most recent backup")" || exit 0
    [ "$snap" = latest ] || args+=(--snapshot "$snap")
fi

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

# 2. What to restore (headless: files / database / both).
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

# 3. Restore point(s): a files list, and for databases its own list.
if [ "$what" != dbs ]; then
    fsel="$(pick_point files "Restore $unit's files from which restore point?" "latest|Most recent backup")" || exit 0
    [ "$fsel" = latest ] || args+=(--snapshot "$fsel")
fi
if [ "$what" = dbs ]; then
    dsel="$(pick_point db "Restore $unit's databases from which restore point? (newest first)")" || exit 0
    args+=(--db-snapshot "$dsel")
elif [ "$what" = both ]; then
    dsel="$(pick_point db "Restore $unit's databases from which restore point?" \
        "match|The same moment as the files (checkpoint) or the nearest dump")" || exit 0
    [ "$dsel" = match ] || args+=(--db-snapshot "$dsel")
fi

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

# 6. Safety snapshot (optional, recommended): the account's current state goes into the
#    repo first, so the restore can be undone and anything newer than the backup (today's
#    mail, orders) can still be fetched from it. Skipping it is the deliberate choice.
safety="$(ui --notags --default-item yes --menu \
    "Take a safety snapshot of $unit's CURRENT state before restoring?\n\nIt lets you undo this restore, or fetch anything newer than the backup (today's mail, orders) afterwards. It is uploaded to the backup repo - no local disk." 16 72 2 \
    yes "Yes - take a safety snapshot first (recommended)" \
    no  "No - restore without one (cannot be undone)")" || exit 0
[ "$safety" = no ] && args+=(--no-safety-snapshot)

# 7. Confirm + restore. Runs as its own systemd job, so a dropped SSH session can't stop
#    it halfway; this screen just follows its progress. restic retries a dropped repo
#    connection itself (3 attempts), then mails the owner.
confirm "Restore $unit now, as previewed?$( [ "$safety" = no ] && printf '\n\nNO safety snapshot - this cannot be undone.')" \
    "Yes - restore $unit now" 14 || exit 0
# Second gate (headless): type the account name.
typed="$(ui --inputbox "Final check - type the account name '$unit' to restore it:" 10 72 "")" || exit 0
[ "$typed" = "$unit" ] || { msg "Name mismatch - nothing was changed." 8; exit 0; }
if run_job "kiss-restore-$unit" "restore of $unit done" restore-unit "${args[@]}" --yes; then
    msg "Restore of $unit finished." 8
else msg "The restore FAILED. The output above shows where.\n\nRun it again from this screen to resume - finished files are skipped." 12; fi
