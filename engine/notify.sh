#!/bin/bash
#
# Notification Router Engine
# Version: 1.2.3
# Script Name: vps_notify_v1.sh
# Project: vps-baseline / headless CloudLinux 8.10 VPS platform
# Summary: Routes a notification for an event to the correct audience (ops / owner / account-holder) by walking the ownership chain, then sends via the local MTA. Routing + recipient-resolution + send only — callers supply the content. See docs/notification_foundation_handover.md.
#
# Purpose:
#   The procedural core of the notification framework. Given an event id (and,
#   for account-scoped events, an account), it resolves WHO should be told —
#   walking account -> owner -> ops per the §5.1 routing table — honours the
#   critical floor and per-recipient opt-in/out, de-duplicates, ALWAYS audits to
#   journald, and sends via the local send-only MTA (postfix_foundation). It does
#   NOT generate content: callers pass --subject/--body (or --body-file with
#   pre-rendered content). It is event-driven (no polling) and dependency-light
#   (coreutils + grep/sed + logger + sendmail).
#
#   Recipient model (docs §2-§3): each entity owns its address in its own scope.
#     - ops          -> NOTIFY_OPS_EMAIL from /etc/vps-tooling/mail.env
#     - account      -> notify_email in <home>/.config/vps-notify/prefs (tenant-
#                       owned; parsed as UNTRUSTED input — never sourced)
#     - owner         -> notify_owner pointer in the state record:
#                          "house"        -> NOTIFY_OPS_EMAIL (Velocity-direct)
#                          "<reseller-id>"-> /etc/vps-tooling/resellers.d/<id>.conf
#
# Run as: root (reads tenant homes + the root-side state record).
# Exit:   0 on success (incl. "audited, nothing to send"); non-zero on usage /
#         unknown-event / send error.
#
# NOT in scope here (callers / other build steps):
#   - Writing notify_owner / the prefs file (provision_site_v1.sh, create-once).
#   - Rendering HTML reports or welcome bodies (the caller passes --body-file).
#   - The detect->restore self-heal sweep (rides the drift-scan loop, §4.2).
# ----------------------------------------------------------------------------

set -u
set -o pipefail
# Deliberately NOT `set -e`: a single unresolvable recipient must not abort the
# whole run — we resolve best-effort, audit, and send to whoever resolved.

readonly SCRIPT_VERSION="1.2.3"
readonly SCRIPT_NAME="vps_notify_v1.sh"
readonly TAG="kiss-notify"

readonly KBC_CONFIG_DIR="${KBC_CONFIG_DIR:-/etc/kiss-backup}"
readonly TENANT_DIR="/var/log/tenant-management"
readonly MAIL_ENV="${MAIL_ENV:-$KBC_CONFIG_DIR/mail.env}"
readonly RESELLER_DIR="${RESELLER_DIR:-$KBC_CONFIG_DIR/resellers.d}"
readonly HOUSE_CONF="${HOUSE_CONF:-$KBC_CONFIG_DIR/house.conf}"
readonly SENDMAIL="/usr/sbin/sendmail"

readonly PREF_MAX_BYTES=65536
readonly EMAIL_RE='^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,63}$'

# ----------------------------------------------------------------------------
# Logging: human-readable to stderr; durable audit to journald (always).
# ----------------------------------------------------------------------------
log()   { echo "[${TAG}] $1" >&2; }
audit() { logger -t "${TAG}" -p daemon.info -- "$1" 2>/dev/null || true; }
die()   { log "ERROR: $2"; audit "ERROR: $2"; exit "$1"; }

usage() {
    cat <<USAGE
${SCRIPT_NAME} v${SCRIPT_VERSION}

Route + send a notification for an event to its audience (ops/owner/account).

Usage: ${SCRIPT_NAME} --event <id> [options]

  --event <id>        REQUIRED. One of the known event ids (below).
  --account <name>    Account the event concerns (required for account-scoped
                      events: provisioned/suspend/resume/offboard/limit-*/report).
  --subject <text>    Email subject (a default is derived if omitted).
  --body <text>       Email body (plain text).
  --body-file <path>  Read body from a (root-owned) file — for pre-rendered
                      content (welcome/offboard manifest/HTML report wrapper).
  --reason <text>     Optional reason (suspend/offboard); folded into body+audit.
  --audience <list>   Override the default audience (comma: account,owner,ops).
  --dry-run           Resolve + audit only; send nothing.
  -h | --help         This message.

Known events (default audience; account-scoped ones walk the chain):
  provisioned       account,owner        suspend           account,owner *floor
  resume            account,owner *floor offboard          account,owner
  limit-disk        account,owner        limit-bw          account,owner
  report            account (opt-in)     notify-self-heal  account,owner,ops
  server-welcome    ops                  ops-alert         ops
  backup-configured ops

  *floor = critical: not suppressible by an owner mute (still needs an address
  to reach the account; if the account has none, the owner is still notified).

Examples:
  /usr/local/bin/vps-tooling/${SCRIPT_NAME} --event provisioned --account alice --dry-run
  /usr/local/bin/vps-tooling/${SCRIPT_NAME} --event ops-alert --subject "disk 90%" --body "/ at 90% on web1"
USAGE
}

# ----------------------------------------------------------------------------
# Untrusted-input parse: read ONE key=value from a file WITHOUT sourcing it.
# Guards: must be a regular non-symlink file under the size cap. Value charset
# is bounded by the callers' validation (email regex / on|off check).
# ----------------------------------------------------------------------------
safe_pref() {
    local file="$1" key="$2" size val
    [[ -n "${file}" ]] || return 0
    if [[ -L "${file}" ]]; then
        audit "WARN refusing symlinked pref file: ${file}"; return 0
    fi
    [[ -f "${file}" ]] || return 0
    size="$(stat -c %s "${file}" 2>/dev/null || echo 0)"
    if (( size > PREF_MAX_BYTES )); then
        audit "WARN pref file exceeds ${PREF_MAX_BYTES}B, ignoring: ${file}"; return 0
    fi
    # last assignment wins; strip surrounding whitespace and optional quotes.
    val="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "${file}" 2>/dev/null \
            | tail -n1 \
            | sed -e "s/^[[:space:]]*${key}[[:space:]]*=[[:space:]]*//" -e 's/[[:space:]]*$//')"
    val="${val%\"}"; val="${val#\"}"
    val="${val%\'}"; val="${val#\'}"
    printf '%s' "${val}"
}

# Read a top-level string value from the JSON state record (no jq dependency).
json_str() {
    local file="$1" key="$2"
    [[ -f "${file}" ]] || return 0
    sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "${file}" \
        | head -n1
}

valid_email() { [[ "$1" =~ ${EMAIL_RE} ]]; }

# ----------------------------------------------------------------------------
# Event -> default audience + class.
# ----------------------------------------------------------------------------
default_audience() {
    case "$1" in
        provisioned|suspend|resume|offboard|limit-disk|limit-bw) echo "account,owner" ;;
        notify-self-heal)                                        echo "account,owner,ops" ;;
        report)                                                  echo "account" ;;
        server-welcome|ops-alert|backup-configured)              echo "ops" ;;
        *)                                                       echo "" ;;
    esac
}

event_class() {
    case "$1" in
        provisioned|suspend|resume|offboard) echo "lifecycle" ;;
        limit-disk|limit-bw)                 echo "limits" ;;
        report)                              echo "report" ;;
        notify-self-heal)                    echo "action" ;;
        server-welcome|ops-alert|backup-configured) echo "ops" ;;
        *)                                   echo "other" ;;
    esac
}

is_floor() { case "$1" in suspend|resume) return 0 ;; *) return 1 ;; esac; }

# ----------------------------------------------------------------------------
# Recipient resolution.
# ----------------------------------------------------------------------------
account_home() {
    local acct="$1" home
    home="$(json_str "${TENANT_DIR}/${acct}_info.json" home)"
    if [[ -z "${home}" ]]; then
        home="$(getent passwd "${acct}" 2>/dev/null | cut -d: -f6)"
    fi
    printf '%s' "${home}"
}

account_prefs_path() {
    local home; home="$(account_home "$1")"
    [[ -n "${home}" ]] && printf '%s' "${home}/.config/vps-notify/prefs"
}

resolve_account_addr() {
    safe_pref "$(account_prefs_path "$1")" "notify_email"
}

resolve_owner_id() {
    local owner
    owner="$(json_str "${TENANT_DIR}/${1}_info.json" notify_owner)"
    [[ -n "${owner}" ]] || owner="house"   # default: Velocity-direct (-> ops)
    printf '%s' "${owner}"
}

owner_conf_path() {
    local owner="$1"
    if [[ "${owner}" == "house" ]]; then printf '%s' "${HOUSE_CONF}"
    else printf '%s' "${RESELLER_DIR}/${owner}.conf"; fi
}

resolve_owner_addr() {
    local owner; owner="$(resolve_owner_id "$1")"
    if [[ "${owner}" == "house" ]]; then
        printf '%s' "${NOTIFY_OPS_EMAIL:-}"
    else
        safe_pref "${RESELLER_DIR}/${owner}.conf" "notify_email"
    fi
}

# Owner has muted this class for their owned accounts? (mute=class1,class2,...)
owner_mutes_class() {
    local acct="$1" class="$2" owner mute
    owner="$(resolve_owner_id "${acct}")"
    mute="$(safe_pref "$(owner_conf_path "${owner}")" "mute")"
    [[ ",${mute}," == *",${class},"* ]]
}

# ----------------------------------------------------------------------------
# Argument parsing
# ----------------------------------------------------------------------------
EVENT=""; ACCOUNT=""; SUBJECT=""; BODY=""; BODY_FILE=""; REASON=""
AUD_OVERRIDE=""; DRY_RUN="false"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --event)     EVENT="${2:-}"; shift 2 ;;
        --account)   ACCOUNT="${2:-}"; shift 2 ;;
        --subject)   SUBJECT="${2:-}"; shift 2 ;;
        --body)      BODY="${2:-}"; shift 2 ;;
        --body-file) BODY_FILE="${2:-}"; shift 2 ;;
        --reason)    REASON="${2:-}"; shift 2 ;;
        --audience)  AUD_OVERRIDE="${2:-}"; shift 2 ;;
        --dry-run)   DRY_RUN="true"; shift ;;
        -h|--help)   usage; exit 0 ;;
        *)           usage >&2; die 2 "unknown argument: $1" ;;
    esac
done

[[ -n "${EVENT}" ]] || { usage >&2; die 2 "--event is required"; }

AUDIENCE="$(default_audience "${EVENT}")"
[[ -n "${AUDIENCE}" ]] || die 2 "unknown event: ${EVENT}"
[[ -n "${AUD_OVERRIDE}" ]] && AUDIENCE="${AUD_OVERRIDE}"
CLASS="$(event_class "${EVENT}")"

# Account-scoped events need --account.
if [[ ",${AUDIENCE}," == *",account,"* || ",${AUDIENCE}," == *",owner,"* ]]; then
    [[ -n "${ACCOUNT}" ]] || die 2 "event '${EVENT}' is account-scoped; --account required"
fi

# ----------------------------------------------------------------------------
# Mail identity (from postfix_foundation). Absent -> audit-only, no send.
# ----------------------------------------------------------------------------
# Capture a caller's env override (lets an operator/test pick the style per run)
# before we reset + source mail.env. Precedence: env > mail.env > built-in default.
_env_brand_style="${MAIL_BRAND_STYLE:-}"
NOTIFY_OPS_EMAIL=""; MAIL_FROM=""; MAIL_BRAND_STYLE=""
if [[ -r "${MAIL_ENV}" ]]; then
    # mail.env is ROOT-OWNED and rendered by us -> safe to source.
    # shellcheck source=/dev/null
    . "${MAIL_ENV}"
fi
[[ -n "${_env_brand_style}" ]] && MAIL_BRAND_STYLE="${_env_brand_style}"
[[ -n "${MAIL_FROM}" ]] || MAIL_FROM="ops@$(hostname -f 2>/dev/null || hostname)"
# Brand styling for the HTML email part — two on-hand styles to A/B over time:
#   light  (default) white bg, dark text; reads everywhere + inverts cleanly.
#   dark            brand-grey #333333 bg, light text; richer look, but
#                   invert-only clients (Gmail / SmarterMail dark) may flip it.
# Operator-selectable via MAIL_BRAND_STYLE in mail.env; bolt stays bold orange.
case "${MAIL_BRAND_STYLE:-light}" in
    dark) BRAND_PAGE_BG="#333333"; BRAND_PRE_BG="#333333"; BRAND_PRE_FG="#e6e6e6" ;;
    *)    BRAND_PAGE_BG="#ffffff"; BRAND_PRE_BG="#ffffff"; BRAND_PRE_FG="#1a1a1a" ;;
esac
# Brand orange for body dash-rules (matches brand_header's MOTD rule / bolt). A
# caller's all-dashes line (a separator) renders in this colour in the HTML part.
BRAND_RULE_HEX="#f1952e"

# ----------------------------------------------------------------------------
# Build the recipient set by walking the audience nodes.
# ----------------------------------------------------------------------------
declare -a raw=()
IFS=',' read -ra NODES <<< "${AUDIENCE}"
for node in "${NODES[@]}"; do
    case "${node}" in
        ops)
            [[ -n "${NOTIFY_OPS_EMAIL}" ]] && raw+=("${NOTIFY_OPS_EMAIL}")
            ;;
        account)
            # report is opt-in: requires report=on in the tenant prefs.
            if [[ "${EVENT}" == "report" ]]; then
                [[ "$(safe_pref "$(account_prefs_path "${ACCOUNT}")" report)" == "on" ]] || continue
            fi
            addr="$(resolve_account_addr "${ACCOUNT}")"
            [[ -n "${addr}" ]] && raw+=("${addr}")
            ;;
        owner)
            # Non-floor events respect an owner mute; floor events ignore it.
            if ! is_floor "${EVENT}" && owner_mutes_class "${ACCOUNT}" "${CLASS}"; then
                continue
            fi
            addr="$(resolve_owner_addr "${ACCOUNT}")"
            [[ -n "${addr}" ]] && raw+=("${addr}")
            ;;
        *)
            log "WARN ignoring unknown audience node: ${node}"
            ;;
    esac
done

# Flatten comma-lists, validate each address, drop invalid, de-duplicate.
declare -a clean=()
for entry in "${raw[@]:-}"; do
    [[ -n "${entry}" ]] || continue
    IFS=',' read -ra parts <<< "${entry}"
    for p in "${parts[@]}"; do
        p="${p// /}"
        [[ -n "${p}" ]] || continue
        if valid_email "${p}"; then clean+=("${p}")
        else audit "WARN dropping invalid address for event=${EVENT}: ${p}"; fi
    done
done

declare -a final=()
if [[ ${#clean[@]} -gt 0 ]]; then
    mapfile -t final < <(printf '%s\n' "${clean[@]}" | sort -u)
fi

# ----------------------------------------------------------------------------
# Audit ALWAYS (even with zero recipients / dry-run) — durable record.
# ----------------------------------------------------------------------------
audit "event=${EVENT} class=${CLASS} account=${ACCOUNT:-none} audience=${AUDIENCE} recipients=${final[*]:-none}${REASON:+ reason=${REASON}} dry_run=${DRY_RUN}"

# ----------------------------------------------------------------------------
# Compose + send.
# ----------------------------------------------------------------------------
[[ -n "${SUBJECT}" ]] || SUBJECT="[${TAG}] ${EVENT}${ACCOUNT:+ — ${ACCOUNT}}"

if [[ -z "${BODY}" ]]; then
    if [[ -n "${BODY_FILE}" && -f "${BODY_FILE}" ]]; then
        BODY="$(cat "${BODY_FILE}")"
    else
        BODY="Event: ${EVENT}${ACCOUNT:+
Account: ${ACCOUNT}}${REASON:+
Reason: ${REASON}}"
    fi
fi

# Velocity Host brand header. Single source: brand_header_v1.sh. Best-effort —
# a missing engine just means no header, never a failed send. We render TWO forms
# from the one engine: PLAIN (text/plain part; fine in terminals + monospace mail)
# and HTML-escaped art (text/html part, wrapped in a <pre> below) so that
# proportional-font mail clients render the bolt monospace instead of shearing it.
BRAND_HEADER="${BRAND_HEADER:-/usr/local/bin/vps-tooling/brand_header_v1.sh}"
brand_plain=""; brand_html=""
if [[ -x "${BRAND_HEADER}" ]]; then
    brand_plain="$("${BRAND_HEADER}" plain 2>/dev/null || true)"
    brand_html="$("${BRAND_HEADER}" html  2>/dev/null || true)"
fi

# text/plain body: brand (plain) + the message, unchanged from prior behaviour.
PLAIN_BODY="${BODY}"
[[ -n "${brand_plain}" ]] && PLAIN_BODY="${brand_plain}

${BODY}"

# text/html body: HTML-escape the message; the brand art is already escaped +
# brand-coloured (bold orange bolt) by the engine's html mode. Brand + message go
# in ONE light <pre> below — a white email reads everywhere and inverts cleanly in
# dark mode (no explicit dark background for invert-only clients to mangle). sed,
# not bash ${//}: bash 5.2's patsub_replacement treats a bare & in the replacement
# as the matched text, which would corrupt the entities.
# Build the HTML body line-by-line: escape each line, and render an all-dashes
# separator line in brand orange (like the MOTD rule) so a caller's section rules
# read as cleanly as the header. Non-rule lines inherit the <pre> colour.
body_html="$(printf '%s' "${BODY}" | while IFS= read -r _ln || [ -n "${_ln}" ]; do
    _esc="$(printf '%s' "${_ln}" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g')"
    if printf '%s' "${_ln}" | grep -qE '^[[:space:]]*-{3,}[[:space:]]*$'; then
        printf '<span style="color:%s">%s</span>\n' "${BRAND_RULE_HEX}" "${_esc}"
    else
        printf '%s\n' "${_esc}"
    fi
done)"

if [[ "${DRY_RUN}" == "true" ]]; then
    log "[dry-run] event=${EVENT} would send to: ${final[*]:-none}"
    exit 0
fi
if [[ ${#final[@]} -eq 0 ]]; then
    log "no recipients resolved for event=${EVENT} (audited; nothing to send)"
    exit 0
fi
if [[ ! -x "${SENDMAIL}" ]]; then
    log "no MTA at ${SENDMAIL}; event=${EVENT} audited only, not sent"
    exit 0
fi

TO="$(IFS=','; echo "${final[*]}")"

# multipart/alternative: text/plain (terminals + monospace clients) AND text/html
# (brand + body in a <pre> so proportional-font clients render the bolt right).
# Boundary is unique per send ($$ + epoch) and cannot collide with the ASCII art.
BOUNDARY="=_vh_${$}_$(date +%s 2>/dev/null || echo 0)"
{
    printf 'From: %s\n' "${MAIL_FROM}"
    printf 'To: %s\n' "${TO}"
    printf 'Subject: %s\n' "${SUBJECT}"
    printf 'MIME-Version: 1.0\n'
    printf 'Content-Type: multipart/alternative; boundary="%s"\n\n' "${BOUNDARY}"
    printf 'This is a multi-part message in MIME format.\n\n'
    printf '%s\n' "--${BOUNDARY}"
    printf 'Content-Type: text/plain; charset=utf-8\nContent-Transfer-Encoding: 8bit\n\n'
    printf '%s\n\n' "${PLAIN_BODY}"
    printf '%s\n' "--${BOUNDARY}"
    printf 'Content-Type: text/html; charset=utf-8\nContent-Transfer-Encoding: 8bit\n\n'
    printf '<!DOCTYPE html>\n<html>\n<head><meta charset="utf-8"><meta name="color-scheme" content="light dark"></head>\n'
    printf '<body style="margin:0; padding:0; background:%s;">\n' "${BRAND_PAGE_BG}"
    printf '<div style="max-width:600px; margin:0 auto;">\n'
    # 600px email column (the max-width div above). TWO stacked <pre> blocks, styled
    # per MAIL_BRAND_STYLE (light|dark): the brand bolt carries its bold orange from
    # the engine's spans; wordmark/contacts/message inherit the base colour so they
    # read on either background.
    #  • brand art — white-space:pre (must NOT wrap, keeps the bolt aligned), 11px.
    #    The 80-col art is ~528px at 11px; with 12px side padding the content box is
    #    ~576px, so it sits well inside with margin (was 12px/16px = ~576px art in a
    #    568px box → ~8px overrun + scrollbar). overflow-x:hidden so no client shows a
    #    horizontal scrollbar; the comfortable margin means nothing is clipped.
    #  • message body — its OWN block, white-space:pre-wrap so long alert lines WRAP
    #    instead of forcing a horizontal scroll (the converge-stale line is > 82 cols);
    #    overflow-wrap/word-break also break long unbroken tokens (paths, URLs).
    # Splitting them is the fix — one shared <pre> made any long body line overflow.
    if [[ -n "${brand_html}" ]]; then
        printf '<pre style="margin:0; padding:14px 12px 0; background:%s; color:%s; font-family:Menlo,Consolas,&quot;DejaVu Sans Mono&quot;,monospace; font-size:11px; line-height:1.25; white-space:pre; overflow-x:hidden;">' "${BRAND_PRE_BG}" "${BRAND_PRE_FG}"
        printf '%s' "${brand_html}"
        printf '</pre>\n'
    fi
    printf '<pre style="margin:0; padding:8px 12px 14px; background:%s; color:%s; font-family:Menlo,Consolas,&quot;DejaVu Sans Mono&quot;,monospace; font-size:11px; line-height:1.4; white-space:pre-wrap; overflow-wrap:anywhere; word-break:break-word;">' "${BRAND_PRE_BG}" "${BRAND_PRE_FG}"
    printf '%s' "${body_html}"
    printf '</pre>\n</div>\n</body></html>\n\n'
    printf '%s\n' "--${BOUNDARY}--"
} | "${SENDMAIL}" -t 2>/dev/null \
    || die 1 "sendmail failed for event=${EVENT} (recipients=${TO})"

log "sent event=${EVENT} to ${TO}"
audit "SENT event=${EVENT} account=${ACCOUNT:-none} to=${TO}"
exit 0
