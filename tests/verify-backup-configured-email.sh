#!/bin/bash
#
# verify-backup-configured-email.sh — manual verification helper for the slice-3
# backup-configured confirmation email. Builds a representative body (the same shape
# backup_setup_v1.sh sends) and fires it through vps_notify, so an operator can
# eyeball the real branded email without running the full interactive wizard.
#
# Why this exists: pasting the long multi-line send by hand keeps getting split at
# the line wrap, dropping --body-file. Shipping it as a script (git show -> bash)
# is paste-immune (see memory: command-delivery-format / clone-file-transfer-via-git).
#
# Usage:  bash /tmp/vbc.sh      (run as root on the box under test)
#
set -u
NOTIFY="${NOTIFY:-/usr/local/bin/vps-tooling/vps_notify_v1.sh}"
[ -x "$NOTIFY" ] || { echo "no vps_notify at $NOTIFY" >&2; exit 1; }

host="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo '?')"
rule="$(printf '%72s' '' | tr ' ' -)"   # all-dashes => vps_notify renders it brand-orange
body="$(mktemp)"
{
    printf '%s\n' "$rule"
    printf '  Offsite backups configured + VERIFIED on %s\n' "$host"
    printf '%s\n\n' "$rule"
    printf '  %-11s %s\n\n' 'Verify'     'PASSED — small write + restore round-trip'
    printf '  %-11s %s\n\n' 'Protection' 'AES-256 · zstd · deduplicated · immutable offsite'
    printf '  %-11s %s\n\n' 'Repository' 'sftp:kiss-headless:/data/restic-repo'
    printf '  %-11s %s\n'   'Files'      '/home /etc /root /var/spool/cron /usr/local/lsws/conf'
    printf '  %-11s %s\n\n' ''           '(site data, configs, crontabs, certificates)'
    printf '  %-11s %s\n\n' 'Databases'  'local hourly chain + daily offsite dump'
    printf '  %-11s %s\n\n' 'Schedule'   'a full backup every HOUR (incremental — tiny after #1)'
    printf '  %-11s %s\n\n' 'Retention'  '24h rolling + 14 daily + 8 weekly + 12 monthly (GFS)'
    printf '  %-11s %s\n'   'First full' 'left to the schedule'
    printf '%s\n' "$rule"
    printf '  PASSPHRASE (break-glass):  /etc/restic/backup.pass\n'
    printf '  The ONLY key that decrypts the offsite backups — escrow it in your\n'
    printf '  password manager. If the box is lost, the on-box copy goes with it.\n'
    printf '%s\n\n' "$rule"
    printf '  See coverage + live size/dedup stats any time (real after backup #1):\n'
    printf '  /usr/local/bin/vps-tooling/backup_setup_v1.sh status\n'
} > "$body"

"$NOTIFY" --event backup-configured \
    --subject "Backups configured + verified on $(hostname -s 2>/dev/null || echo vps)" \
    --body-file "$body"
rc=$?
rm -f "$body"
exit "$rc"
