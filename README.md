# KISS Backup Client

**Encrypted, deduplicated offsite backups for Linux servers — with per-account restore for
hosting control panels.** Built on [restic](https://restic.net). Backs up to the KISS
storage service by default, or to any restic SFTP repository you run yourself.

- **Whole-server backups, every hour** — sites, mail, DNS, configs, crontabs and databases.
  restic only sends what changed, so after the first run each backup is small.
- **Encrypted before it leaves the server** (AES-256). The storage end never sees your data.
- **Restore one account, not the whole server** — pick an account and a point in time; files,
  mail, DNS and databases go back in place. A dry-run preview shows exactly what will change.
- **Browse a backup and fetch single files** — opens the backup read-only in Midnight Commander
  (`mc`), backup on the left, live server on the right. Nothing is copied to local disk.
- **Proves its backups work** — a weekly restore drill and integrity check, plus a test round-trip
  when you set it up.
- **Console + CLI** — a text-menu console (`kiss-console`) for day-to-day use, and a scriptable
  CLI (`kiss-backup`).

Control panels: **DirectAdmin** today (tested on CloudLinux 8.10 + DirectAdmin 1.713).
cPanel and Plesk are planned. Without a panel adapter you still get full-server backups and
file-level restores.

---

## Contents

- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Set up backups (the wizard)](#set-up-backups-the-wizard)
- [What is backed up, and when](#what-is-backed-up-and-when)
- [The console](#the-console)
- [Restoring an account](#restoring-an-account)
- [Browsing a backup / fetching single files](#browsing-a-backup--fetching-single-files)
- [CLI reference](#cli-reference)
- [Files and locations](#files-and-locations)
- [Your repository passphrase](#your-repository-passphrase)
- [Control-panel adapters](#control-panel-adapters)
- [Testing — what has been proven, and how](#testing--what-has-been-proven-and-how)
- [Troubleshooting](#troubleshooting)
- [Upgrade and uninstall](#upgrade-and-uninstall)
- [Known limits](#known-limits)
- [Support, issues, licence](#support-issues-licence)

---

## How it works

Three layers, so one engine can serve any control panel:

```
 ┌──────────────────────────────────────────────────────────────────────┐
 │ Layer 3  app adapters (planned)    e.g. a mail server, one app's data │
 ├──────────────────────────────────────────────────────────────────────┤
 │ Layer 2  panel adapters            directadmin · velocity · (cPanel,  │
 │          "what is an account,       Plesk planned)                    │
 │           which paths + DBs are     adapters/<name>/adapter           │
 │           its, how to put it back"                                    │
 ├──────────────────────────────────────────────────────────────────────┤
 │ Layer 1  engine (knows no panel)   restic backups, DB dumps,          │
 │                                    retention, checks, drills, restore │
 │                                    engine/restic_backup.sh            │
 └──────────────────────────────────────────────────────────────────────┘
              │  SFTP, encrypted client-side
              ▼
        restic repository  (KISS storage, or your own SFTP server)
```

- **Backups are whole-server**, taken on a timer by systemd. Per-account restores work by
  picking that account's paths and databases out of the whole-server backup — the adapter
  says which paths and databases belong to an account.
- **The adapter contract** is a small command-line interface (`info`, `list-units`,
  `paths-for-unit`, `dbs-for-unit`, `restore-unit`, …) so new panels can be added without
  touching the engine. It is specified in [`docs/architecture.md`](docs/architecture.md) §1.
- **Databases** are dumped per database (`mysqldump`) once a day into the same repository, and
  optionally kept as an hourly on-server `mariabackup` chain for fast "roll back a few hours".

## Requirements

| | |
|---|---|
| OS | RHEL family (CloudLinux, AlmaLinux, Rocky) 8 — **tested on CloudLinux 8.10**. The installer also supports `apt` (Debian/Ubuntu); that path is not yet tested. |
| Access | root |
| Storage | a restic SFTP repository: a KISS storage subscription, or your own SFTP server |
| Databases (optional) | MariaDB/MySQL reachable as root over the unix socket |
| Tools | installed for you if missing: `curl`, `bzip2`, `whiptail` (newt), `flock`, `mc`, FUSE. restic itself is downloaded at a pinned version and **checked against its published SHA-256** — an unverified binary is refused. |

## Install

```bash
git clone https://github.com/Velocity-Host-Pty-Ltd/kiss-backup-client.git
cd kiss-backup-client
sudo packaging/install.sh
```

Or from a release tarball (each [release](https://github.com/Velocity-Host-Pty-Ltd/kiss-backup-client/releases)
has `kiss-backup-client-<version>.tar.gz` and its `.sha256`):

```bash
sha256sum -c kiss-backup-client-0.1.0.tar.gz.sha256
tar xzf kiss-backup-client-0.1.0.tar.gz && cd kiss-backup-client-0.1.0
sudo packaging/install.sh
```

The installer copies the code to `/usr/local/lib/kiss-backup/`, adds three commands to
`/usr/local/sbin` (`kiss-backup`, `kiss-backup-setup`, `kiss-console`), and installs the systemd
units. **It does not start any backups** — that happens in the wizard, after the connection
and a test round-trip have been verified. Re-running it upgrades in place and never overwrites
your configuration.

## Set up backups (the wizard)

```bash
sudo kiss-backup-setup
```

The wizard walks you through, in order:

1. **SSH key** — creates the server's SFTP key if there isn't one, and shows the public key to
   authorise on the storage side.
2. **Connection** — storage host, port and user; trusts the server's host key; tests the SFTP
   connection (KISS is SFTP-only, so it tests SFTP, not a shell).
3. **Repository path** on the storage side.
4. **What to back up** — files (always), databases (optional). On a DirectAdmin server it adds
   DirectAdmin's account data, configuration and DNS zones automatically.
5. **Notification email** — where alerts and the confirmation go (optional).
6. **New repository, or reconnect to an existing one** (e.g. a rebuilt server — you type the
   existing passphrase).
7. **Your passphrase** — for a new repository it is generated and shown **once**. See
   [Your repository passphrase](#your-repository-passphrase).
8. **Verify** — a few-KB backup + restore round-trip, so you know the repository works
   before anything is scheduled.
9. **Schedule** — enables the timers. You can start the first full backup now (in the
   background) or let the next hourly run do it.

Check it any time with `kiss-backup-setup status`.

## What is backed up, and when

**Paths** (default; absent ones are skipped): `/home /etc /root /var/spool/cron
/usr/local/lsws/conf`, plus on DirectAdmin `/usr/local/directadmin/data`,
`/usr/local/directadmin/conf`, CustomBuild's `options.conf` and `/var/named`. The live database
files (`/var/lib/mysql`) are excluded — databases are backed up as dumps instead. Add your own
exclude patterns to `/etc/kiss-backup/backup-excludes.conf` (dangerously broad patterns such as
`/` or `/home` are refused, so a typo can't silently exclude everything).

| Timer | When (default) | What |
|---|---|---|
| `kiss-backup.timer` | hourly (+ up to 30 min jitter) | file backup |
| `kiss-backup-db-dump.timer` | daily 01:40 | one `mysqldump` per database → repository |
| `kiss-backup-db-full.timer` / `-db-diff.timer` | nightly 01:00 / hourly :15 | optional on-server `mariabackup` chain (local only, ~48 h) |
| `kiss-backup-check.timer` | Sundays 03:30 | repository integrity check |
| `kiss-backup-prune.timer` | Sundays 04:30 | apply retention, then reclaim space |
| `kiss-backup-drill.timer` | Sundays 05:30 | restore drill: restores a file and imports a database to prove backups really restore |

**Retention:** the last 24 hourly backups, then 14 daily, 8 weekly and 12 monthly.

Backups run at low CPU and I/O priority (`nice 19`, idle I/O class, 2 cores) so they can't
starve the sites on the server.

## The console

```bash
sudo kiss-console
```

A text-menu console. The header shows the host, OS, web server, backup schedule and the
repository's size and deduplication. Under **Backups**:

| Screen | What it does |
|---|---|
| **What's backed up + schedule** | the paths, timers and retention in force |
| **Refresh repo stats** | recomputes the size/dedup figures in the background |
| **Restore an account** | guided per-account restore — see below |
| **Browse a backup** | open a backup read-only in `mc` to fetch single files — see below |

If a restore failed for good, the console says so as soon as it opens.

## Restoring an account

From the console (**Backups → Restore an account**) or the CLI
(`kiss-backup restore-unit <account> …`). The console asks:

1. **Which account** (from the panel adapter).
2. **Which backup** — the most recent, or any earlier one, including the *safety snapshots*
   taken before earlier restores.
3. **What** — files and databases, files only, databases only, or one folder/file.
4. **How**
   - **Merge** — put back what the backup has; keep anything newer (DirectAdmin default).
   - **Exactly as it was** (mirror) — also **delete** files and tables created since the
     backup. Use this after a hack: a planted file can't survive it.
5. **Preview** — a dry run listing every file that would be restored, updated or deleted, and
   any owner changes. Nothing has changed yet.
6. **Safety snapshot?** (default **yes**) — backs up the account's *current* state to the
   repository first, so the restore can be undone, and anything newer than the backup
   (today's mail, new orders) can still be fetched from it afterwards. It is uploaded and
   deduplicated, so it takes no local disk. Skipping it is your call; the restore then cannot
   be undone.
7. **Confirm** — the restore runs as its own background job (`kiss-restore-<account>`), so a
   dropped SSH session can't stop it halfway. The screen follows its progress; the full log
   is kept at `/var/lib/kiss-backups/restore-status/<account>.log`.

### What happens underneath

- **Files go straight back into place** with restic, which compares each file with the backup
  and writes only the ones that differ. There is no temporary copy of the account, so a
  restore needs no extra disk space.
- **Databases** are downloaded as dumps, checked to be complete (a truncated dump is never
  imported), then imported. In mirror mode the database is dropped and re-created first.
- **Guards before anything is written:**
  - the account must exist on the server (`/etc/passwd`, `/etc/group`);
  - the restore may only touch the account's own paths — the same restore is first run as a
    dry run, and if it would touch anything outside the account it is refused;
  - a path that is a whole backup root (e.g. `/home`) is never restored as "one account".
- **Owners stay right even if the account's user ID changed** — e.g. the account was deleted
  and re-created, or you are restoring onto a rebuilt server. The backup's `/etc/passwd` and
  `/etc/group` are compared with the live ones **by name**, and only files on a moved ID are
  re-owned. Shared groups (DirectAdmin's `access`, `mail`) are left alone. On DirectAdmin the
  user IDs stored *inside* the mail login files are updated too.
- **Panel follow-up** (DirectAdmin): queues an httpd config rewrite and reloads DNS when the
  account's configuration or zones came back.
- **Network trouble** — each step is retried 3 times (30 s, then 60 s apart). If it still
  fails, an alert email is sent and the console shows a warning. **Running the restore again
  resumes it**: files that were already restored are skipped.

## Browsing a backup / fetching single files

**Backups → Browse a backup**, pick an account and a backup. The repository is mounted
read-only (`restic mount`, in memory under `/run`) and `mc` opens with the **backup on the left**
and the **live account on the right**. Copy what you need with **F5** (keep "Preserve attributes"
ticked so owner and timestamps come back too), quit with **F10** — the mount is removed.

Only the files you copy are downloaded. While the backup is open, scheduled retention waits
(backups still run).

## CLI reference

Run `kiss-backup` with no arguments for the full list.

```text
kiss-backup backup                       back up now
kiss-backup db-dump                      dump the databases into the repository now
kiss-backup snapshots --compact          list backups
kiss-backup check [--read-data-subset=5%]   verify the repository
kiss-backup restore-drill                prove a file + a database restore work

kiss-backup list-units                   accounts the panel adapter knows
kiss-backup restore-unit <account>       show the restore plan (changes nothing)
    --dry-run                            preview exactly what would change
    --yes                                do it
    --snapshot <id>  --db-snapshot <id>  pick the backup (default: latest)
    --files-only | --dbs-only            what to restore
    --only <path>                        one folder or file inside the account
    --merge | --mirror                   keep newer extras | exactly as it was
    --no-safety-snapshot                 skip the pre-restore snapshot (cannot be undone)
kiss-backup mount <dir>                  mount the repository read-only (FUSE)

kiss-backup-setup                        the setup wizard
kiss-backup-setup status                 what's backed up, how often, kept how long
```

Example — preview, then restore one account exactly as it was in a given backup:

```bash
kiss-backup restore-unit alice --snapshot 4cc95161 --mirror --dry-run
kiss-backup restore-unit alice --snapshot 4cc95161 --mirror --yes
```

## Files and locations

| Path | What |
|---|---|
| `/etc/kiss-backup/backup.env` | main configuration (repository, paths, retention, adapter) — written by the wizard |
| `/etc/kiss-backup/backup-excludes.conf` | your exclude patterns |
| `/etc/kiss-backup/mail.env` | notification email |
| `/etc/kiss-backup/kiss-target.conf` | default storage host/port for the wizard (optional) |
| `/etc/kiss-backup/console.d/` | console menu entries (drop-in `*.menu` files) |
| `/etc/kiss-backup/adapters.d/<name>/adapter` | your own adapters |
| `/etc/restic/backup.pass` | **the repository passphrase** (root-only) |
| `/usr/local/lib/kiss-backup/` | installed code |
| `/var/lib/kiss-backups/` | database dumps, restore work area (DB dumps only), restore logs + status |
| `/var/cache/restic` | restic's cache (never backed up) |

Restore settings in `backup.env`: `BACKUP_RESTORE_ATTEMPTS` (default 3),
`BACKUP_DB_PAIR_WINDOW` (default 900 s — a database dump taken within this long after a file
backup is treated as its pair).

## Your repository passphrase

Everything in the repository is encrypted with the passphrase in `/etc/restic/backup.pass`.
**Without it your backups cannot be read — by you, by us, by anyone.** If the server is lost and
you don't have the passphrase, the backups are lost with it.

When the wizard shows it, store it somewhere **off this server** (a password manager, a sealed
envelope). To restore onto a new server, run the wizard there, choose *reconnect to an existing
repository*, and type it in.

## Control-panel adapters

| Adapter | Account = | Restores | Default mode |
|---|---|---|---|
| `directadmin` | a DirectAdmin user | home, DirectAdmin user data, mail config (`/etc/virtual/<domain>`), DNS zones, `<user>_*` databases | merge |
| `velocity` | a tenant record of the Velocity headless platform | the site's docroot + `<prefix>_*` databases | mirror |

The active adapter is `ADAPTER=<name>` in `backup.env` (the wizard sets it when it detects a
panel). Writing an adapter for another panel or app is a matter of implementing the contract
in [`docs/architecture.md`](docs/architecture.md) §1 — see [`adapters/README.md`](adapters/README.md).

## Testing — what has been proven, and how

Every restore behaviour above has a test. Unit tests run anywhere (no root, no panel); the
DirectAdmin tests run end to end on a real CloudLinux 8.10 + DirectAdmin 1.713 server and print
PASS/FAIL. The full list — what each test does, why, and its last result — is in
[`tests/README.md`](tests/README.md).

Highlights from the DirectAdmin runs:

- a planted file is removed, a changed file and database are rolled back (mirror restore);
- restic killed mid-restore → the restore retries by itself and finishes, checksum intact;
- the account deleted and re-created with **new user/group IDs**, the old IDs given to another
  user → every restored file and the mail login file end up on the new IDs, nothing on the old;
- a single file fetched back with *Browse a backup*, owner and timestamp preserved.

## Troubleshooting

| Symptom | Look at |
|---|---|
| Backups not running | `kiss-backup-setup status`, `systemctl list-timers 'kiss-backup*'`, `journalctl -u kiss-backup` |
| "deferred — another backup/restore holds the lock" | normal: backup and DB dump share a lock; the next run catches up |
| Restore failed | `/var/lib/kiss-backups/restore-status/<account>.log`; fix the cause (usually the storage connection: `kiss-backup snapshots`), then run the restore again — it resumes |
| "has no system user in /etc/passwd" | the account doesn't exist on this server; create it in the control panel first, then restore |
| Retention not applied | a *Browse a backup* window left open holds a lock; close it |

## Upgrade and uninstall

```bash
cd kiss-backup-client && git pull && sudo packaging/install.sh     # upgrade (config kept)
sudo packaging/install.sh --uninstall                              # remove code + units
```

Uninstall keeps `/etc/kiss-backup`, the passphrase and, of course, the backups in the repository.

## Known limits

- **A restore needs the account to exist in the panel.** It puts files, mail, DNS and databases
  back into an existing account; it does not re-create the panel account itself (package, IP,
  the panel's own records). On a rebuilt server, create the accounts in the panel first.
  Re-creating accounts through the panel's API is planned.
- **Resume is per file.** An interrupted restore skips files that already finished; a single
  very large file that was half-written is downloaded again in full.
- **Debian/Ubuntu**: supported by the installer, not yet tested. CloudLinux 9 / EL9 is next.

## Support, issues, licence

- **Bugs and feature requests:** [GitHub Issues](https://github.com/Velocity-Host-Pty-Ltd/kiss-backup-client/issues). Please include your OS, panel
  version and the output of `kiss-backup-setup status`.
- **Commercial support** is available from Velocity Host (chargeable), and included with a
  KISS storage subscription.
- **Licence:** [GNU AGPL v3](LICENSE).
