#!/bin/bash
#
# Backup Setup Wizard
# Version: 1.1.0
# Script Name: backup_setup_v1.sh
# Project: vps-baseline / headless CloudLinux 8.10 VPS platform
# Summary: Interactive operator wizard that finishes backup onboarding after the
#   welcome email: it preflights the per-VPS SFTP key (generated earlier by
#   ssh_access_foundation), wires the KISS SSH alias + known_hosts, tests the
#   connection, lets the operator opt in/out, persists the choice to host.yml,
#   renders the backup config, initialises the repo, SHOWS the repo passphrase with
#   the break-glass escrow warning, then proves it with a first backup + restore
#   drill. The scheduled timers activate on the next converge (via host.yml).
#
# Purpose:
#   The interactive front end to backups_foundation (engine/front-end split). It
#   does NOT replace the role — it persists backups_enabled/backups_repo to
#   /etc/vps-tooling/host.yml (so the converge keeps backups running + installs the
#   timers) and runs the engine once now for immediate confirmation. Re-runnable.
#   The SFTP ACCESS key is a foundation prerequisite (ssh_access_foundation); the
#   repo PASSPHRASE (decryption) is generated here at init. Escrow policy is still
#   owner-managed (handover §9 pending) — the wizard shows the passphrase + warns.
#
# Usage:
#   backup_setup_v1.sh                    # run the interactive wizard (default)
#   backup_setup_v1.sh status             # what's backed up, how often, retained how long
#   backup_setup_v1.sh refresh-stats      # recompute the cached repo dedup/size figures
#                                         #   (add --force to rescan even if the cache is fresh)
#   backup_setup_v1.sh --help             # this help
# Examples (run as root; /usr/local/bin is not on root's login PATH):
#   /usr/local/bin/vps-tooling/backup_setup_v1.sh
#
# Run as: root. Exit: 0 ok / 1 error / 2 usage.
#
set -u

KEY="${BACKUP_SSH_KEY:-/etc/restic/kiss_id_rsa}"
SSH_CONFIG="${SSH_CONFIG:-/root/.ssh/config}"
KNOWN_HOSTS="${KNOWN_HOSTS:-/root/.ssh/known_hosts}"
HOST_YML="${HOST_YML:-/etc/vps-tooling/host.yml}"
BASELINE="${BASELINE:-/var/lib/ansible/baseline}"
ENGINE="${ENGINE:-/usr/local/bin/vps-tooling/restic_backup_v1.sh}"
ENGINE_SRC="${ENGINE_SRC:-$BASELINE/vps-tooling/restic_backup_v1.sh}"
KBC_CONFIG_DIR="${KBC_CONFIG_DIR:-/etc/kiss-backup}"
BACKUP_ENV="${BACKUP_ENV:-$KBC_CONFIG_DIR/backup.env}"
PASSFILE="${PASSFILE:-/etc/restic/backup.pass}"
RESTIC_BIN="${RESTIC_BIN:-/usr/local/bin/restic}"
RESTIC_VERSION="${RESTIC_VERSION:-0.19.0}"
# restic 0.19 FATALs without a writable cache when there's no $HOME — exactly the case when
# refresh-stats runs from the console's `systemd-run` background unit. Pin a HOME-independent
# cache dir for every restic call here (matching the engines). Without it the background stats
# scan dies, the cache never writes, and the console header stays blank.
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"
NOTIFY_ENGINE="${NOTIFY_ENGINE:-/usr/local/bin/vps-tooling/vps_notify_v1.sh}"
# Default file coverage — MUST match backups_foundation's backups_paths default so
# the interim env + the on-converge re-render agree. The engine skips absent paths.
PATHS="${BACKUP_PATHS:-/home /etc /root /var/spool/cron /usr/local/lsws/conf}"
# Cached repo stats — the two `restic stats` passes scan the whole repo (slow on a large or
# remote repo), so we DON'T run them interactively. `refresh-stats` writes this cache; `status`
# and the console header READ it instantly + show "as of <when>"; a stale cache is refreshed
# in the background on view (throttled + flock-guarded). See docs/operator_console_design.md.
STATS_CACHE="${BACKUP_STATS_CACHE:-/var/lib/kiss-backups/repo-stats}"
STATS_MAX_AGE="${BACKUP_STATS_MAX_AGE:-72000}"        # 20h — refresh roughly once a day
STATS_LOCK="${BACKUP_STATS_LOCK:-/run/lock/kiss-repo-stats.lock}"

say()  { printf '%s\n' "$*"; }
hr()   { printf -- '--------------------------------------------------------------------------------\n'; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
ask()  { local p="$1" d="$2" a; read -r -p "$p [$d]: " a; printf '%s' "${a:-$d}"; }
yes()  { local p="$1" d="$2" a; read -r -p "$p ($d): " a; a="${a:-$d}"; case "$a" in [Yy]*) return 0 ;; *) return 1 ;; esac; }

usage() { sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# KISS reachability probe. KISS is SFTP-ONLY (ForceCommand internal-sftp), so an
# ssh exec ('ssh host true') is REJECTED even when SFTP works — test over SFTP.
kiss_reachable() {
    printf 'quit\n' | sftp -b - -o BatchMode=yes -o ConnectTimeout=10 "$ALIAS" >/dev/null 2>&1
}

repo_path() { grep -m1 '^BACKUP_REPO=' "$BACKUP_ENV" 2>/dev/null | cut -d'"' -f2; }
# Read one KEY="value" field from the (root-owned) stats cache WITHOUT sourcing it.
stats_get() { grep -m1 "^${1}=" "$STATS_CACHE" 2>/dev/null | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//'; }

# compute_stats — the SLOW part: two restic stats passes + a snapshot count, written to the
# cache as a sourceable file. Returns non-zero (cache untouched) if the repo isn't reachable
# or there's no real backup yet. Callers own throttle/lock.
compute_stats() {
    local repo logical stored snaps hl hs saved tmp
    repo="$(repo_path)"; [ -n "$repo" ] || return 1
    [ -x "$RESTIC_BIN" ] && [ -s "$PASSFILE" ] || return 1
    logical="$("$RESTIC_BIN" -r "$repo" --password-file "$PASSFILE" stats --mode restore-size --json 2>/dev/null | grep -o '"total_size":[0-9]*' | head -1 | cut -d: -f2)"
    stored="$("$RESTIC_BIN" -r "$repo" --password-file "$PASSFILE" stats --mode raw-data --json 2>/dev/null | grep -o '"total_size":[0-9]*' | head -1 | cut -d: -f2)"
    snaps="$("$RESTIC_BIN" -r "$repo" --password-file "$PASSFILE" snapshots --json 2>/dev/null | grep -o '"short_id"' | wc -l)"
    [ -n "${logical:-}" ] && [ -n "${stored:-}" ] && [ "${logical:-0}" -gt 0 ] 2>/dev/null || return 1
    hl="$(numfmt --to=iec-i --suffix=B "$logical" 2>/dev/null || echo "${logical}B")"
    hs="$(numfmt --to=iec-i --suffix=B "$stored" 2>/dev/null || echo "${stored}B")"
    saved=$(( (logical - stored) * 100 / logical ))
    install -d -m 0755 "$(dirname "$STATS_CACHE")"
    tmp="$(mktemp)"
    {
        printf 'REPO_STATS_AS_OF="%s"\n' "$(date '+%Y-%m-%d %H:%M')"
        printf 'REPO_STATS_EPOCH=%s\n'   "$(date +%s)"
        printf 'REPO_STATS_SUMMARY="%s → %s stored (%s%% saved), %s snaps"\n' "$hl" "$hs" "$saved" "${snaps:-?}"
    } > "$tmp"
    install -m 0644 "$tmp" "$STATS_CACHE"; rm -f "$tmp"
}

# True if the cache exists and is younger than STATS_MAX_AGE.
stats_fresh() {
    [ -s "$STATS_CACHE" ] || return 1
    local epoch now
    epoch="$(stats_get REPO_STATS_EPOCH)"; epoch="${epoch:-0}"
    now="$(date +%s)"
    [ "$(( now - epoch ))" -lt "$STATS_MAX_AGE" ]
}

# Fire a detached background refresh (throttle+flock inside make it safe to call freely).
spawn_stats_refresh() {
    if command -v setsid >/dev/null 2>&1; then
        setsid "$0" refresh-stats </dev/null >/dev/null 2>&1 &
    else
        ( "$0" refresh-stats >/dev/null 2>&1 & )
    fi
}

# refresh-stats [--force] — recompute the cache. Throttled (skips if fresh) unless --force;
# flock so an auto-fired refresh and a manual one don't both scan.
cmd_refresh_stats() {
    [ "$(id -u)" -eq 0 ] || die "run as root"
    local force=0; [ "${1:-}" = "--force" ] && force=1
    exec 9>"$STATS_LOCK" 2>/dev/null || true
    if command -v flock >/dev/null 2>&1; then flock -n 9 || { say "a repo-stats refresh is already running."; return 0; }; fi
    if [ "$force" -ne 1 ] && stats_fresh; then
        say "repo-stats cache is fresh (as of $(stats_get REPO_STATS_AS_OF)) — use --force to rescan."
        return 0
    fi
    say "Refreshing repository stats — restic scans every snapshot; this can take a minute or two…"
    if compute_stats; then
        say "Updated: $(stats_get REPO_STATS_SUMMARY) (as of $(stats_get REPO_STATS_AS_OF))."
    else
        say "Could not compute stats (repo unreachable, or no real backup yet)."
    fi
}

# status — the "what am I subscribed to?" view; reads the LIVE config so it reflects
# this box, not just defaults. Safe/read-only.
cmd_status() {
    [ "$(id -u)" -eq 0 ] || die "run as root"
    hr; say "Velocity Host — backup status"; hr
    if ! grep -q '^backups_enabled:[[:space:]]*true' "$HOST_YML" 2>/dev/null; then
        say "Backups: NOT configured on this box."
        say "Set them up with:  $0"
        return 0
    fi
    local repo paths
    repo="$(grep -m1 '^BACKUP_REPO=' "$BACKUP_ENV" 2>/dev/null | cut -d'"' -f2)"; repo="${repo:-?}"
    paths="$(grep -m1 '^BACKUP_PATHS=' "$BACKUP_ENV" 2>/dev/null | cut -d'"' -f2)"; paths="${paths:-/home /etc}"
    say "Backups:     ENABLED"
    say "Protection:  AES-256 encrypted · zstd-compressed · deduplicated · immutable offsite"
    say "Repository:  ${repo}"
    say "Files:       ${paths}"
    say "             (engine skips any path not present on this box)"
    if grep -q '^backups_db_enabled:[[:space:]]*true' "$HOST_YML" 2>/dev/null; then
        say "Databases:   nightly full + hourly differential (local) + daily per-DB dump (offsite)"
    else
        say "Databases:   not enabled"
    fi
    say "Cadence:     full file backup HOURLY (incremental); databases hourly (local) + daily dump (offsite)"
    say "Retention:   GFS — last 24 hourly (rolling 24h) + 14 daily + 8 weekly + 12 monthly (~1 year)"
    say "Passphrase:  ${PASSFILE}  (escrow it — break-glass to decrypt the offsite copy)"
    say ""
    say "Schedule (systemd timers):"
    systemctl list-timers 'kiss-backup*' --all --no-pager 2>/dev/null | sed 's/^/  /' \
        || say "  (timers install on the next converge)"
    say ""
    say "Most recent backups in the repo:"
    if [ -x "$ENGINE" ] && [ -s "$BACKUP_ENV" ]; then
        "$ENGINE" snapshots 2>/dev/null | tail -6 | sed 's/^/  /' || say "  (repo not reachable right now)"
    fi
    # Repo stats are read from the CACHE (the live restic scan is slow on a large/remote
    # repo, so it never runs interactively). A stale/absent cache is refreshed in the
    # background here, so the NEXT view is current — this call never blocks on the scan.
    say ""
    say "Repository stats (deduplication + compression):"
    if [ -s "$STATS_CACHE" ]; then
        say "  $(stats_get REPO_STATS_SUMMARY)"
        say "  (as of $(stats_get REPO_STATS_AS_OF) — refresh now: $0 refresh-stats --force)"
        stats_fresh || { say "  (figures are stale — refreshing in the background for next time…)"; spawn_stats_refresh; }
    else
        say "  (not computed yet — fetching in the background; or run: $0 refresh-stats)"
        spawn_stats_refresh
    fi
}

case "${1:-}" in
    -h|--help|help) usage 0 ;;
    status)         cmd_status; exit 0 ;;
    refresh-stats)  shift; cmd_refresh_stats "$@"; exit 0 ;;
    "" )            : ;;
    *)              printf 'unknown arg: %s\n' "$1" >&2; usage 2 ;;
esac

[ "$(id -u)" -eq 0 ] || die "run as root"

hr; say "Velocity Host — backup setup"; hr
say "Finishes offsite backup onboarding: connect to KISS, opt in, initialise the"
say "repo, show your break-glass passphrase, and verify with a test backup + restore."
say ""

# Preflight: the per-VPS SFTP key must exist (ssh_access_foundation makes it).
[ -s "${KEY}.pub" ] || die "no backup key at ${KEY}.pub — converge first (ssh_access_foundation generates it)."
ALIAS="kiss-headless"

# Connection — reuse a working alias if there is one; otherwise set it up. Testing
# FIRST means a box already wired to KISS (existing alias + known_hosts) just works,
# and the host-key trust / pubkey-authorize steps only appear when actually needed.
if kiss_reachable; then
    say "Connection to '${ALIAS}' already works — using the existing SFTP setup."
else
    # Don't clobber a hand-made alias: if a non-managed Host block exists and the
    # connection still failed, the operator must fix their own config.
    if grep -q "^Host ${ALIAS}\$" "$SSH_CONFIG" 2>/dev/null \
       && ! grep -q '# >>> backup-setup alias >>>' "$SSH_CONFIG" 2>/dev/null; then
        die "a hand-made '${ALIAS}' alias in ${SSH_CONFIG} isn't connecting — fix its HostName/Port/IdentityFile by hand and re-run (the wizard won't overwrite a manual alias)."
    fi
    say "Authorize this box's backup PUBLIC key on the KISS backup account:"
    say ""; cat "${KEY}.pub"; say ""
    KHOST="$(ask 'KISS hostname or IP' 'kiss.example.net')"
    KUSER="$(ask 'KISS backup account (username)' 'headless')"
    KPORT="$(ask 'KISS SSH port' '22')"
    install -d -m 0700 "$(dirname "$SSH_CONFIG")"
    touch "$SSH_CONFIG"; chmod 600 "$SSH_CONFIG"
    # Managed alias block — REPLACED every run, so a changed host/IP/port actually
    # applies (re-runnable for reconfigure, not just first-time setup).
    tmp="$(mktemp)"
    sed '/# >>> backup-setup alias >>>/,/# <<< backup-setup alias <<</d' "$SSH_CONFIG" > "$tmp"
    {
        cat "$tmp"
        printf '# >>> backup-setup alias >>>\n'
        printf 'Host %s\n' "$ALIAS"
        printf '    HostName %s\n' "$KHOST"
        printf '    User %s\n' "$KUSER"
        printf '    Port %s\n' "$KPORT"
        printf '    IdentityFile %s\n' "$KEY"
        printf '    IdentitiesOnly yes\n'
        printf '# <<< backup-setup alias <<<\n'
    } > "$SSH_CONFIG"
    rm -f "$tmp"; chmod 600 "$SSH_CONFIG"
    say "Wrote SSH alias '${ALIAS}' (HostName ${KHOST}, Port ${KPORT})."
    # Trust KISS's SERVER host key (distinct from our client key). Refresh it (the
    # host/port may have changed on a reconfigure), then re-scan.
    ssh-keygen -R "[${KHOST}]:${KPORT}" -f "$KNOWN_HOSTS" >/dev/null 2>&1 || true
    install -d -m 0700 "$(dirname "$KNOWN_HOSTS")"
    ssh-keyscan -p "$KPORT" -H "$KHOST" >> "$KNOWN_HOSTS" 2>/dev/null \
        || die "ssh-keyscan failed for ${KHOST}:${KPORT} (reachable? right host/IP/port?)"
    say "Trusted KISS host key (${KHOST}:${KPORT})."
    say "Testing the connection ..."
    if ! kiss_reachable; then
        hr
        say "Still can't authenticate. Authorize the PUBLIC key above on the KISS"
        say "'${KUSER}' account, then re-run this wizard."
        hr
        die "connection test failed."
    fi
    say "Connection OK."
fi

# Repo path on KISS (always confirmed; must be absolute — a pathless repo lands
# restic at the chroot root and fails on permissions).
RPATH="$(ask 'repo path on KISS (absolute, e.g. /data/restic-repo)' '/data/restic-repo')"
RPATH="$(printf '%s' "$RPATH" | tr -d '[:space:]')"
case "$RPATH" in
    /?*) : ;;
    *) die "repo path must be an absolute path like /data/restic-repo (got: '${RPATH}')." ;;
esac
REPO="sftp:${ALIAS}:${RPATH}"

# Opt in/out.
say ""
if ! yes "Enable offsite backups on this box?" "y/N"; then
    say "Leaving backups OFF. Re-run this wizard any time to enable."
    exit 0
fi
DB="false"; if yes "Also enable database backups (mariabackup + per-DB dumps)?" "Y/n"; then DB="true"; fi

# Persist the opt-in to host.yml (managed block; the converge reads this).
install -d -m 0755 "$(dirname "$HOST_YML")"
touch "$HOST_YML"
tmp="$(mktemp)"
sed '/^# >>> backup-setup >>>$/,/^# <<< backup-setup <<<$/d' "$HOST_YML" > "$tmp"
{
    cat "$tmp"
    printf '# >>> backup-setup >>>\n'
    printf 'backups_enabled: true\n'
    printf 'backups_db_enabled: %s\n' "$DB"
    printf 'backups_repo: "%s"\n' "$REPO"
    printf '# <<< backup-setup <<<\n'
} > "$HOST_YML"
rm -f "$tmp"
say "Saved backups_enabled/backups_repo to ${HOST_YML} (converge keeps it running + installs timers)."

# Render config + deploy engine for immediate use (the role re-renders these
#    authoritatively on the next converge; identical content).
install -d -m 0755 "$(dirname "$ENGINE")" "$(dirname "$BACKUP_ENV")"
install -d -m 0700 "$(dirname "$PASSFILE")"
[ -x "$ENGINE" ] || { [ -s "$ENGINE_SRC" ] && install -m 0750 "$ENGINE_SRC" "$ENGINE"; }
[ -x "$ENGINE" ] || die "backup engine not found ($ENGINE / $ENGINE_SRC)"
{
    printf '# backup-setup (interim; backups_foundation re-renders on converge)\n'
    printf 'BACKUP_REPO="%s"\n' "$REPO"
    printf 'BACKUP_PASSFILE="%s"\n' "$PASSFILE"
    printf 'BACKUP_PATHS="%s"\n' "$PATHS"
    printf 'BACKUP_TAG="%s"\n' "$(hostname -s 2>/dev/null || echo vps)"
    printf 'RESTIC_BIN="%s"\n' "$RESTIC_BIN"
    printf 'RESTIC_VERSION="%s"\n' "$RESTIC_VERSION"
} > "$BACKUP_ENV"
chmod 0640 "$BACKUP_ENV"

# Install restic (if needed) + initialise the repo (generates the passphrase).
say ""; say "Installing restic ..."
"$ENGINE" install || die "restic install failed"

# New repo, or RECONNECTING to an existing one you hold the passphrase for (disaster
# recovery / re-pointing a rebuilt box)? For "existing", seed + verify the passphrase
# BEFORE init so init adopts the repo; for "new", init generates a fresh passphrase.
if yes "Reconnecting to an EXISTING repo you have the passphrase for?" "y/N"; then
    say "Paste the existing repo passphrase (input hidden):"
    IFS= read -r -s existing_pass; echo
    [ -n "$existing_pass" ] || die "no passphrase entered."
    ( umask 077; printf '%s\n' "$existing_pass" > "$PASSFILE" ); unset existing_pass
    if "$RESTIC_BIN" -r "$REPO" --password-file "$PASSFILE" cat config >/dev/null 2>&1; then
        say "  ✓ passphrase verified — existing repo opened; it will be reused as-is."
    else
        rm -f "$PASSFILE"
        die "that passphrase does not open ${REPO} (your repo + data are untouched) — re-run with the correct one."
    fi
fi

say "Initialising the repo ..."
if ! "$ENGINE" init; then
    hr
    say "Repo init failed. If a repo ALREADY exists at '${RPATH}' (e.g. created"
    say "earlier with a different passphrase), restic refuses to re-initialise it —"
    say "your existing data is NOT touched. Either restore that repo's passphrase to"
    say "${PASSFILE} and re-run, or choose a NEW repo path."
    hr
    die "repo init failed"
fi

# Show the passphrase + the break-glass escrow warning.
say ""; hr
say "REPO PASSPHRASE — SAVE THIS TO YOUR PASSWORD MANAGER NOW"
hr
[ -s "$PASSFILE" ] && cat "$PASSFILE"
hr
say "This is the ONLY key that can DECRYPT the offsite backups. It lives on this"
say "box at ${PASSFILE}, but if the box is ever lost, that copy goes with it — the"
say "escrowed copy in your password manager is then the only way to restore."
say "Losing it = the backups are permanently unrecoverable."
hr

# Verify with a SMALL round-trip (a few KB) — proves the repo accepts a backup and
# restores it, WITHOUT starting the full dataset backup. Fast, non-blocking.
say ""; say "Verifying with a small test (writes + restores a few KB — NOT the full backup) ..."
vd="$(mktemp -d)"; printf 'kiss-backup verify\n' > "${vd}/verify.txt"
if "$RESTIC_BIN" -r "$REPO" --password-file "$PASSFILE" backup "${vd}/verify.txt" --tag verify >/dev/null 2>&1 \
   && "$RESTIC_BIN" -r "$REPO" --password-file "$PASSFILE" restore latest --tag verify --target "${vd}/r" >/dev/null 2>&1 \
   && find "${vd}/r" -name verify.txt -exec grep -q 'kiss-backup verify' {} +; then
    say "  ✓ verified — the repo accepts a backup and restores it cleanly."
    "$RESTIC_BIN" -r "$REPO" --password-file "$PASSFILE" forget --tag verify --keep-last 1 >/dev/null 2>&1 || true
    rm -rf "$vd"
else
    rm -rf "$vd"
    die "verification failed — backups are NOT working yet (see output above)."
fi

# Set expectations BEFORE anything heavy runs, and leave the choice with the operator.
say ""; hr
say "WHAT HAPPENS NEXT"
hr
say "A full backup runs automatically every HOUR — restic only ships what changed,"
say "so after the first (full) run each one is tiny. Backups begin within ~15 min of"
say "setup. The most recent 24 are kept hour-by-hour (rolling 24h), then thinned to"
say "daily/weekly/monthly. The file backup covers:"
say "    ${PATHS}"
say "  (site data, system + web-server configs, crontabs, certificates; the engine"
say "   skips any path not present on this box)."
if [ "$DB" = "true" ]; then
    say "Databases: nightly full + hourly differential (local) + a daily per-DB dump (offsite)."
else
    say "Databases: not enabled."
fi
say "The live database files (/var/lib/mysql) are handled by the DB backup, not here."
say ""
say "The FIRST full backup can be large (a big /home takes a while) and holds this"
say "terminal until it finishes. You can let tonight's schedule do it, or run it now."
hr
FULL_NOW="left to the nightly schedule"
if yes "Run the first FULL backup now (otherwise the schedule handles it)?" "y/N"; then
    # Run DETACHED so it doesn't hold the terminal and survives a disconnect — a
    # transient systemd unit (journald-logged), not a foreground/child process.
    if command -v systemd-run >/dev/null 2>&1 \
       && systemd-run --unit=kiss-backup-now --collect --description='kiss-backup first full backup' \
            "$ENGINE" backup >/dev/null 2>&1; then
        FULL_NOW="started now, in the background (systemd unit kiss-backup-now)"
        say "  ↳ started in the BACKGROUND (systemd unit 'kiss-backup-now') — your terminal is free,"
        say "    and it keeps running if this session disconnects."
        say "    Watch:   journalctl -u kiss-backup-now -f"
        say "    Status:  systemctl status kiss-backup-now"
    else
        say "  Couldn't start it in the background — run it yourself, detached:"
        say "    systemd-run --unit=kiss-backup-now --collect ${ENGINE} backup"
    fi
else
    say "OK — leaving it to the schedule. Run it any time (detached) with:"
    say "    systemd-run --unit=kiss-backup-now --collect ${ENGINE} backup"
fi

# Confirmation email — the permanent record of what was configured + that it
# verified (the slice-3 backup-configured event). Best-effort: vps_notify audits to
# journald even when no MTA/recipient is set, so this never blocks setup.
if [ -x "$NOTIFY_ENGINE" ]; then
    host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo '?')"
    db_line="not enabled"
    [ "$DB" = "true" ] && db_line="local hourly chain + daily offsite dump"
    rule="$(printf '%72s' '' | tr ' ' -)"   # all-dashes => vps_notify renders it brand-orange
    cbody="$(mktemp)"
    {
        printf '%s\n' "$rule"
        printf '  Offsite backups configured + VERIFIED on %s\n' "$host"
        printf '%s\n\n' "$rule"
        printf '  %-11s %s\n\n' 'Verify'     'PASSED — small write + restore round-trip'
        printf '  %-11s %s\n\n' 'Protection' 'AES-256 · zstd · deduplicated · immutable offsite'
        printf '  %-11s %s\n\n' 'Repository' "$REPO"
        printf '  %-11s %s\n'   'Files'      "$PATHS"
        printf '  %-11s %s\n\n' ''           '(site data, configs, crontabs, certificates)'
        printf '  %-11s %s\n\n' 'Databases'  "$db_line"
        printf '  %-11s %s\n\n' 'Schedule'   'a full backup every HOUR (incremental — tiny after #1)'
        printf '  %-11s %s\n\n' 'Retention'  '24h rolling + 14 daily + 8 weekly + 12 monthly (GFS)'
        printf '  %-11s %s\n'   'First full' "$FULL_NOW"
        printf '%s\n' "$rule"
        printf '  PASSPHRASE (break-glass):  %s\n' "$PASSFILE"
        printf '  The ONLY key that decrypts the offsite backups — escrow it in your\n'
        printf '  password manager. If the box is lost, the on-box copy goes with it.\n'
        printf '%s\n\n' "$rule"
        printf '  See coverage + live size/dedup stats any time (real after backup #1):\n'
        printf '  %s status\n' "$0"
    } > "$cbody"
    if notify_err="$("$NOTIFY_ENGINE" --event backup-configured \
            --subject "Backups configured + verified on ${host}" \
            --body-file "$cbody" 2>&1)"; then
        say ""; say "A confirmation email has been sent to ops (audited to journald)."
    else
        # Surface the REAL reason (the old vague 'mail not ready' hid a stale-notifier
        # 'unknown event' once). Show vps_notify's own message; setup is unaffected.
        say ""; say "(Confirmation email NOT sent — ${notify_err:-unknown reason}. Setup itself is fine.)"
    fi
    rm -f "$cbody"
fi

say ""; say "Done. Backups are configured and verified."
say "Re-check anytime what's backed up + the schedule:  $0 status"
