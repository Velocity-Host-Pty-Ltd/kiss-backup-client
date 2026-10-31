#!/usr/bin/env bash
#
# brand_header_v1.sh — the Velocity Host brand header (char-style ASCII lightning
# bolt + VELOCITY HOST + KISS tagline + website/support/phone). SINGLE SOURCE OF
# TRUTH for the brand block used by the SSH welcome (ssh_access_foundation ->
# /etc/motd) and every ops email (vps_notify_v1.sh prepends the plain form).
#
# Version: 1.5.0
# 1.5.0 - MOTD board (drop-ins) now renders BELOW the art with a blank line
#         between sections, instead of woven into the 6 bolt-tail rows. Fixes
#         congestion + the 6-row cap that dropped overflow; host line stays woven.
#
# Summary: Renders the Velocity Host brand header — char-style ASCII lightning bolt + VELOCITY HOST + KISS tagline + website/support/phone — in ANSI truecolour for the /etc/motd SSH welcome, plain for terminal-style email, or HTML-escaped + brand-coloured (inline-style <span>s) for a monospace <pre> in an HTML email part; install-motd writes /etc/motd idempotently.
#
# Three render targets from ONE definition (one palette, two encodings):
#   * terminal / MOTD — ANSI truecolour (lighter-orange bolt, darker-orange
#     tagline; wordmark + contacts default). Terminals do ANSI, so colour is fine.
#   * email (text/plain) — PLAIN (no ANSI; colour codes are garbage in mail). The
#     art is pure ASCII (Debian-style distinct characters, not Unicode blocks) so
#     it renders identically in a terminal and in a monospace mail client.
#   * email (text/html) — the same art, HTML-escaped (&,<,> entities) and wrapped
#     in inline-style <span>s that mirror the MOTD palette (HEX_BOLT/HEX_TAG). For
#     embedding inside a <pre>; the caller (vps_notify_v1.sh) owns the <pre> and
#     document wrapper. Proportional-font clients render the bolt monospace +
#     coloured; a client that strips colour still gets the aligned art.
#
# Modes:
#   motd          print the colour brand block + host context line to stdout
#   plain         print the plain (no-ANSI) brand block to stdout (for email)
#   html          print the brand block HTML-escaped + brand-coloured (for a <pre>
#                 in HTML mail)
#   install-motd  write the colour MOTD to /etc/motd, only when it differs
#                 (prints RESULT=changed|unchanged for the converge front end)
#
# Usage: brand_header_v1.sh <motd|plain|html|install-motd>
#
# Examples:
#   /usr/local/bin/vps-tooling/brand_header_v1.sh motd
#   /usr/local/bin/vps-tooling/brand_header_v1.sh install-motd
#
# Exit:  0 ok / 2 usage or precondition.

set -euo pipefail

readonly MOTD_FILE="${MOTD_FILE:-/etc/motd}"
readonly KBC_CONFIG_DIR="${KBC_CONFIG_DIR:-/etc/kiss-backup}"
readonly MOTD_EXTRA_DIR="${MOTD_EXTRA_DIR:-$KBC_CONFIG_DIR/motd.d}"   # MOTD-only "you are here" board drop-ins

# --- Brand palette (sampled from the logo) -----------------------------------
ESC=$'\033'
readonly ESC
readonly RST="${ESC}[0m"
readonly C_BOLT="${ESC}[38;2;241;149;46m"   # #f1952e — lighter orange (bolt)
readonly C_TAG="${ESC}[38;2;244;118;33m"    # #F47621 — darker orange (tagline)
readonly HEX_BOLT="#f1952e"                  # same palette, hex form for HTML mail
readonly HEX_TAG="#F47621"
readonly PAD=31                              # right column starts at column PAD+1

# --- Brand content -----------------------------------------------------------
readonly WORDMARK="V E L O C I T Y   H O S T"
readonly TAGLINE="KISS — Keeping IT Simple & Successful. Since 2007"
readonly URL="https://velocityhost.com.au"
readonly EMAIL="support@velocityhost.com.au"
readonly PHONE="1800-937-348"

# The char-style bolt (pure ASCII; distinct characters, Debian-style).
bolt_rows=(
"              :-=:"
"            .:===."
"           .-===-."
"          :==-==:"
"        .-=-..==."
"       :--:. :=-"
"     .-=-.  .-=:"
"    :--:.   :=-."
"  .---.     :==--------:"
" :--:.      .::::::-==-:"
".:--.              .-=-."
":-=-:::::::.      .:=-:"
":---------=:     .-=-."
"        .--:   .:--:"
"        :--.  .-=-."
"        --:  :--:"
"       .--..---."
"       :--:--:"
"       -----."
"      .---:"
"      .--."
)
# Right-column text keyed by bolt row index (0-based).
declare -A row_text=(
  [4]="${WORDMARK}"
  [6]="${TAGLINE}"
  [9]="${URL}"
  [10]="${EMAIL}"
  [11]="${PHONE}"
)
# MOTD-only dynamic right-column lines (the "you are here" board): woven into the
# empty bolt-tail rows by do_motd. Left empty for the plain/html email forms.
declare -A extra_rows=()

# HTML-escape stdin (&,<,> -> entities). Uses sed, whose `&`-in-replacement
# semantics are stable across bash 4.x (fleet) and 5.2+ (dev); bash's own
# ${var//&/...} is NOT — 5.2's patsub_replacement treats a bare & as the match.
html_escape() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# HTML-escape a single string argument (for inline span building).
esc() { printf '%s' "$1" | html_escape; }

# Render the brand block as HTML-escaped lines with inline-coloured <span>s that
# mirror the MOTD palette (bolt orange + BOLD so it stands out on a white email,
# tagline darker orange, wordmark/contacts inherit). For embedding in the caller's
# <pre>; the caller's <pre> sets the base colour, so this is background-agnostic
# (works light or dark). Spans are NOT escaped; only the text content is. Degrades
# gracefully: a client that strips colour still gets the aligned monospace art.
render_html() {
  local i b t bp
  local bolt='color:'"${HEX_BOLT}"'; font-weight:bold'   # bolt span style (bold)
  for i in "${!bolt_rows[@]}"; do
    b="${bolt_rows[$i]}"; t="${row_text[$i]:-}"
    if [[ -n "${t}" ]]; then
      printf -v bp '%-*s' "${PAD}" "${b}"          # pad bolt column for alignment
      if [[ "${i}" -eq 6 ]]; then                  # tagline row: bold bolt + tagline text
        printf '<span style="%s">%s</span><span style="color:%s">%s</span>\n' \
          "${bolt}" "$(esc "${bp}")" "${HEX_TAG}" "$(esc "${t}")"
      else                                         # wordmark/contacts: bold bolt + inherited text
        printf '<span style="%s">%s</span>%s\n' "${bolt}" "$(esc "${bp}")" "$(esc "${t}")"
      fi
    else                                           # bolt-only rows
      printf '<span style="%s">%s</span>\n' "${bolt}" "$(esc "${b}")"
    fi
  done
}

# Render the block. $1 = color | plain. (html = plain piped through html_escape.)
render_block() {
  local mode="$1" i b t
  for i in "${!bolt_rows[@]}"; do
    b="${bolt_rows[$i]}"; t="${row_text[$i]:-}"
    [[ "${mode}" == color && -z "${t}" ]] && t="${extra_rows[$i]:-}"   # MOTD board beside the bolt tail
    if [[ "${mode}" == color ]]; then
      if [[ "${i}" -eq 6 ]]; then                    # tagline row: bolt light, text dark
        printf '%s%-*s%s%s%s%s\n' "${C_BOLT}" "${PAD}" "${b}" "${RST}" "${C_TAG}" "${t}" "${RST}"
      elif [[ -n "${t}" ]]; then                     # wordmark/contact rows: bolt light, text default
        printf '%s%-*s%s%s\n' "${C_BOLT}" "${PAD}" "${b}" "${RST}" "${t}"
      else                                           # bolt-only rows
        printf '%s%s%s\n' "${C_BOLT}" "${b}" "${RST}"
      fi
    else
      if [[ -n "${t}" ]]; then printf '%-*s%s\n' "${PAD}" "${b}" "${t}"
      else printf '%s\n' "${b}"; fi
    fi
  done
}

# A stable per-box context line (no volatile timestamp -> idempotent). Emitted BARE
# (no indent) so do_motd can weave it into the bolt column, aligned with the
# wordmark/contacts/board above it rather than hanging at the far left.
host_line() {
  local h ed
  h="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo '?')"
  ed="$(cldetect --detect-edition 2>/dev/null || true)"
  if [[ -z "${ed}" ]]; then
    # shellcheck disable=SC1091
    ed="$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-Linux}" )"
    [[ -n "${ed}" ]] || ed="Linux"
  fi
  printf '%s · %s\n' "${h}" "${ed}"
}

# MOTD "you are here" board: sorted *.txt drop-ins from MOTD_EXTRA_DIR (key paths,
# tool pointers, status) written by roles, woven into the empty right column of the
# bolt-TAIL rows so they sit IN PARALLEL WITH THE BOLT under the branding — not
# dangling above the prompt. Starts at row 13, leaving row 12 blank under the phone
# contact so it isn't jumbled. MOTD-ONLY (the plain/html email forms never call
# this, so KISS / cross-infra emails stay pure brand). Keep drop-in lines short —
# they render at the contact column (~32), so ~45 chars keeps them inside 80 cols.
# A brand-orange ASCII dash rule — the MOTD footer divider before the prompt
# (ANSI; MOTD-only, like the rest of do_motd). ASCII '-' to match the char-style
# art, not Unicode bars.
motd_rule() {
  local dashes
  # 80 wide = col 1 to the tagline's right edge (PAD 31 + 49-char tagline), so the
  # rule squares off under the "…Since 2007" column.
  dashes="$(printf '%*s' 80 '' | tr ' ' '-')"
  printf '%s%s%s\n' "${C_BOLT}" "${dashes}" "${RST}"
}

# Woven board lines render at the contact column (PAD+1 = col 32); clip to 49 chars
# so they END at or before col 80 — the tagline's "…Since 2007" edge — and the block
# stays square no matter what a drop-in contains.
readonly BOARD_MAX=49

do_motd() {
  extra_rows=()
  local hl; hl="$(host_line)"
  extra_rows[13]="${hl:0:BOARD_MAX}"        # host context stays woven at row 13
  render_block color                        # brand art + wordmark / contacts / host line

  # Status board BELOW the art: the "you are here" drop-ins render under the block
  # with ONE BLANK LINE BETWEEN SECTIONS, so entries are legible instead of crammed
  # into the 6 bolt-tail rows (which capped the board and dropped overflow). Each
  # sorted *.txt drop-in is one section, printed at a 2-space margin. Full width
  # (no 49-col clip needed here). MOTD-only — plain/html email forms never call this.
  if [[ -d "${MOTD_EXTRA_DIR}" ]]; then
    local f ln any=0
    for f in "${MOTD_EXTRA_DIR}"/*.txt; do
      [[ -e "${f}" ]] || continue
      [[ "${any}" -eq 0 ]] || printf '\n'   # blank separator between sections
      any=1
      while IFS= read -r ln; do printf '  %s\n' "${ln}"; done < "${f}"
    done
    [[ "${any}" -eq 0 ]] || printf '\n'     # gap before the divider
  fi
  motd_rule                                 # brand-orange divider; install adds one blank after
}

do_install_motd() {
  [[ $(id -u) -eq 0 ]] || { printf 'ERROR: install-motd must run as root\n' >&2; exit 2; }
  local new
  new="$(do_motd)"
  # Compare on content: $(cat) strips trailing newlines, so the 2-line bottom gap
  # we write below doesn't defeat idempotency.
  if [[ -f "${MOTD_FILE}" && "$(cat "${MOTD_FILE}")" == "${new}" ]]; then
    printf 'RESULT=unchanged\n'; return 0
  fi
  { printf '%s\n' "${new}"; printf '\n'; } > "${MOTD_FILE}"   # +1 blank after the rule = gap before the prompt
  chmod 0644 "${MOTD_FILE}"
  printf 'RESULT=changed\n'
}

usage() { grep -E '^#( |$)' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in
  motd)           do_motd ;;
  plain)          render_block plain ;;
  html)           render_html ;;
  install-motd)   do_install_motd ;;
  -h|--help|help) usage ;;
  *)              usage >&2; exit 2 ;;
esac
