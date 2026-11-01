#!/bin/bash
#
# KISS Backup standalone installer
# Version: 0.1.0
# Script Name: install.sh
# Project: KISS-Backup-Client
# Summary: Installs the Layer-1 engine, setup wizard, notifier, brand header and
#   console onto a standalone box (no ansible), renders the systemd units from the
#   backups_foundation role's templates + defaults, and drops the console menus.
#
# Purpose:
#   The non-ansible install path (docs/EXTRACTION.md item 6). It only INSTALLS:
#   the timers are enabled by the setup wizard once the repo is initialised and
#   verified, so nothing fires against an unconfigured box. Re-runnable — code and
#   units are overwritten, operator config in $KBC_CONFIG_DIR is never clobbered.
#   Unit values come from packaging/ansible/backups_foundation/defaults/main.yml so
#   the standalone and role-managed schedules can't drift; check-failure alerting is
#   always OFF here (service_watchdog is a vps-baseline foundation, item 4).
#
# Usage (run as root from a checkout of the repo):
#   packaging/install.sh              # install / upgrade
#   packaging/install.sh --uninstall  # remove code + units (keeps $KBC_CONFIG_DIR + the repo passphrase)
# Then:  kiss-backup-setup

set -u
set -o pipefail

SRC="$(cd "$(dirname "$0")/.." && pwd)"
ROLE="$SRC/packaging/ansible/backups_foundation"
LIB="${LIB:-/usr/local/lib/kiss-backup}"
SBIN="${SBIN:-/usr/local/sbin}"
UNIT_DIR="${UNIT_DIR:-/etc/systemd/system}"
KBC_CONFIG_DIR="${KBC_CONFIG_DIR:-/etc/kiss-backup}"
RESTIC_DIR="${RESTIC_DIR:-/etc/restic}"

# Unit templates and which subset is core (always) vs optional (wizard decides).
UNITS="kiss-backup kiss-backup-check kiss-backup-prune kiss-backup-drill
       kiss-backup-db-full kiss-backup-db-diff kiss-backup-db-dump"
# Console menus shipped standalone.
MENUS="30-backups.menu 35-backup-stats.menu 40-account-restore.menu 45-browse-backup.menu"

say() { printf '%s\n' "$*"; }
die() { printf 'install: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "run as root"
[ -f "$SRC/engine/restic_backup.sh" ] || die "run from a KISS-Backup-Client checkout (no engine at $SRC/engine)"

do_uninstall() {
    say "Stopping + removing kiss-backup units ..."
    for u in $UNITS; do
        systemctl disable --now "${u}.timer" >/dev/null 2>&1 || true
        rm -f "${UNIT_DIR}/${u}.timer" "${UNIT_DIR}/${u}.service"
    done
    systemctl daemon-reload
    rm -f "$SBIN/kiss-backup" "$SBIN/kiss-backup-setup" "$SBIN/kiss-console"
    rm -rf "$LIB"
    for m in $MENUS; do rm -f "$KBC_CONFIG_DIR/console.d/$m"; done
    say "Removed. Kept: ${KBC_CONFIG_DIR} (config) and ${RESTIC_DIR} (repo key + passphrase)."
    say "The offsite repo itself is untouched."
}

# Install the tools the engine/console call out to, via whichever package family
# this box has (the runtime OS auto-detect, handover §8).
install_deps() {
    local need="" pkgs="" t
    for t in curl bzip2 whiptail flock mc; do command -v "$t" >/dev/null 2>&1 || need="$need $t"; done
    [ -n "$need" ] || return 0
    if command -v dnf >/dev/null 2>&1; then
        for t in $need; do case "$t" in whiptail) pkgs="$pkgs newt" ;; flock) pkgs="$pkgs util-linux" ;; *) pkgs="$pkgs $t" ;; esac; done
        say "Installing missing tools:${pkgs} (dnf) ..."
        # shellcheck disable=SC2086
        dnf -y -q install $pkgs || die "dnf install failed:${pkgs}"
    elif command -v apt-get >/dev/null 2>&1; then
        for t in $need; do case "$t" in flock) pkgs="$pkgs util-linux" ;; *) pkgs="$pkgs $t" ;; esac; done
        say "Installing missing tools:${pkgs} (apt) ..."
        # shellcheck disable=SC2086
        DEBIAN_FRONTEND=noninteractive apt-get -y -q install $pkgs || die "apt-get install failed:${pkgs}"
    else
        die "no dnf or apt-get — install these yourself:${need}"
    fi
}

# Read a scalar from the role defaults ("key: value  # comment", value optionally quoted).
default_of() {
    local line v
    line="$(grep -m1 -E "^$1:" "$ROLE/defaults/main.yml")" || return 1
    v="${line#*:}"; v="${v#"${v%%[![:space:]]*}"}"
    case "$v" in
        \"*) v="${v#\"}"; v="${v%%\"*}" ;;
        *)   v="${v%%[[:space:]]#*}"; v="${v%"${v##*[![:space:]]}"}" ;;
    esac
    printf '%s' "$v"
}

# Render one role unit template. Supports exactly the Jinja the unit templates use:
# {{ ansible_managed }}, plain {{ backups_* }} scalars, and the alert {% if %} block
# (dropped — alerting is off standalone). Anything else left over is a hard error.
render_unit() {
    local in="$1" out="$2" body var val
    body="$(sed '/^{% if backups_alert_on_check_failure | bool %}$/,/^{% endif %}$/d' "$in")"
    body="${body//\{\{ ansible_managed \}\}/Installed by KISS-Backup-Client packaging/install.sh — local edits are overwritten on reinstall}"
    for var in $(printf '%s\n' "$body" | grep -oE '\{\{ backups_[a-z_]+ \}\}' | sort -u | tr -d '{} '); do
        case "$var" in
            backups_engine_path) val="$LIB/restic_backup.sh" ;;
            backups_env_path)    val="$KBC_CONFIG_DIR/backup.env" ;;
            *) val="$(default_of "$var")" || die "no default for $var (used in $(basename "$in"))" ;;
        esac
        body="${body//\{\{ $var \}\}/$val}"
    done
    case "$body" in *'{{'*|*'{%'*) die "unrendered Jinja left in $(basename "$in")" ;; esac
    printf '%s\n' "$body" > "$out" && chmod 0644 "$out" || die "could not write $out"
}

# On an already-configured box, bring restic to the engine's pin — the timers never
# reinstall it, so without this a pin bump would never reach existing boxes. Older
# wizards wrote RESTIC_VERSION into backup.env; drop that line from a WIZARD-written
# file so the engine's pin applies (an operator- or role-set value is left alone).
upgrade_restic() {
    local env="$KBC_CONFIG_DIR/backup.env" tmp
    [ -r "$env" ] || return 0
    if head -1 "$env" | grep -q '^# backup-setup ' && grep -q '^RESTIC_VERSION=' "$env"; then
        tmp="$(mktemp)" && grep -v '^RESTIC_VERSION=' "$env" > "$tmp" \
            && install -m 0640 "$tmp" "$env" && rm -f "$tmp" \
            || die "could not update $env"
        say "Removed the wizard-written RESTIC_VERSION from $env (the engine's pin now applies)."
    fi
    # Per-account restore needs ADAPTER (and, on DA, the DNS zones in the backup).
    # Add them to a WIZARD-written config on a box the adapter recognises.
    if head -1 "$env" | grep -q '^# backup-setup ' && ! grep -q '^ADAPTER=' "$env"; then
        if "$LIB/adapters/directadmin/adapter" detect >/dev/null 2>&1; then
            printf 'ADAPTER="directadmin"\n' >> "$env"
            say "Added ADAPTER=directadmin to $env (per-account restore)."
            if ! grep -q '^BACKUP_PATHS=.*/var/named' "$env"; then
                sed -i 's|^\(BACKUP_PATHS="[^"]*\)"|\1 /var/named"|' "$env"
                say "Added /var/named (DNS zones) to BACKUP_PATHS in $env."
            fi
        elif "$LIB/adapters/velocity/adapter" detect >/dev/null 2>&1; then
            printf 'ADAPTER="velocity"\n' >> "$env"
            say "Added ADAPTER=velocity to $env (per-account restore from the tenant ledger)."
        fi
    fi
    say "Checking restic against the pinned version ..."
    BACKUP_ENV="$env" KBC_CONFIG_DIR="$KBC_CONFIG_DIR" "$LIB/restic_backup.sh" install \
        || die "restic upgrade failed — backups keep running on the current binary; see the output above"
}

do_install() {
    install_deps

    say "Installing code to ${LIB} ..."
    install -d -m 0755 "$LIB" "$SBIN"
    install -m 0750 "$SRC/engine/restic_backup.sh" "$LIB/restic_backup.sh"
    install -m 0750 "$SRC/engine/backup_setup.sh"  "$LIB/backup_setup.sh"
    install -m 0750 "$SRC/engine/notify.sh"        "$LIB/notify.sh"
    install -m 0755 "$SRC/brand/brand_header.sh"   "$LIB/brand_header.sh"
    install -m 0750 "$SRC/console/console.sh"      "$LIB/console.sh"
    install -m 0750 "$SRC/console/restore_account.sh" "$LIB/restore_account.sh"
    # Layer-2/3 adapters (docs/architecture.md §1.6): adapters/<name>/adapter.
    local a
    # Shared adapter helpers (restore_common.sh) — sourced by every adapter.
    install -d -m 0755 "$LIB/adapters/lib"
    for a in "$SRC"/adapters/lib/*.sh; do [ -f "$a" ] && install -m 0640 "$a" "$LIB/adapters/lib/"; done
    for a in "$SRC"/adapters/*/adapter; do
        [ -f "$a" ] || continue
        install -d -m 0755 "$LIB/adapters/$(basename "$(dirname "$a")")"
        install -m 0750 "$a" "$LIB/adapters/$(basename "$(dirname "$a")")/adapter"
    done
    ln -sfn "$LIB/restic_backup.sh" "$SBIN/kiss-backup"
    ln -sfn "$LIB/backup_setup.sh"  "$SBIN/kiss-backup-setup"
    ln -sfn "$LIB/console.sh"       "$SBIN/kiss-console"

    say "Installing config scaffolding to ${KBC_CONFIG_DIR} (existing files kept) ..."
    install -d -m 0755 "$KBC_CONFIG_DIR" "$KBC_CONFIG_DIR/console.d"
    install -d -m 0700 "$RESTIC_DIR"
    for m in $MENUS; do install -m 0644 "$SRC/console/console.d/$m" "$KBC_CONFIG_DIR/console.d/$m"; done
    [ -e "$KBC_CONFIG_DIR/backup-excludes.conf" ] \
        || install -m 0644 "$ROLE/templates/backup-excludes.conf.j2" "$KBC_CONFIG_DIR/backup-excludes.conf"
    install -m 0644 "$SRC/brand/kiss-target.conf.example" "$KBC_CONFIG_DIR/kiss-target.conf.example"

    say "Rendering systemd units to ${UNIT_DIR} ..."
    local u kind
    install -d -m 0755 "$UNIT_DIR"
    for u in $UNITS; do
        for kind in service timer; do
            render_unit "$ROLE/templates/${u}.${kind}.j2" "${UNIT_DIR}/${u}.${kind}"
        done
    done
    systemctl daemon-reload

    say ""
    if systemctl is-enabled --quiet kiss-backup.timer 2>/dev/null; then
        upgrade_restic
        say "Upgraded. Backups were already configured — the timers stay enabled and pick up"
        say "the new code on their next run. Check with:  kiss-backup-setup status"
    else
        say "Installed. Timers are NOT enabled yet — the setup wizard enables them after it"
        say "connects to your repo and verifies a test backup + restore. Next:"
        say "    kiss-backup-setup"
    fi
}

case "${1:-}" in
    "")          do_install ;;
    --uninstall) do_uninstall ;;
    *)           die "usage: $0 [--uninstall]" ;;
esac
