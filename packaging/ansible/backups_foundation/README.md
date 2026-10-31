# backups_foundation

Server-global backup layer: deploys the restic backup engine
(`vps-tooling/restic_backup_v1.sh`, §1.2 single source of truth) and the systemd
timers that drive it. One repo per VPS, client-side AES-256, native SFTP backend
to KISS. Engine/front-end split per `platform-architecture.md` §3 — this role is
the declarative front end; the engine owns the procedural steps.

**Files + DB.** This role backs up filesystem paths (`/home`, `/etc`, …) and,
when `backups_db_enabled`, the databases via the §3.1 method: a `mariabackup`
physical chain (nightly **full** + hourly **differential** — each diff vs the full,
so any point restores from full + one diff and a bad diff can't break the chain)
plus a daily self-contained per-database `mysqldump` (the unchained fallback), all
into the same repo. Status + proofs: `docs/backups_handover.md` §12 and
`docs/backups_prototype_runbook.md`.

## Opt-in

Disabled by default (`backups_enabled: false`). A fresh clone must not back up
before a repo target and reachable SFTP credentials exist (an onboarding /
control-plane concern), so the role is a complete no-op until enabled in
`host.yml`. When enabled, `backups_repo` is required.

```yaml
backups_enabled: true
backups_repo: "sftp:kiss-headless:/data/restic-repo"
backups_restic_sha256: "<sha256 of restic_0.19.0_linux_amd64>"   # recommended
# optional overrides: backups_paths, retention, schedules, caps — see defaults/main.yml
```

## What it installs

| Unit | Schedule (default) | Action |
|------|--------------------|--------|
| `restic-backup.timer`  | nightly 02:00 +jitter | `init` (idempotent) then capped file `backup` |
| `restic-check.timer`   | weekly Sun 03:30      | `check` — **detection**; failure → `OnFailure` alert → notification framework |
| `restic-prune.timer`   | weekly Sun 04:30      | `forget` (GFS retention) then `prune` (disk reclaim; locks the repo) |
| `restic-db-full.timer`  | nightly 01:00 +jitter | `db-backup full` — mariabackup full (new generation) — **local** |
| `restic-db-diff.timer`  | hourly :15 +jitter    | `db-backup diff` — differential (changed pages since the full) — **local** |
| `restic-db-dump.timer`  | daily 01:40 +jitter   | `db-dump` — per-database `mysqldump` → **restic** (offsite) |
| `restic-drill.timer`    | weekly Sun 05:30 +jitter | `restore-drill` — prove backups **restore** (file + rotating DB import); **detection**, failure → notifier |

The DB timers install only when `backups_db_enabled: true` (a second gate inside
`backups_enabled`). DB tools auth via `unix_socket` as root. **Two-tier by design:**

- The **physical chain** (full + hourly differential) is **LOCAL only** — the
  short-term, hour-granular point-in-time layer for "roll back N hours" on a *live*
  box. It is **not** shipped to restic (box-loss DB recovery is covered offsite by
  the nightly dump + the hypervisor/PBS snapshot, so duplicating the hourly chain
  offsite is overlap for no gain). Two generations are kept (~48h): a new full is
  built into the inactive slot and only becomes current on success, so a failed
  full never destroys the working chain. Staging `/var/lib/vps-backups/mariabackup`
  ≈ 2×(datadir + diffs) — **monitor that filesystem.**
- The **per-DB logical dumps** are the **offsite, long-retained** store (restic,
  GFS) and the per-tenant single-DB recovery path.

**Restore is an operator runbook step** (restore-aside to scratch, then a scoped
per-DB import), never an engine action — see `docs/backups_prototype_runbook.md` §5
and `tests/verify-granular-db-restore.sh`.

### Restore-drill (verify backups restore)

`restore-drill` proves the backups actually *restore* — "a backup you haven't
restored isn't one." It is **detection, not recovery**: non-destructive (restores
to scratch + a throwaway `_restoredrill` temp DB, dropped), so it's safe to
automate, and a failure routes to the notification framework. On by default when
`backups_enabled` (opt-out via `backups_drill_enabled`); the heavy DB import has its
own opt-out (`backups_drill_db_import`) for load-sensitive boxes.

- **File:** restores a small sentinel (`backups_drill_file`, default `/etc/hostname`)
  from the latest file snapshot end-to-end — near-zero load.
- **DB:** restores per-DB dumps from restic and import-verifies them into the temp DB
  on a **rotating cursor** up to a per-run **size budget** (`backups_drill_db_budget_bytes`,
  ~1.5 GiB) — several small DBs or one big one, never the whole fleet at once.
- **Goal = process health** (continuous proof the restore pipeline works); full
  per-DB coverage accrues slowly as a bonus. Per-DB-unique corruption is backstopped
  by backup-time alerts + `restic check --read-data-subset`.
- The timer **pins it to 1 CPU + idle IO**, off-hours, so it can't starve sites.

Resource caps (`GOMAXPROCS`/`nice`/`ionice`) are applied by the engine from the
rendered `/etc/vps-tooling/backup.env`, so a backup can never starve tenant sites.

## KISS SSH key (a foundational prerequisite — generated elsewhere)

The per-VPS SFTP **access** keypair to KISS is **not** generated by this role — it's
a foundational prerequisite created early by **`ssh_access_foundation`**
(`ssh_access_backup_key`, default `/etc/restic/kiss_id_rsa`), *before* the
notification welcome advertises its public half and before `backup-setup`. That
ordering is deliberate: the pubkey must exist to be authorized on KISS ahead of
backups being turned on. It's distinct from the restic **passphrase** (decryption)
below. The pubkey path + tool locations are advertised on the MOTD board (the
`20-backups.txt` drop-in `ssh_access_foundation` writes) and in the onboarding
welcome email; the operator authorizes it on KISS, then runs `backup-setup`.

## Passphrase

Generated on first `init` into `backups_passfile` (`/etc/restic/backup.pass`,
mode 600) if absent, via `openssl rand -base64 24`. **It is the only key to the
repo — loss = unrecoverable backups.** Escrow it (manager / control plane). The
fleet-wide escrow *policy* is still pending — `docs/backups_handover.md` §9.

## Recovery

Recovery is **ops-decided** (handover §13): this role automates *detection* only.
Routine file/DB restore is self-service (`restic restore` over SFTP, or Backrest);
whole-repo disaster is an ops-side `zfs rollback` on KISS. The proven recovery
procedures (incl. recovering the repo itself from a ZFS snapshot) are in
`docs/backups_prototype_runbook.md` §5.

## Dependencies

Soft: check-failure escalation uses `service_watchdog`'s `vps-service-alert@.service`
template (a core foundation, present fleet-wide). Set `backups_alert_on_check_failure: false`
to leave the check timer un-escalated.
