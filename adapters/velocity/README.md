# velocity — Layer-2 adapter (vps-baseline / headless)

Lets **vps-baseline** adopt KISS-Backup-Client and keep its per-account restore. The tenant ledger
coupling from vps-baseline lives here, behind the adapter contract (`docs/architecture.md` §1).

| Contract verb | What it does |
|---|---|
| `detect` | any `/var/log/tenant-management/*_info.json` present |
| `list-units` | each `<account>_info.json` → `account`, `account (domain)`, `package` |
| `paths-for-unit` | the record's **`docroot`** (default `/home/<account>/public_html`), only if it exists — the same scope as vps-baseline's own `backup_ondemand` |
| `dbs-for-unit` | databases `<db_prefix>_*` (`db_prefix` == account by design) |
| `restore-unit` | shared `adapters/lib/restore_common.sh`: sync the docroot back, import complete dumps only |
| `preflight` · `owner-for-unit` | ledger present, `rsync`, MariaDB as root · the account's `uid:gid` |

**Default restore mode is `mirror`** (`"default_restore_mode":"mirror"` in `info`), matching
headless' exact-match restore: files added since the snapshot — e.g. an injected backdoor — are
removed, and databases are dropped + re-imported. `--merge` (or the console's Merge row) keeps
newer extras instead.

Records are read with the same `"key": "value"` line reader vps-baseline uses — no `jq`/python.
The record is treated as a cache: the docroot is verified on disk. Account names must match
`^[a-z][a-z0-9]{0,15}$` (the platform contract).

Usage is the same as any adapter: `ADAPTER=velocity` in `backup.env` (the wizard / installer set
it on a box with a tenant ledger), then `kiss-backup list-units`, `kiss-backup restore-unit <acct>`
or **kiss-console → Backups → Restore an account**.
