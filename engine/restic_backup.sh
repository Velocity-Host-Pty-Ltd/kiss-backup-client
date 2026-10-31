#!/bin/bash
#
# Restic Backup Engine
# Version: 1.5.0
# Script Name: restic_backup_v1.sh
# Project: vps-baseline / headless CloudLinux 8.10 VPS platform
# Summary: The procedural core of the backups_foundation role — installs a pinned,
#   SHA-verified restic; initialises a per-VPS repo (generating the passphrase on
#   first run if absent); and runs CPU/IO-capped file backups, integrity checks,
#   GFS retention (forget) and the separate disk-reclaim (prune). One repo per VPS,
#   client-side AES-256, native SFTP backend. The Ansible role is one front end;
#   this engine is idempotent and safe to re-run from a systemd timer.
#
# Purpose:
#   Engine/front-end split (platform-architecture.md §3, handover §11): the role
#   deploys this script from the baseline checkout and renders /etc/vps-tooling/
#   backup.env; the timers invoke the subcommands below. Settled design points
#   (backups_handover.md §13 + prototype runbook §5): GFS-B default retention;
#   forget != prune (forget is metadata-only, prune is the weekly disk-reclaim);
#   dump UNCOMPRESSED + let restic dedup; mandatory excludes (live DB datadir,
#   restic cache); caps via GOMAXPROCS/nice/ionice so a backup can never starve
#   the tenant sites.
#
# Usage:
#   restic_backup_v1.sh install                 # install/verify the pinned restic binary
#   restic_backup_v1.sh init                    # init the repo (+ passphrase) if absent
#   restic_backup_v1.sh backup                  # capped file backup of BACKUP_PATHS
#   restic_backup_v1.sh check [--read-data-subset=N%]   # integrity check (exit code = verdict)
#   restic_backup_v1.sh forget                  # apply GFS retention (NO prune)
#   restic_backup_v1.sh prune                   # reclaim disk (locks repo; weekly)
#   restic_backup_v1.sh snapshots               # list snapshots
#   restic_backup_v1.sh db-backup [full|diff]   # mariabackup full / DIFFERENTIAL -> restic (hot, capped)
#   restic_backup_v1.sh db-dump                 # per-database mysqldump -> restic (daily, logical)
#   restic_backup_v1.sh restore-drill           # verify backups RESTORE (file + rotating DB import); non-destructive
#   restic_backup_v1.sh validate-excludes       # screen the operator exclude file for dangerous (root-nuking) patterns
# Examples (real on-box path; /usr/local/bin is not on root's login PATH):
#   /usr/local/bin/vps-tooling/restic_backup_v1.sh snapshots
#   /usr/local/bin/vps-tooling/restic_backup_v1.sh check --read-data-subset=5%
#
# Config: sourced from $BACKUP_ENV (default $KBC_CONFIG_DIR/backup.env, i.e.
#   /etc/kiss-backup/backup.env). Run as: root (from systemd units). Exit non-zero on failure so the
#   watchdog/notification framework can route it.
#
set -u

readonly KBC_CONFIG_DIR="${KBC_CONFIG_DIR:-/etc/kiss-backup}"
readonly BACKUP_ENV="${BACKUP_ENV:-$KBC_CONFIG_DIR/backup.env}"
readonly TAG="kiss-backup"

log()  { logger -t "$TAG" -- "$*" 2>/dev/null || true; printf '%s %s\n' "$(date '+%F %T')" "$*"; }
die()  { log "FATAL: $*"; exit 1; }

# Help must work on ANY box, before the config is even required — short-circuit
# here (the config block below would otherwise die without $BACKUP_ENV).
case "${1:-}" in
    -h|--help|help) sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
esac

# ---- config -----------------------------------------------------------------
[ -r "$BACKUP_ENV" ] || die "config not readable: $BACKUP_ENV (is the role deployed?)"
# shellcheck disable=SC1090
. "$BACKUP_ENV"

RESTIC_BIN="${RESTIC_BIN:-/usr/local/bin/restic}"
BACKUP_PASSFILE="${BACKUP_PASSFILE:-/etc/restic/backup.pass}"
BACKUP_TAG="${BACKUP_TAG:-$(hostname -s 2>/dev/null || echo vps)}"
GOMAXPROCS_CAP="${GOMAXPROCS:-2}"
NICE_N="${NICE:-19}"
IONICE_CLASS="${IONICE_CLASS:-3}"

# Retention (GFS policy "B" default — backups_handover.md §13). The repo holds only
# the file backups + per-DB logical dumps (the physical chain is local-only), and
# both want the same GFS window, so a single forget covers the repo (hour-granular
# last 24h + daily 14 + weekly 8 + monthly 12); restic forget groups by path.
KEEP_HOURLY="${KEEP_HOURLY:-24}"
KEEP_DAILY="${KEEP_DAILY:-14}"
KEEP_WEEKLY="${KEEP_WEEKLY:-8}"
KEEP_MONTHLY="${KEEP_MONTHLY:-12}"

# Database slice (handover §3.1): two paths. (1) mariabackup physical chain (hot,
# whole-instance: nightly full + hourly DIFFERENTIAL) kept LOCAL (short-term,
# hour-granular point-in-time; 2 generations ~48h) — NOT shipped to restic. (2)
# per-database logical mysqldump → restic (the offsite, long-retained, per-DB store).
# DB tools auth via unix_socket as root (passwordless OS-identity — the platform model).
DB_STAGE="${BACKUP_DB_STAGE:-/var/lib/kiss-backups/mariabackup}"
DB_DUMP_DIR="${BACKUP_DB_DUMP_DIR:-/var/lib/kiss-backups/dumps}"
MARIABACKUP_BIN="${MARIABACKUP_BIN:-mariabackup}"
MYSQL_BIN="${MYSQL_BIN:-mysql}"
MYSQLDUMP_BIN="${MYSQLDUMP_BIN:-mysqldump}"
# System schemas excluded from per-database dumps (anchored extended-regex). Also
# excludes the restore-drill's throwaway DB so a drill mid-run can't be dumped.
DB_DUMP_EXCLUDE="${BACKUP_DB_DUMP_EXCLUDE:-information_schema|performance_schema|mysql|sys|_restoredrill}"

# Restore-drill (verify backups actually RESTORE — the "a backup you haven't
# restored isn't one" check). GOAL = process health: a small file is restored from
# the repo end-to-end, and per-DB dumps are restored + import-verified on a ROTATING
# cursor up to a per-run size BUDGET (does several small DBs or one big one, never
# the whole fleet at once). Non-destructive (scratch + a throwaway temp DB, dropped).
# The timer pins it to 1 CPU + idle IO so it can't starve sites; failure -> notify.
DRILL_SCRATCH="${BACKUP_DRILL_SCRATCH:-/var/lib/kiss-backups/drill}"
DRILL_FILE="${BACKUP_DRILL_FILE:-/etc/hostname}"          # small sentinel (must be within BACKUP_PATHS)
DRILL_DB_IMPORT="${BACKUP_DRILL_DB_IMPORT:-1}"            # 1=import-verify dumps, 0=file check only
DRILL_DB_BUDGET_BYTES="${BACKUP_DRILL_DB_BUDGET_BYTES:-1610612736}"  # ~1.5 GiB restored/run
DRILL_TMPDB="_restoredrill"
DRILL_CURSOR="$DRILL_SCRATCH/.cursor"

[ -n "${BACKUP_REPO:-}" ] || die "BACKUP_REPO unset in $BACKUP_ENV"

# Mandatory excludes (handover §11): never back up the live DB datadir (use the
# DB engine for that) or restic's own cache (bloat/loopback). BACKUP_EXCLUDES adds
# site-specific patterns on top.
readonly -a MANDATORY_EXCLUDES=(
    "/var/lib/mysql"
    "/root/.cache/restic"
    "/var/cache/restic"
    "*/.cache/restic"
)

# Redundant-backup excludes: output dirs of WP backup PLUGINS — these are
# backups-of-backups (often many GB of zip/tar archives that restic would re-ingest
# every run) and pure waste to ship offsite. Matched by base name at any depth
# (restic's no-slash pattern semantics), so they catch the dir wherever the plugin
# wrote it (wp-content/, uploads/, site root). Curated default; an operator can still
# add to it via BACKUP_EXCLUDES. Glob patterns are array elements (quoted) so the
# SHELL never expands them — restic does the matching.
readonly -a REDUNDANT_EXCLUDES=(
    # Distinctive plugin directory base-names (matched at any depth) — verified
    # against wordpress.org / vendor docs / plugin source (2026-06-21).
    "updraft"                 # UpdraftPlus
    "ai1wm-backups"           # All-in-One WP Migration
    "ai1wm-storage"           # All-in-One WP Migration (temp/storage)
    "backups-dup-lite"        # Duplicator Lite
    "backups-dup-pro"         # Duplicator Pro
    "wpvividbackups"          # WPvivid
    "wp-staging"              # WP STAGING
    "backupbuddy_backups"     # BackupBuddy / Solid Backups
    "backupbuddy_temp"        # BackupBuddy (temp)
    "wpbackitup_backups"      # WPBackItUp
    "boldgrid_backup"         # Total Upkeep (when it lands in wp-content)
    "tCapsule"                # WP Time Capsule (local DB staging)
    "backwpup-*"              # BackWPup (randomized suffix)
    "backup-migration*"       # Backup Migration / BackupBliss (randomized suffix)
    # Plugin-INVENTED file extensions (unique enough to match by extension; generic
    # .zip/.tar.gz are NOT here — they collide with real uploads, so we never
    # extension-match those: scope them to the dirs above instead).
    "*.wpress"                # All-in-One WP Migration
    "*.wpstg"                 # WP STAGING
    "*.daf"                   # Duplicator archive format
)

# Operator-editable exclude file (layer 3): a human-maintained list of extra exclude
# patterns (the role ships it once with instructions, then never overwrites it, so
# edits survive every converge). Patterns use restic's syntax; a `*` stands in for
# the account name so one line templates across all accounts, e.g.
#   /home/*/public_html/wp-content/my-custom-backups
# Screened by is_dangerous_exclude() before every backup — see safe_exclude_patterns.
BACKUP_EXCLUDE_FILE="${BACKUP_EXCLUDE_FILE:-$KBC_CONFIG_DIR/backup-excludes.conf}"

export RESTIC_PASSWORD_FILE="$BACKUP_PASSFILE"

# restic caches the repo index under $HOME/.cache by default. A root systemd oneshot
# has NO $HOME, and restic 0.19 treats "cannot locate a cache dir" as FATAL (not a
# warning) — so EVERY restic call exits non-zero under the timer: db-dump's `backup`
# dies, and cmd_init's `cat config` guard misfires into a bogus "repo already exists"
# init failure for the file backup. Pin an explicit, HOME-independent cache so the
# timer and an interactive shell agree. /var/cache/restic is in MANDATORY_EXCLUDES, so
# it never ships offsite; restic creates it (0700) on first use. Verified on test4
# (restic 0.19.0, 2026-06-22): without this `cat config` exits 1, with it exits 0.
export RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR:-/var/cache/restic}"

# restic invoked with the configured repo + caps. Password comes via the file
# (never on the command line — avoids the argv-password footgun, CLAUDE.md §4).
restic_capped() {
    GOMAXPROCS="$GOMAXPROCS_CAP" nice -n "$NICE_N" ionice -c "$IONICE_CLASS" \
        "$RESTIC_BIN" -r "$BACKUP_REPO" "$@"
}
restic_plain() { "$RESTIC_BIN" -r "$BACKUP_REPO" "$@"; }

# check/forget/prune need an EXCLUSIVE lock; a crashed or killed prior run can
# leave a stale lock that blocks them (a backup, holding only a non-exclusive
# lock, sails past — so this bites the maintenance ops, not the backup). `restic
# unlock` removes ONLY stale locks (dead process / aged-out), never a live one,
# so it is safe to run before an exclusive operation.
clear_stale_locks() { restic_plain unlock >/dev/null 2>&1 || true; }

# --- shared backup/restore mutex (cross-engine) ------------------------------
# An advisory lock guards every state-changing backup/restore op across BOTH this scheduled
# engine and the on-demand backup_ondemand_v1.sh. It covers the gap restic's repo lock CANNOT:
# the live `mysqldump`/`mariabackup`/import windows — without it a timer could snapshot a
# half-restored DB (or a half-restored docroot) mid-restore. Scheduled ops take it NON-BLOCKING
# and DEFER if an operator restore/checkpoint holds it (Persistent= timers catch the next tick);
# the on-demand engine waits briefly then refuses. fd 9 is held for the process lifetime.
# Fail-open (mutex disabled + warning) if flock/the lockfile is unavailable — a missing mutex
# must never wedge backups. The on-demand engine carries an identical helper + the same path.
BACKUP_LOCK="${BACKUP_LOCK:-/run/lock/kiss-backup.lock}"
take_backup_lock() {            # take_backup_lock nowait | <wait-seconds>
    command -v flock >/dev/null 2>&1 || { log "WARN: flock not found — backup/restore mutex disabled"; return 0; }
    exec 9>"$BACKUP_LOCK" 2>/dev/null || { log "WARN: cannot open $BACKUP_LOCK — mutex disabled"; return 0; }
    case "$1" in
        nowait) flock -n 9 ;;
        *)      flock -w "$1" 9 ;;
    esac
}

# Run an exclusive op (forget/prune/check) and treat a LIVE-lock collision as a soft
# defer, not a fault. clear_stale_locks already cleared any DEAD lock, so if restic
# still can't lock it's because a genuinely-live holder has the repo — an operator's
# `restic mount` left open, or a long backup still running. restic exits 11 ("Failed
# to lock repository", restic >=0.17; box runs 0.19 — restic docs 075_scripting,
# verified 2026-06-22) for exactly that. We log + return 0 so the next timer tick
# retries, instead of die-ing: as the backup unit's ExecStartPost, a die here fails an
# already-good backup and pages on a non-problem. Any OTHER non-zero (repo damage,
# missing repo, bad password) is a real fault → die, as before.
# Usage: run_exclusive <label> <restic-subcommand+args...>
run_exclusive() {
    local op="$1"; shift
    local rc=0
    restic_capped "$@" || rc=$?
    case "$rc" in
        0)  log "$op ok" ;;
        11) log "$op deferred — repo busy (a live op holds the lock); will retry next cycle" ;;
        *)  die "$op failed (restic exit $rc)" ;;
    esac
}

# DB tools are native (GOMAXPROCS is a Go knob, irrelevant here) — cap I/O + CPU
# priority only, so a hot backup can't starve the live instance.
db_capped() { nice -n "$NICE_N" ionice -c "$IONICE_CLASS" "$@"; }

# Is an operator exclude pattern DANGEROUSLY broad — would it exclude a whole backup
# root (or everything)? The only real footgun in a hand-edited exclude file: a
# fat-fingered '/', '*', or '/home' silently excludes the entire backup. We screen
# those out (and warn) so a bad line fails toward backing up MORE, never nothing.
# Returns 0 (true) = dangerous. Specific patterns like
# /home/*/public_html/wp-content/foo are fine.
is_dangerous_exclude() {
    local p="$1" n root
    case "$p" in ''|'/'|'*'|'**'|'/*'|'/**'|'*/'|'**/') return 0 ;; esac
    n="${p%/}"; n="${n%/\*\*}"; n="${n%/\*}"; n="${n%/}"   # strip trailing /,/*,/**
    [ -z "$n" ] && return 0
    for root in $BACKUP_PATHS; do                          # word-split intentional
        [ "$n" = "$root" ] && return 0                     # excludes a whole root
        case "$root" in "$n"/*) return 0 ;; esac           # n is an ancestor of a root
    done
    return 1
}

# Emit the SAFE operator exclude patterns (one per line) from BACKUP_EXCLUDE_FILE:
# skip comments/blanks, drop + loudly warn on any dangerous pattern. $1=warn|quiet.
safe_exclude_patterns() {
    local mode="${1:-warn}" line p
    [ -r "$BACKUP_EXCLUDE_FILE" ] || return 0
    while IFS= read -r line || [ -n "$line" ]; do
        p="${line%%#*}"                                    # strip inline comment
        p="$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$p" ] || continue
        if is_dangerous_exclude "$p"; then
            [ "$mode" = warn ] && log "WARNING: ignoring DANGEROUS exclude '$p' from $BACKUP_EXCLUDE_FILE (would exclude a whole backup root)"
            continue
        fi
        printf '%s\n' "$p"
    done < "$BACKUP_EXCLUDE_FILE"
}

# ---- subcommands ------------------------------------------------------------

# validate-excludes: screen the operator exclude file + report each pattern (OK or
# DANGEROUS-and-skipped). Run after editing. Exit 0 if all OK, 1 if any dangerous.
cmd_validate_excludes() {
    local line p bad=0 n=0
    if [ ! -r "$BACKUP_EXCLUDE_FILE" ]; then
        log "no operator exclude file at $BACKUP_EXCLUDE_FILE (nothing to validate)"; return 0
    fi
    log "validating $BACKUP_EXCLUDE_FILE (against backup roots: $BACKUP_PATHS)"
    while IFS= read -r line || [ -n "$line" ]; do
        p="${line%%#*}"
        p="$(printf '%s' "$p" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -n "$p" ] || continue
        n=$((n + 1))
        if is_dangerous_exclude "$p"; then
            printf '  DANGEROUS (will be SKIPPED): %s\n' "$p"; bad=$((bad + 1))
        else
            printf '  ok: %s\n' "$p"
        fi
    done < "$BACKUP_EXCLUDE_FILE"
    log "checked $n pattern(s): $bad dangerous"
    [ "$bad" -eq 0 ]
}

# Official SHA256s of the pinned restic release assets, copied from the release's
# SHA256SUMS (github.com/restic/restic/releases/download/v<ver>/SHA256SUMS). Bump
# these together with RESTIC_VERSION. RESTIC_SHA256 in backup.env overrides them.
restic_pinned_sha256() {
    case "$1" in
        0.19.0_amd64) echo 13176fe6d89d4357947a2cd107218ab2873a5f9d8e1ac2d4cd1c8e07e6839c21 ;;
        0.19.0_arm64) echo e522ce6bf748d753fee8093e8ec59359972cf5b6bc65fc7c7cf38ae952351d91 ;;
    esac
}

cmd_install() {
    local want="${RESTIC_VERSION:-}" sha="${RESTIC_SHA256:-}" arch
    [ -n "$want" ] || die "RESTIC_VERSION unset — refusing to install an unpinned restic"
    if [ -x "$RESTIC_BIN" ] && "$RESTIC_BIN" version 2>/dev/null | grep -q "restic ${want}\b"; then
        log "restic ${want} already installed at $RESTIC_BIN"
        return 0
    fi
    local tmp bz url
    tmp="$(mktemp -d)" || die "mktemp failed"
    # shellcheck disable=SC2064
    trap "rm -rf '$tmp'" RETURN
    case "$(uname -m)" in
        x86_64)        arch=amd64 ;;
        aarch64|arm64) arch=arm64 ;;
        *) die "unsupported CPU architecture: $(uname -m)" ;;
    esac
    [ -n "$sha" ] || sha="$(restic_pinned_sha256 "${want}_${arch}")"
    # A root-run binary that reads the whole box must be verified. Opt out only
    # deliberately (e.g. testing an unreleased version).
    [ -n "$sha" ] || [ "${RESTIC_ALLOW_UNVERIFIED:-0}" = 1 ] \
        || die "no SHA256 known for restic ${want} (${arch}) — set RESTIC_SHA256 in backup.env"
    bz="restic_${want}_linux_${arch}.bz2"
    url="https://github.com/restic/restic/releases/download/v${want}/${bz}"
    log "downloading restic ${want}"
    curl -fsSL -o "$tmp/$bz" "$url" || die "download failed: $url"
    if [ -n "$sha" ]; then
        printf '%s  %s\n' "$sha" "$tmp/$bz" | sha256sum -c - >/dev/null 2>&1 \
            || die "SHA256 mismatch for $bz — refusing to install"
        log "SHA256 verified"
    else
        log "WARNING: RESTIC_ALLOW_UNVERIFIED=1 — installing without checksum verification"
    fi
    bunzip2 -f "$tmp/$bz" || die "bunzip2 failed"
    install -m 0755 "$tmp/restic_${want}_linux_${arch}" "$RESTIC_BIN" || die "install failed"
    log "installed restic ${want} -> $RESTIC_BIN"
}

# Generate the per-VPS passphrase on first use if absent (handover §9 decision:
# generate-on-first-run + surface; formal escrow pending). 0600, root-only.
ensure_passfile() {
    [ -s "$BACKUP_PASSFILE" ] && return 0
    install -d -m 0700 "$(dirname "$BACKUP_PASSFILE")"
    ( umask 077; openssl rand -base64 24 > "$BACKUP_PASSFILE" ) || die "passphrase generation failed"
    chmod 600 "$BACKUP_PASSFILE"
    log "GENERATED new repo passphrase at $BACKUP_PASSFILE — ESCROW IT (loss = unrecoverable backups)"
}

cmd_init() {
    ensure_passfile
    if restic_plain cat config >/dev/null 2>&1; then
        log "repo already initialised: $BACKUP_REPO"
        return 0
    fi
    log "initialising repo: $BACKUP_REPO"
    restic_plain init || die "restic init failed"
    log "repo initialised"
}

cmd_backup() {
    [ -n "${BACKUP_PATHS:-}" ] || die "BACKUP_PATHS unset in $BACKUP_ENV"
    local -a args=(backup --compression auto --tag "$BACKUP_TAG")
    local x p
    for x in "${MANDATORY_EXCLUDES[@]}"; do args+=(--exclude "$x"); done
    for x in "${REDUNDANT_EXCLUDES[@]}"; do args+=(--exclude "$x"); done
    for x in ${BACKUP_EXCLUDES:-}; do args+=(--exclude "$x"); done
    # Layer 3: operator-editable file, with dangerous (root-nuking) patterns screened
    # out + warned — so a fat-fingered line can never silently exclude everything.
    while IFS= read -r x; do [ -n "$x" ] && args+=(--exclude "$x"); done < <(safe_exclude_patterns warn)
    # Only back up paths that actually exist: the default set spans web-stack
    # variants (e.g. /usr/local/lsws/conf is absent on Apache boxes), and restic
    # exits non-zero on a missing source — which would flag a healthy run as failed.
    local -a paths=()
    # shellcheck disable=SC2086
    for p in $BACKUP_PATHS; do                       # word-split is intentional
        if [ -e "$p" ]; then paths+=("$p"); else log "skip (absent): $p"; fi
    done
    [ "${#paths[@]}" -gt 0 ] || die "none of BACKUP_PATHS exist: $BACKUP_PATHS"
    log "backup start: paths=[${paths[*]}] repo=$BACKUP_REPO"
    restic_capped "${args[@]}" "${paths[@]}" || die "backup failed"
    log "backup ok"
}

cmd_check() {
    log "check start"
    clear_stale_locks
    # extra args (e.g. --read-data-subset=5%) passed through. A non-11 non-zero is a
    # real integrity verdict (repo damaged) → die; an 11 means it was busy → defer.
    run_exclusive check check "$@"
}

cmd_forget() {
    log "forget (GFS) start — metadata only, no prune"
    clear_stale_locks
    run_exclusive forget forget \
        --keep-hourly "$KEEP_HOURLY" --keep-daily "$KEEP_DAILY" \
        --keep-weekly "$KEEP_WEEKLY" --keep-monthly "$KEEP_MONTHLY"
}

cmd_prune() {
    log "prune start — reclaims disk, locks repo (run weekly, not per-backup)"
    clear_stale_locks
    run_exclusive prune prune
}

cmd_snapshots() { restic_plain snapshots; }

# mariabackup physical chain — LOCAL ONLY, deliberately NOT shipped to restic.
# WHOLE-INSTANCE (all databases, page-level): mariabackup chains are instance-level
# by design — partial/per-DB backups CANNOT base an incremental/differential chain
# (MariaDB KB) — and per-TENANT/single-DB recovery does NOT come from here; it comes
# from db-dump (logical, per-DB, offsite in restic) or restore-aside. This chain is
# only the SHORT-TERM, hour-granular, on-box point-in-time layer ("roll back 3h" on a
# live box). Box-loss recovery is covered offsite by the nightly db-dump (≤24h RPO)
# + the hypervisor (PBS) snapshot, so duplicating the hourly chain into restic would
# be overlap + per-hour restic cycles fleet-wide for no gain — hence local-only.
#
# `full` = nightly base; `diff` = DIFFERENTIAL (basedir ALWAYS the full, never a
# prior diff) so any hour restores from full + exactly ONE diff (short, robust; a
# degraded diff can't break the others). TWO GENERATIONS are kept (~48h): a new full
# is built into the inactive slot and only becomes `current` on success, so a failed
# nightly full never destroys the working chain. Storage is bounded to ~2×(full +
# its diffs) — monitor the staging filesystem. --prepare/--copy-back restore is an
# operator runbook step, never done here; mariabackup logs to the journal (stderr).
cmd_db_backup() {
    local mode="${1:-diff}"
    [ "$mode" = "incremental" ] && mode="diff"   # legacy keyword -> differential
    command -v "$MARIABACKUP_BIN" >/dev/null 2>&1 || die "$MARIABACKUP_BIN not found"
    install -d -m 0700 "$DB_STAGE"
    local cur other
    cur="$(cat "$DB_STAGE/.current" 2>/dev/null || echo gen-a)"
    # No current base yet (fresh box, before the first full) -> promote to full.
    if [ "$mode" = "diff" ] && [ ! -d "$DB_STAGE/$cur/full" ]; then
        log "db-backup: no current base full — promoting to full"
        mode="full"
    fi
    if [ "$mode" = "full" ]; then
        # Build into the INACTIVE slot; flip `current` to it only on success, so a
        # failed full leaves the working generation intact. Clearing the inactive
        # slot first drops the previous-previous generation (2-generation cap).
        [ "$cur" = "gen-a" ] && other="gen-b" || other="gen-a"
        log "db-backup FULL start -> $other (current stays $cur until success)"
        # Recreate the slot empty: mariabackup creates the target-dir leaf but NOT
        # its parents, so the generation dir must exist (and be clean) first.
        rm -rf "${DB_STAGE:?}/$other"
        mkdir -p "$DB_STAGE/$other"
        db_capped "$MARIABACKUP_BIN" --backup --target-dir="$DB_STAGE/$other/full" \
            || die "mariabackup full failed (current generation $cur left intact)"
        echo "$other" > "$DB_STAGE/.current"
        log "db-backup FULL ok — current=$other ($cur retained as previous)"
    else
        local n=1
        while [ -d "$DB_STAGE/$cur/diff.$n" ]; do n=$((n + 1)); done
        log "db-backup DIFFERENTIAL start ($cur: base=full -> diff.$n)"
        db_capped "$MARIABACKUP_BIN" --backup \
            --incremental-basedir="$DB_STAGE/$cur/full" --target-dir="$DB_STAGE/$cur/diff.$n" \
            || die "mariabackup differential failed"
        log "db-backup DIFFERENTIAL ok ($cur/diff.$n)"
    fi
}

# Per-database logical dump -> restic. One file per DB (selective single-DB
# restore), UNCOMPRESSED (gzip would defeat restic dedup — runbook §2 gotcha).
# Connects via unix_socket as root; system schemas skipped.
cmd_db_dump() {
    command -v "$MYSQLDUMP_BIN" >/dev/null 2>&1 || die "$MYSQLDUMP_BIN not found"
    install -d -m 0700 "$DB_DUMP_DIR"
    local dbs db count=0
    dbs="$("$MYSQL_BIN" -N -B -e 'SHOW DATABASES' 2>/dev/null)" \
        || die "cannot list databases (unix_socket auth as root?)"
    while IFS= read -r db; do
        [ -n "$db" ] || continue
        printf '%s\n' "$db" | grep -Eq "^($DB_DUMP_EXCLUDE)$" && continue
        db_capped "$MYSQLDUMP_BIN" --single-transaction --routines --triggers --events \
            "$db" > "$DB_DUMP_DIR/$db.sql" || die "mysqldump failed for $db"
        count=$((count + 1))
    done < <(printf '%s\n' "$dbs")
    log "db-dump: dumped $count databases -> $DB_DUMP_DIR"
    restic_capped backup "$DB_DUMP_DIR" --tag db-dump --tag "$BACKUP_TAG" \
        || die "restic backup of dumps failed"
    log "db-dump ok"
}

# --- restore-drill: prove backups actually restore (non-destructive) -----------

# clean up scratch + the throwaway temp DB; runs on function return (success/fail).
drill_cleanup() {
    rm -rf "${DRILL_SCRATCH:?}"/r.* 2>/dev/null || true
    "$MYSQL_BIN" -e "DROP DATABASE IF EXISTS \`$DRILL_TMPDB\`" >/dev/null 2>&1 || true
}

# import a restored dump into a throwaway temp DB on the LIVE instance and confirm
# it replays cleanly (a truncated/corrupt dump errors out -> fail), then drop it.
# Pass = mysql import exits 0 (an empty-but-valid DB is a valid restore); table
# count is informational. Capped (nice/ionice); the timer also pins the CPU.
drill_import() {
    local sql="$1" n
    "$MYSQL_BIN" -e "DROP DATABASE IF EXISTS \`$DRILL_TMPDB\`; CREATE DATABASE \`$DRILL_TMPDB\`" || return 1
    if ! db_capped "$MYSQL_BIN" "$DRILL_TMPDB" < "$sql"; then
        "$MYSQL_BIN" -e "DROP DATABASE IF EXISTS \`$DRILL_TMPDB\`" >/dev/null 2>&1 || true
        return 1
    fi
    n="$("$MYSQL_BIN" -N -e \
        "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$DRILL_TMPDB'" 2>/dev/null || echo 0)"
    "$MYSQL_BIN" -e "DROP DATABASE IF EXISTS \`$DRILL_TMPDB\`" >/dev/null 2>&1 || true
    log "  (imported $n tables)"
    return 0
}

cmd_restore_drill() {
    local fail=0 checked=0
    install -d -m 0700 "$DRILL_SCRATCH"
    trap drill_cleanup RETURN
    log "restore-drill start (db budget=${DRILL_DB_BUDGET_BYTES}B)"

    # 1) FILE: restore a small sentinel from the latest FILE snapshot, end to end.
    local fdir="$DRILL_SCRATCH/r.file"
    rm -rf "$fdir"
    if restic_capped restore latest --path "$(dirname "$DRILL_FILE")" --include "$DRILL_FILE" \
            --target "$fdir" >/dev/null 2>&1 && [ -s "$fdir$DRILL_FILE" ]; then
        log "drill FILE ok: $DRILL_FILE restored + non-empty"
        checked=$((checked + 1))
    else
        log "drill FILE FAIL: could not restore $DRILL_FILE from latest file snapshot"
        fail=$((fail + 1))
    fi

    # 2) DB DUMPS: rotating, budget-bounded import-verify (process health, not full coverage).
    if [ "${DRILL_DB_IMPORT:-1}" = "1" ] && command -v "$MYSQL_BIN" >/dev/null 2>&1; then
        local dumps
        dumps="$(restic_plain ls latest --tag db-dump 2>/dev/null | grep -E '\.sql$' | sort || true)"
        if [ -z "$dumps" ]; then
            log "drill DB: no db-dump snapshot yet — skipped"
        else
            local last order acc=0 seen=" " d ddir sz
            last="$(cat "$DRILL_CURSOR" 2>/dev/null || echo '')"
            # rotate: dumps lexically after the cursor first, then wrap through the rest
            order="$(printf '%s\n' "$dumps" | awk -v c="$last" '$0 > c'; printf '%s\n' "$dumps")"
            while IFS= read -r d; do
                [ -n "$d" ] || continue
                case "$seen" in *" $d "*) continue ;; esac   # de-dupe within this run
                seen="$seen$d "
                ddir="$DRILL_SCRATCH/r.db"
                rm -rf "$ddir"
                log "drill DB: restoring + importing $(basename "$d") (may take minutes)…"
                if restic_capped restore latest --tag db-dump --include "$d" --target "$ddir" \
                        >/dev/null 2>&1 && [ -s "$ddir$d" ] && drill_import "$ddir$d"; then
                    log "drill DB ok: $(basename "$d")"
                    checked=$((checked + 1))
                else
                    log "drill DB FAIL: $(basename "$d") did not restore+import"
                    fail=$((fail + 1))
                fi
                sz="$(stat -c %s "$ddir$d" 2>/dev/null || echo 0)"
                acc=$((acc + sz))
                printf '%s\n' "$d" > "$DRILL_CURSOR"
                [ "$acc" -ge "$DRILL_DB_BUDGET_BYTES" ] && break
            done <<EOF
$order
EOF
        fi
    fi

    log "restore-drill done: passed=$checked failed=$fail"
    [ "$fail" -eq 0 ] || die "restore-drill FAILED ($fail check[s]) — backups may not be restorable"
}

usage() {
    sed -n '/^# Usage:/,/^#$/p' "$0" | sed 's/^# \{0,1\}//'
    exit "${1:-0}"
}

main() {
    local cmd="${1:-}"; shift || true
    # State-changing ops share the cross-engine mutex; defer (not fail) if an on-demand
    # backup/restore holds it — a Persistent= timer catches the next tick. Read-only ops
    # (snapshots, validate-excludes) and one-shot setup (install/init) don't take it.
    case "$cmd" in
        backup|db-backup|db-dump|check|forget|prune|restore-drill)
            take_backup_lock nowait \
                || { log "$cmd deferred — an on-demand backup/restore holds the lock; will retry next cycle"; exit 0; } ;;
    esac
    case "$cmd" in
        install)   cmd_install "$@" ;;
        init)      cmd_init "$@" ;;
        backup)    cmd_backup "$@" ;;
        check)     cmd_check "$@" ;;
        forget)    cmd_forget "$@" ;;
        prune)     cmd_prune "$@" ;;
        snapshots) cmd_snapshots "$@" ;;
        db-backup) cmd_db_backup "$@" ;;
        db-dump)   cmd_db_dump "$@" ;;
        restore-drill) cmd_restore_drill "$@" ;;
        validate-excludes) cmd_validate_excludes "$@" ;;
        ""|-h|--help|help) usage 0 ;;
        *) log "unknown subcommand: $cmd"; usage 2 ;;
    esac
}

main "$@"
