# adapters/ — Layer 2 (control panels) + Layer 3 (apps)

One **subfolder per module** (`adapters/<name>/`), each with an executable `adapter` that implements
the contract in `docs/architecture.md` §1 (`info` / `detect` / `list-units` / `paths-for-unit` /
`dbs-for-unit` / `restore-unit` + optional verbs), plus optional `lib/` and `tests/`.

Planned: `generic-dir/` (reference), `directadmin/` (first real), `velocity/` (old tenant-ledger
logic behind the contract), `smartermail/` (Layer-3, granular email restore). None built yet.
