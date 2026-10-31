#!/usr/bin/env bash
#
# preview-console-palette.sh
# --------------------------
# A/B preview of two console highlight palettes so the maintainer can pick what reads well on a
# real terminal. newt/whiptail has NO true 'orange' (only 16 named colours), so the orange-ish
# option is 'brown' (the dark-amber base yellow) and the other is bright 'yellow'.
#
# Each palette is shown as a MENU — the moving highlight bar is exactly what the console menus
# AND the new vertical yes/no confirms use, so it's the only thing worth previewing. There are
# deliberately NO <Yes>/<No> button dialogs here (those were the confusing bit). To move on:
# press Enter on any row, OR Esc — either advances. Both palettes always show.
#
# Usage:  bash preview-console-palette.sh        # run on any box with whiptail
#
set -u

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

# preview <label> <highlight-fg> <highlight-bg> <hint>
preview() {
    export NEWT_COLORS="${base}
actsellistbox=${2},${3}
actlistbox=white,black
button=${2},${3}
actbutton=${2},${3}"
    whiptail --title "Palette ${1}" --notags \
        --menu "Arrow up/down — the moving bar is the highlight (menus + yes/no use it).\n\n${4}" \
        18 70 5 \
        a "Restore this account" \
        b "Back up this account" \
        c "System info" \
        d "Refresh repo stats" \
        e "Quit" \
        3>&1 1>&2 2>&3 || true
}

preview "A  —  WHITE text on ORANGE (brown) bar" white  brown  "Press Enter or Esc  ->  Palette B"
preview "B  —  BLACK text on YELLOW bar"          black  yellow "Press Enter or Esc  ->  Palette C"
preview "C  —  BLACK text on ORANGE (brown) bar"  black  brown  "Press Enter or Esc  ->  finish"

clear
cat <<'EOF'
Palette A = white text on an orange (brown) bar
Palette B = black text on a yellow bar
Palette C = black text on an orange (brown) bar   <- the "mix" (A's bar + B's text)

Tell me which you prefer — A, B, or C — and I'll set the console
+ restore TUI to match.
EOF
