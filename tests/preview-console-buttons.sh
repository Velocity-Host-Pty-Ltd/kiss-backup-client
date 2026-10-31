#!/usr/bin/env bash
#
# preview-console-buttons.sh
# --------------------------
# Button-focus check for the console palette, run over the SAME SSH session operators use.
# The menu palette preview (preview-console-palette.sh) gives buttons identical colours, so it
# can never show the bug this script tests: on many terminals a bright BACKGROUND (e.g. yellow)
# renders dull, so the FOCUSED button looks dark and the UNFOCUSED one's plain text looks like
# the highlight — "OK is highlighted, Enter cancels".
#
# For each palette: press Tab until the highlight sits on <Ok> or <Cancel>, press Enter, and the
# script reports which button was ACTUALLY pressed. If it says "Cancel" while <Ok> looked
# highlighted, that palette is inverted on your terminal. A summary prints at the end.
#
# Usage:  bash tests/preview-console-buttons.sh
#
set -u
command -v whiptail >/dev/null 2>&1 || { echo "whiptail not installed" >&2; exit 1; }

base='root=,black
border=brown,black
window=white,black
title=brightyellow,black
roottext=brown,black
listbox=white,black
sellistbox=white,black
entry=white,black
label=white,black
textbox=white,black
helpline=brightyellow,black'

results=()
# try <name> <unfocused fg,bg> <focused fg,bg> <description>
try() {
    export NEWT_COLORS="${base}
actlistbox=white,black
actsellistbox=${3}
button=${2}
actbutton=${3}
checkbox=${2}
actcheckbox=${3}
acttextbox=${3}"
    local rc
    whiptail --title "Palette ${1}" --notags --ok-button "Ok" --cancel-button "Cancel" \
        --menu "${4}\n\nPress TAB until <Ok> or <Cancel> is highlighted, note which LOOKS highlighted, then press ENTER." \
        16 74 3 \
        a "Row one" \
        b "Row two" \
        c "Row three" 3>&1 1>&2 2>&3 >/dev/null
    rc=$?
    local pressed; [ "$rc" -eq 0 ] && pressed="Ok" || pressed="Cancel"
    whiptail --title "Palette ${1}" --msgbox "You actually pressed:  ${pressed}\n\nDid that match the button that LOOKED highlighted?" 10 60
    results+=("Palette ${1} (${4%%.*}): pressed ${pressed}")
}

try A "white,black" "black,yellow"    "A = CURRENT: focused black on yellow, unfocused white text."
try B "gray,black"  "black,lightgray" "B = PROPOSED: focused black on light grey, unfocused dim grey text."
try C "white,black" "white,blue"      "C = ALTERNATIVE: focused white on blue, unfocused white text."

clear
printf 'Results (compare with what LOOKED highlighted each time):\n'
printf '  %s\n' "${results[@]}"
printf '\nTell Claude which palettes matched — the matching one becomes the console palette.\n'
