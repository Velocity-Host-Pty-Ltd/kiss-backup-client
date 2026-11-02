# directadmin — Layer-2 adapter

A **unit is one DirectAdmin account** (admin, reseller or user). Backups stay whole-box; this
adapter lets the engine restore **one account** from any hourly snapshot.

| Contract verb | What it does on DA |
|---|---|
| `detect` | `/usr/local/directadmin/directadmin` + `data/users/` present |
| `list-units` | every `data/users/<user>/user.conf` → `user`, `user (main domain)`, `usertype` |
| `paths-for-unit` | `/home/<user>` · `/usr/local/directadmin/data/users/<user>` · per domain `/etc/virtual/<domain>` (mail accounts) and `/var/named/<domain>.db` (DNS) — existing ones only |
| `dbs-for-unit` | databases named `<user>_*` (DA's prefix rule) |
| `restore-unit` | after the engine has restored the files in place (restic): hand files to a re-created account's new uid/gid if they differ; import each `<user>_*` dump (mirror drops + recreates the DB first, keeping grants); queues a DA `httpd` rewrite if the account config came back and reloads DNS if a zone did |
| `preflight` | DA tree, MariaDB reachable as root |
| `owner-for-unit` | the account's `uid:gid` |

## Using it

From the console: **kiss-console → Backups → Restore an account** walks through account →
backup → what (files + databases / files / databases / one folder) → merge or mirror → preview →
confirm. The same from the CLI:

```
kiss-backup list-units
kiss-backup restore-unit john                       # prints the plan, changes nothing
kiss-backup restore-unit john --dry-run             # shows exactly what would change
kiss-backup restore-unit john --yes                 # files + databases from the latest snapshots
kiss-backup restore-unit john --only /home/john/domains/john.com/public_html --files-only --yes
kiss-backup restore-unit john --dbs-only --db-snapshot 6d574c7a --yes
kiss-backup restore-unit john --mirror --yes        # exactly as it was (deletes newer extras)
```

Every real restore first takes a **safety snapshot** of the account's current state (tags
`pre-restore`, `unit-<user>`); to undo, restore that snapshot with `--snapshot <id>`.

## Limits (v1)
- Restores into an **existing** account. Re-creating a deleted DA account (with its DB users,
  package and IPs) is DirectAdmin's own job — restore the account in DA first, then use this to
  bring its data back.
- Database **users/grants** live in MariaDB's `mysql` schema, not the per-DB dumps; they're kept
  as they are.
- DNS zones need `/var/named` in `BACKUP_PATHS` (the wizard and installer add it on DA boxes).
