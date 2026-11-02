# console/ — Layer 1 TUI

Generic menu launcher: builds its menu from `console.d/*.menu` drop-ins and runs the mapped commands.
NOT backup-specific — backups are just the drop-ins shipped here.

- `console.sh` — the launcher.
- `console.d/` — backup menu descriptors (30-backups, 35-backup-stats, 40-backup-restore).

See `docs/architecture.md` §3.
