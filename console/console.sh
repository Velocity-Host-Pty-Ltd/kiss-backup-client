#!/bin/bash
#
# Operator Console
# Version: 1.1.3
# Script Name: vps_console_v1.sh
# Project: vps-baseline / headless CloudLinux 8.10 VPS platform
# Summary: A whiptail TUI launcher for the vps-tooling engines — a guided "arrow-down,
#   hit enter" console so a new operator/L1 doesn't have to memorise paths + flags on a
#   no-panel box. The menu is built from DROP-IN descriptors in
#   /etc/vps-tooling/console.d/*.menu (category / title / command / needs_root / order):
#   each engine ships its own entry, so the console grows by dropping a file, not editing
#   this script (the TurnKey Confconsole "plugin" lesson).
#   Stage 2 (1.1.0): a STATUS HEADER (host / edition / IP / web server / uptime / load /
#   account + backup state at a glance, Confconsole-style) and a CATEGORISED menu (sections
#   instead of one flat list). Descriptors gain an optional `category` (default "General")
#   and are grouped under it in `order` sequence; everything stays backward-compatible.
#
# Usage:
#   vps_console_v1.sh            # open the console (default)
#   vps_console_v1.sh --help     # this help
# Examples (run as root for privileged entries):
#   /usr/local/bin/vps-tooling/vps_console_v1.sh
#
# Run as: operator; root for entries marked needs_root. Exit: 0 ok / 1 missing dep / 2 usage.
#
set -u

KBC_CONFIG_DIR="${KBC_CONFIG_DIR:-/etc/kiss-backup}"
CONSOLE_D="${KBC_CONSOLE_D:-$KBC_CONFIG_DIR/console.d}"
BRAND="Velocity Host — Operator Console"
TENANT_DIR="${TENANT_DIR:-/var/log/tenant-management}"
STATS_CACHE="${BACKUP_STATS_CACHE:-/var/lib/kiss-backups/repo-stats}"

# BUTTONS: whiptail draws <Ok>/<Cancel> as newt COMPACT buttons — the FOCUSED one uses
# `button`, the UNFOCUSED ones use `compactbutton`; `actbutton` is never used. Left unset,
# compactbutton falls back to newt's default black-on-white block, so the button you are
# NOT on looks highlighted ("Cancel highlighted, Enter presses Ok"). Measured 2026-10-31
# (newt 0.52.25, pty probe). Keep button = the highlight, compactbutton = plain.
# Velocity Host palette for whiptail/newt. newt supports only the 16 NAMED colours (no hex):
# Palette B (maintainer's pick) — BLACK text on a bright-YELLOW highlight bar (high-contrast),
# brand-orange-ish 'brown' border + brightyellow title. Exported so any whiptail the console
# launches (the backup/restore TUI, confirms) inherits the same look. To switch to "C" (black
# on orange), change the three 'yellow' highlight values below to 'brown'.
export NEWT_COLORS='
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
'

usage() { sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
case "${1:-}" in -h|--help|help) usage 0 ;; "" ) : ;; *) printf 'unknown arg: %s\n' "$1" >&2; usage 2 ;; esac

command -v whiptail >/dev/null 2>&1 || { echo "whiptail not installed — dnf install -y newt" >&2; exit 1; }

# --- status header -----------------------------------------------------------
# Cheap, read-only facts shown above the menu (the Confconsole "info panel" feel). Gathered
# once at start + on the explicit Refresh action — NOT per keystroke, so heavier probes
# (cldetect) don't tax the box every redraw. Each probe degrades to "—" rather than failing.
STATUS=""
gather_status() {
    local host ip edition web up load accts btimer repo
    host="$(hostname -f 2>/dev/null || hostname 2>/dev/null)"
    ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
    # CloudLinux edition is an OPTIONAL enhancement (CL-only). Off CloudLinux (e.g. a
    # DirectAdmin box on AlmaLinux/Debian) cldetect is absent — fall back to the OS name
    # so the field is still meaningful rather than blank.
    if command -v cldetect >/dev/null 2>&1; then
        edition="$(cldetect --detect-edition 2>/dev/null | head -n1)"
    fi
    [ -n "${edition:-}" ] || edition="$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-}" )"
    if   systemctl is-active --quiet lsws  2>/dev/null; then web="LiteSpeed"
    elif systemctl is-active --quiet httpd 2>/dev/null; then web="Apache"
    else web="(none active)"; fi
    # Abbreviate uptime ("3 weeks, 2 days, 6 hours" -> "3w 2d 6h"): whiptail reserves text
    # height by counting NEWLINES, so if this line word-wraps past the box width the LAST
    # status line (Repo:) is pushed out of the reserved area and newt clips it. Keeping
    # every line under the usable width (~72 cols at box width 78) is what keeps Repo: visible.
    up="$(uptime -p 2>/dev/null | sed -e 's/^up //' -e 's/ year\(s\)\?/y/g' -e 's/ month\(s\)\?/mo/g' \
        -e 's/ week\(s\)\?/w/g' -e 's/ day\(s\)\?/d/g' -e 's/ hour\(s\)\?/h/g' -e 's/ minute\(s\)\?/m/g' -e 's/,//g')"
    load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    accts="$(find "$TENANT_DIR" -maxdepth 1 -name '*_info.json' 2>/dev/null | wc -l)"
    if systemctl is-active --quiet kiss-backup.timer 2>/dev/null; then btimer="scheduled"; else btimer="off"; fi
    # Repo dedup/size figures come from the CACHE (instant) — never a live restic scan here.
    # ASCII + compact (arrow -> '->', trim ' stored') keeps the line short and terminal-safe.
    # NB the earlier "newt drops multi-byte lines" theory was DISPROVEN (2026-07-02): the sed
    # converts fine under LC_ALL=C too. The real Repo-line clipping cause was the UPTIME line
    # wrapping (see abbreviation above), which pushed this last line out of the reserved height.
    if [ -s "$STATS_CACHE" ]; then
        local rsum rwhen
        rsum="$(grep -m1 '^REPO_STATS_SUMMARY=' "$STATS_CACHE" | cut -d= -f2- | tr -d '"' | sed -e 's/→/->/g' -e 's/ stored//')"
        rwhen="$(grep -m1 '^REPO_STATS_AS_OF=' "$STATS_CACHE" | cut -d= -f2- | tr -d '"')"
        repo="${rsum}  (as of ${rwhen})"
    else
        repo="(choose 'Refresh repo stats')"
    fi
    # Layout (maintainer's picks 2026-07-02): a blank row under the title bar (a drawn rule
    # was tried and rejected — air, not ink), then Host+Edition adjacent as an "identity
    # block", then Uptime and Repo each spaced by a blank line.
    # The ROW BUDGET is exact: the text area at geometry 24/78/10 is 7 rows, and
    # blank + 2 + blank + 1 + blank + 1 = 7. Anything added here (another blank, a prompt
    # line) pushes past the text area and newt SILENTLY truncates from the bottom —
    # tmux-render any layout change before shipping it (that's how this bug class was
    # finally caught; newt DOES preserve the leading blank line — tested). The old
    # "Select an action" prompt was dropped deliberately.
    STATUS="$(printf '\nHost: %s    IP: %s\nEdition: %s    Web: %s    Backups: %s\n\nUptime: %s    Load: %s    Accounts: %s\n\nRepo: %s' \
        "${host:-—}" "${ip:-—}" "${edition:-—}" "$web" "$btimer" "${up:-—}" "${load:-—}" "$accts" "${repo:-—}")"
}

# Extract a descriptor's fields by sourcing it in a SUBSHELL (descriptors are root-owned
# 0644 config; title + command required). TAB-delimited so a command may contain '|'.
# Emits: category<TAB>order<TAB>title<TAB>command<TAB>needs_root
read_desc() {
    (
        category="General"; title=""; command=""; needs_root=0; order=99
        # shellcheck disable=SC1090
        . "$1" 2>/dev/null
        [ -n "$title" ] && [ -n "$command" ] \
            && printf '%s\t%s\t%s\t%s\t%s\n' \
                "${category:-General}" "${order:-99}" "$title" "$command" "${needs_root:-0}"
    )
}

gather_status
while :; do
    mapfile -t rows < <(
        shopt -s nullglob
        for f in "$CONSOLE_D"/*.menu; do read_desc "$f"; done | sort -t$'\t' -k2,2n
    )
    if [ "${#rows[@]}" -eq 0 ]; then
        whiptail --title "$BRAND" --msgbox "No actions in ${CONSOLE_D}.\nDrop a *.menu descriptor there to add one." 10 64
        exit 0
    fi

    # Build the menu, inserting a section header each time the category changes (so
    # descriptors numbered per category — 10-19 System, 30-39 Backups — group cleanly).
    menu=(); declare -A CMD=() ROOT=(); i=0; lastcat=""
    for ln in "${rows[@]}"; do
        IFS=$'\t' read -r cat _ title cmd needs <<<"$ln"
        if [ "$cat" != "$lastcat" ]; then
            menu+=("sep" "── ${cat} ──")
            lastcat="$cat"
        fi
        i=$((i + 1))
        menu+=("$i" "  ${title}")
        CMD["$i"]="$cmd"; ROOT["$i"]="$needs"
    done
    menu+=("r" "↻ Refresh status")
    menu+=("q" "✕ Quit")

    # --notags hides the internal tag column (1/2/sep/r/q) — only the section headers +
    # item text show, so 'sep' rows render as clean dividers. Selection still returns the tag.
    # Geometry 24 78 10 (PROVEN 2026-07-02, tmux repro): at list-height 14 newt left only ~4
    # rows for the text block and SILENTLY truncated the rest — that's the real reason the
    # Repo: line (and the old Select-an-action prompt) never rendered; the arrow/locale and
    # uptime-wrap theories were both disproven. List-height 10 frees the 7 rows the header
    # needs (see the row-budget note in gather_status), keeps the box at 24 lines (fits an
    # 80×24 rescue/serial console), and if drop-ins ever exceed 10 rows the list scrolls
    # with a scrollbar — header stays intact.
    choice="$(whiptail --title "$BRAND" --notags \
        --menu "${STATUS}" 24 78 10 "${menu[@]}" \
        3>&1 1>&2 2>&3)" || exit 0

    case "$choice" in
        q)   exit 0 ;;
        r)   gather_status; continue ;;
        sep) continue ;;                       # section header row — not selectable
    esac

    cmd="${CMD[$choice]:-}"; needs="${ROOT[$choice]:-0}"
    [ -n "$cmd" ] || continue
    if [ "$needs" = "1" ] && [ "$(id -u)" -ne 0 ]; then
        whiptail --title "$BRAND" --msgbox "That action needs root.\nRe-run the console with sudo." 9 60
        continue
    fi

    clear
    printf '>>> %s\n\n' "$cmd"
    # Descriptors are trusted root-owned config; eval runs the command + its args.
    # shellcheck disable=SC2294
    eval "$cmd"
    printf '\n[done] Press Enter to return to the console...'; read -r _
    gather_status                              # refresh the header after an action runs
done
