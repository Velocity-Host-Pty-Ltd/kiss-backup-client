# engine/ — Layer 1 (generic, panel-agnostic)

The control-panel-agnostic backup engine: scheduled restic backup (whole-box: /home, all DBs,
configs), MariaDB-aware dumps, retention, drills, restore, and the runtime OS/package-family
auto-detection (dnf vs apt). Knows the adapter contract; knows no control panel.

- `restic_backup.sh` — the scheduled engine.
- `backup_setup.sh` — opt-in setup wizard (writes the config; being decoupled from KISS defaults).
- `notify.sh` — notifications (mail/webhook; optional, non-fatal).

See `docs/architecture.md` §3 (layers) and §4 (layout/config). Decoupling status: `docs/EXTRACTION.md`.
