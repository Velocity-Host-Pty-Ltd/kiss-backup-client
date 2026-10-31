# adapters/ — Layer 2 (control panels) + Layer 3 (apps)

One **subfolder per module** (`adapters/<name>/`), each with an executable `adapter` that implements
the contract in `docs/architecture.md` §1 (`info` / `detect` / `list-units` / `paths-for-unit` /
`dbs-for-unit` / `restore-unit` + optional verbs), plus optional `lib/` and `tests/`.

Built: **`directadmin/`** (first real Layer-2 adapter — see its README). Planned: `generic-dir/`
(reference + conformance fixture), `velocity/` (old tenant-ledger logic behind the contract),
`smartermail/` (Layer-3, granular email restore).

The installer copies each `adapters/<name>/adapter` to `/usr/local/lib/kiss-backup/adapters/<name>/`;
site adapters can be dropped into `/etc/kiss-backup/adapters.d/<name>/adapter`. The active one is
`ADAPTER=<name>` in `backup.env`.
