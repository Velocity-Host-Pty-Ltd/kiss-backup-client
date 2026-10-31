# KISS-Backup-Client — Architecture

**Status:** Draft. First architecture spec for the new repo.
**Date:** 2026-10-31
**Audience:** engineers working in `KISS-Backup-Client`.
**Companion:** [`HANDOVER.md`](./HANDOVER.md) carries the business context and the extraction map
from `vps-baseline`. This document is the technical design; where the two disagree, this one wins
for *how the code is shaped*, HANDOVER wins for *why*.

This document leads with the **adapter contract**, because — per the Charter (§3) — getting that
seam right is the single most important thing for the layered model to hold together. Everything
else (the layer model, the engine, the reference adapters) is arranged around it.

---

## 1. The adapter contract (THE priority spec)

### 1.1 What an adapter is

An **adapter** is the thing that answers, for one environment:

> *What backup units exist here, what files and databases belong to each unit, and how do I put a
> single unit back?*

A **unit** is whatever the environment calls an independently-restorable tenant:

| Environment              | A "unit" is…                              |
|--------------------------|-------------------------------------------|
| DirectAdmin              | a DA user account                         |
| cPanel / Plesk (later)   | a panel account                           |
| Velocity vps-baseline    | a tenant in the tenant-management ledger  |
| SmarterMail (Layer 3)    | a mailbox (or a single email, see §1.7)   |
| generic directories      | a named path group from a config file     |

The Layer-1 engine never hardcodes any of the above. It only knows how to call **the contract
below**. Today that knowledge is hardcoded in `vps-baseline` against the tenant ledger
(`/var/log/tenant-management/<acct>_info.json`); this contract is the explicit seam that replaces
the hardcoding.

### 1.2 Shape of the contract: a verb CLI

An adapter is a single executable (a shell script is expected, but any executable that honours the
protocol qualifies). The engine invokes it as:

```
<adapter> <verb> [args…]
```

Chosen over a sourced-function library so that:
- adapters are language-agnostic (a Layer-3 adapter could be Python),
- the engine's blast radius is a process boundary, not a shared shell namespace,
- an adapter is independently testable: `directadmin list-units` is runnable by hand.

The engine locates adapters by name and resolves a path (see §1.6). The engine passes **no global
state via the environment** beyond a documented allow-list (§1.5).

### 1.3 Required verbs

Every adapter MUST implement these. Unless stated otherwise: success is exit `0`, records go to
**stdout**, diagnostics go to **stderr**, and the engine treats any nonzero exit as "this verb
failed — abort the operation for this unit".

| Verb                         | Args                      | Stdout                                                        |
|------------------------------|---------------------------|--------------------------------------------------------------|
| `info`                       | —                         | one JSON object: adapter metadata + capabilities (§1.4)      |
| `detect`                     | —                         | nothing; **exit 0** = applicable on this host, `10` = not    |
| `list-units`                 | —                         | one **unit record** per line (TSV, §1.4)                     |
| `paths-for-unit`             | `<unit-id>`               | one absolute path per line (NUL-safe variant: `--print0`)    |
| `dbs-for-unit`               | `<unit-id>`               | one **db record** per line (TSV, §1.4)                       |
| `restore-unit`               | `<unit-id> <workdir>`     | nothing on stdout; restores from `<workdir>` into place      |

Optional verbs (engine feature-detects them via `info` capabilities, never by probing):

| Verb              | Args                     | Purpose                                                        |
|-------------------|--------------------------|----------------------------------------------------------------|
| `preflight`       | —                        | check tools/permissions the adapter needs; nonzero = not ready |
| `owner-for-unit`  | `<unit-id>`              | print `uid:gid` to restore files as (defaults to current)      |
| `quiesce`         | `<unit-id>`              | pause/lock a unit before snapshot (e.g. mail delivery)         |
| `unquiesce`       | `<unit-id>`              | release after snapshot; engine guarantees it runs if quiesce did |

> Verb names are **kebab-case on the CLI**. The Charter wrote them as `list_units`,
> `paths_for_unit`, `dbs_for_unit`, `restore_unit` (snake_case) — same four operations; the
> rename is only the surface spelling. An adapter MAY also accept the snake_case aliases.

### 1.4 Record formats

Structured output is **TSV** (tab-separated, one record per line, `\n`-terminated), not JSON, for
the record-streaming verbs. Rationale: Layer 1 is bash and consumes these with
`while IFS=$'\t' read -r …`; TSV keeps Layer 1 free of a hard `jq` dependency. `info` is the one
exception — it is a single JSON object, because it is read once and benefits from being
self-describing/extensible. (If `jq` turns out to be universally present on targets, revisit and
move everything to JSON Lines — see §6.)

**Unit record** (`list-units`), columns in order:

```
unit-id <TAB> display-name <TAB> kind
```

- `unit-id` — stable, opaque to the engine, safe for use as a restic path component (no tabs/newlines).
- `display-name` — human label for the console.
- `kind` — adapter-defined hint (`account`, `mailbox`, `dirgroup`, …); free-form, for display/filter.

**DB record** (`dbs-for-unit`), columns in order:

```
engine <TAB> name <TAB> owner-hint
```

- `engine` — `mysql` | `mariadb` | `pgsql` (Layer 1 currently implements MariaDB/MySQL; others
  declared-but-unsupported are skipped with a warning).
- `name` — database name.
- `owner-hint` — optional DB user the engine may use for a per-unit dump; blank = use engine default.

Fields never contain a literal tab or newline. Paths that might (exotic filenames) use the
`--print0` NUL-separated variant of `paths-for-unit`.

**`info` object** (minimum keys):

```json
{
  "adapter": "directadmin",
  "version": "1",
  "contract": "1",
  "capabilities": ["preflight", "owner-for-unit"],
  "unit_noun": "account"
}
```

`contract` is the contract-version this adapter speaks (this document is contract `1`). The engine
refuses an adapter whose `contract` major it does not implement. Optional keys: `has_databases`
(wizard hint, §2.3) and **`default_restore_mode`** (`merge` | `mirror`) — the mode the engine and
console use when the operator doesn't choose (DirectAdmin `merge`; velocity `mirror`, headless'
exact-match restore).

### 1.5 Environment passed to an adapter

The engine passes a small, documented allow-list and nothing else:

- `KBC_SNAPSHOT` — restic snapshot id (restore verbs only).
- `KBC_WORKDIR` — same value as the `restore-unit` `<workdir>` arg, for convenience.
- `KBC_LOG_LEVEL` — `quiet|normal|debug`.
- `KBC_DRY_RUN` — `1` when the engine wants a no-op rehearsal (adapters MUST honour it).
- `KBC_RESTORE_MODE` — `merge` (default: overwrite from the snapshot, keep newer extras) or
  `mirror` (make it exactly as it was: delete extras, drop + recreate databases).

Adapters MUST NOT depend on the engine's own config (`backup.env`), the tenant ledger, or any other
ambient file *unless that dependency is the adapter's whole point* (the Velocity adapter legitimately
reads the tenant ledger — that is where the hardcoding goes to live, behind the contract).

### 1.6 Discovery & registration

- Adapters live under `adapters/<name>/adapter` (executable), with reference adapters shipped in the
  repo and site adapters droppable into `/etc/kiss-backup/adapters.d/<name>`.
- The active adapter is chosen by config (`ADAPTER=directadmin` in the engine env), **not**
  auto-detected in production. `detect` exists for the console's "which adapter fits this box?"
  helper and for tests, so that selection stays explicit and reviewable.
- Exactly one Layer-2 adapter is active per backup run. Layer-3 app adapters (§1.7) are additive and
  addressed explicitly by the console/CLI, not selected as "the" adapter.

### 1.7 Layer-3 (app) adapters reuse the same contract

A Layer-3 adapter (e.g. SmarterMail) is the same contract at a finer grain: its `unit` is a mailbox,
and — the headline feature — it supports restoring *below* a unit. That is expressed as an optional
capability rather than a new verb family:

- `list-units` → mailboxes.
- `paths-for-unit <mailbox>` → that mailbox's store paths.
- `restore-unit <mailbox> <workdir>` → whole-mailbox restore.
- capability `item-restore` + verb `restore-item <unit-id> <item-selector> <workdir>` → drop a single
  email back into SmarterMail and trigger a mailbox reindex.

The proof the architecture is sound (Charter §3): SmarterMail is "just another adapter" — nothing in
Layer 1 changes to support it, only a new adapter directory and the `item-restore` capability.

### 1.8 Worked example

```
$ directadmin detect; echo $?
0
$ directadmin list-units
john    john (johndoe.com)      account
acme    acme (acme.example)     account
$ directadmin paths-for-unit john
/home/john
/etc/virtual/johndoe.com
$ directadmin dbs-for-unit john
mysql   john_wp     john
mysql   john_store  john
```

The engine turns that into: snapshot those paths, dump those DBs, tag the restic snapshot with
`unit=john`, and — on restore — hand `restore-unit john <workdir>` a tree staged from the snapshot.

---

## 2. How the engine uses the contract

### 2.1 Backup flow (per run)

1. Resolve the active adapter from config; run `info`, reject on contract-major mismatch.
2. If adapter declares `preflight`, run it; abort the run on failure.
3. `list-units` → the set of units in scope (console may filter).
4. **Whole-box baseline** (Phase 1, panel-agnostic): back up `/home`, all DBs, and configs
   regardless of unit decomposition — this is what ships first for the DirectAdmin client and needs
   no per-unit logic. Unit decomposition (steps 5–6) is additive metadata on top.
5. For each unit: `paths-for-unit` + `dbs-for-unit`; if `quiesce` is supported, quiesce → snapshot →
   `unquiesce` (guaranteed via trap).
6. restic backup with per-unit tags so a single unit is addressable at restore time.
7. retention / prune / check as today (`restic_backup_v1.sh` logic, carried over).

### 2.2 Restore flow (per unit) — implemented 2026-10-31

`restic_backup.sh restore-unit <unit> [--snapshot ID] [--db-snapshot ID] [--only PATH]
[--files-only|--dbs-only] [--mirror] [--dry-run] [--yes]` (CLI: `kiss-backup restore-unit …`).

1. **Plan.** `list-units` must contain the unit; `paths-for-unit` / `dbs-for-unit` say what
   belongs to it. `--only` narrows the files to one sub-path (must be inside the unit's paths);
   paths not under any `BACKUP_PATHS` root are reported and skipped. Snapshots: the file snapshot
   is the latest that holds the unit's root (or `--snapshot`); the DB snapshot is the newest
   `db-dump` at or before it, else the closest after it with a warning (or `--db-snapshot`).
   **Without `--yes` (or `--dry-run`) the engine prints the plan and changes nothing** — the
   console confirms, the CLI must opt in.
2. **Stage** into `$BACKUP_RESTORE_ROOT/<unit>.XXXXXX` (default `/var/lib/kiss-backups/restore`):
   - `<workdir>/files/<absolute path>` — the unit's paths as they were in the snapshot;
   - `<workdir>/paths` — the exact list of paths staged (whole areas, or the `--only` sub-path);
   - `<workdir>/dbs/<name>.sql` — one mysqldump per database.
3. **Safety snapshot** (not for `--dry-run`): the unit's *current* paths plus fresh dumps of the
   databases being restored are backed up with tags `pre-restore`, `unit-<unit>`. Undo = restore
   that snapshot (`--snapshot <id>`).
4. **`restore-unit <unit-id> <workdir>`** — the adapter puts each staged path (only those inside the
   unit's own areas, never through `..`) back in place and imports the dumps, honouring
   `KBC_DRY_RUN` / `KBC_RESTORE_MODE`. The workdir is removed on success and kept on failure.
5. The engine holds the backup/restore mutex throughout (waits up to 10 min).

Whole-box / bare restore remains available as an engine-level path independent of any adapter.

### 2.3 Feature toggles — not every target has databases

The whole-box engine inherited a MariaDB/MySQL assumption, but some targets have **no databases at
all** (e.g. a SmarterMail mail server), while others (DirectAdmin, cPanel) usually do. So the backup
function groups are **individually switchable**, not all-or-nothing:

- Engine config carries per-function toggles, e.g. `BACKUP_DBS=yes|no` (with room for more as app
  adapters land).
- An adapter's `info` (§1.4) may declare a `has_databases: true|false` hint so the **setup wizard**
  can pick a sensible default per target: SmarterMail → DB snapshots off; DirectAdmin / cPanel →
  prompt "enable DB snapshots?" defaulting on.
- The **setup wizard** surfaces these as explicit opt-in/opt-out prompts and the operator can always
  override the adapter's default. (Wizard UI is a later build step — captured here so the engine and
  the `info` schema leave room for it now.)

---

## 3. Layer model (recap, see HANDOVER §3)

- **Layer 1 — generic engine + console.** restic scheduling, MariaDB-aware dumps, retention,
  drills, restore, TUI. **Auto-detects the OS / package family at runtime** (`/etc/os-release` →
  dnf vs apt) and owns the **dnf+apt package-install abstraction** — the target OS is never a
  build-time or install-time assumption the operator has to supply. Knows the adapter contract;
  knows no panel. Extracted from the CLEAN files in HANDOVER §4.
- **Layer 2 — control-panel adapters.** One active per run. DirectAdmin first; cPanel/Plesk/Velocity
  later. This is where the old tenant-ledger coupling is quarantined.
- **Layer 3 — app adapters.** Same contract, finer grain, optional `item-restore`. SmarterMail
  granular email restore is the flagship.

Dependency direction is one-way and enforced by layout: Layer 1 must not `source` or `import`
anything under `adapters/`; it only *execs* the configured adapter through the contract.

---

## 4. Repo layout & conventions

### 4.1 Layout

```
engine/              # Layer 1: restic scheduler, db dumps, retention, restore, pkg-install abstraction
  restic_backup.sh   #   the scheduled backup engine
  backup_setup.sh    #   opt-in setup wizard (writes the config; being decoupled)
  notify.sh          #   notifications (mail/webhook; non-fatal)
console/             # Layer 1 TUI
  console.sh         #   generic menu launcher (reads console.d/*.menu, evals commands)
  console.d/         #   backup menu descriptors (30/35/40-backup*)
adapters/            # Layer 2 + 3 — ONE SUBFOLDER PER MODULE (see 4.3). Reference/first adapters:
  generic-dir/       #   reference adapter: named path groups from a config file (no panel)
  directadmin/       #   first real Layer-2 adapter
  velocity/          #   the old tenant-ledger logic, moved behind the contract (Layer 2)
  smartermail/       #   Layer-3 app adapter (item-restore)
brand/               # brand_header.sh + brand.conf (Velocity defaults) + reseller override (HANDOVER §5)
packaging/           # installer + release packaging
  ansible/           #   backups_foundation role (reference for the standalone installer)
tests/               # ported verify-* scripts + the contract conformance harness (§5)
docs/                # HANDOVER.md, architecture.md (this file), EXTRACTION.md (decoupling checklist)
```

### 4.2 Config convention (decided)

- **Config root = `/etc/kiss-backup/`** for a fresh standalone install — a clean break from the
  inherited `/etc/vps-tooling/`. Primary config file: `/etc/kiss-backup/backup.env`.
- **The config root is a single parameter**, read from `KBC_CONFIG_DIR` (default `/etc/kiss-backup`).
  A consumer may override it: e.g. `vps-baseline`, when it adopts the product, can point the engine
  at its existing `/etc/vps-tooling/backup.env` for a **zero-migration** adoption, or migrate on a
  maintenance window. Our choice of default never forces a change on a live fleet — the dependency
  is one-way and version-pinned (HANDOVER §2).
- **Namespacing to avoid collisions:** the product ships its own systemd unit names (`kiss-backup-*`)
  and its own `console.d` dir, so it can coexist with a legacy `vps-tooling` install during a
  transition.
- Env-var prefix for runtime/engine variables is **`KBC_`** (see §1.5).

### 4.3 Module = subfolder (decided)

Every Layer-2/3 module lives in its **own subfolder** under `adapters/`, never as a single loose
file. Code shared between adapters lives in `adapters/lib/` (e.g. `restore_common.sh`), sourced by
the adapters — never by Layer 1. A folder gives each module room for helper libs, its own tests, and a config template without
cluttering the parent tree, and it matches the discovery rule in §1.6 (`adapters/<name>/adapter`).

---

## 5. Contract conformance harness (planned)

A single test target runs any adapter through the contract and asserts the protocol, so a new
adapter is "done" when it passes:

- `info` is valid JSON with a known `contract` major.
- `detect` exits `0` or `10`, never crashes.
- `list-units` output is well-formed TSV with unique `unit-id`s.
- for a sample unit: `paths-for-unit` are absolute and exist; `dbs-for-unit` is well-formed.
- `restore-unit` honours `KBC_DRY_RUN=1` (stages nothing, exits 0).
- declared capabilities correspond to implemented verbs and vice versa.

The `generic-dir` reference adapter doubles as the fixture for this harness.

---

## 6. Open questions (design-level)

Carried from HANDOVER §10 plus seams exposed above:

1. **TSV vs JSON Lines** for record verbs (§1.4). TSV now to keep Layer 1 jq-free; revisit if `jq`
   is universal on targets.
2. **`unit-id` charset** — lock the exact allowed character set (must be a safe restic tag + path
   component). Proposal: `[A-Za-z0-9._-]`, adapter responsible for mapping.
3. **Partial-failure policy** — moot for backups (they stay whole-box); a restore is one unit and
   aborts on the first failure, keeping its workdir.
4. **Snapshot ↔ unit mapping** — **decided 2026-10-31: no per-unit tags or paths.** Every hourly
   whole-box snapshot already holds every unit; a unit restore extracts the unit's paths with
   `restic restore --include`. Only `pre-restore` safety snapshots are tagged per unit (`unit-<id>`).
   §2.1 steps 5–6 (per-unit snapshots, quiesce) stay optional for adapters that need them.
5. **Multi-repo fan-out** (KISS + second location via `restic copy`, HANDOVER §6) — does the adapter
   see one logical repo (engine hides fan-out)? Proposed: yes, adapters are repo-agnostic.
6. **Contract versioning** — how the engine negotiates when an adapter speaks a newer minor. Proposed:
   major must match, newer minor tolerated (unknown `info` keys ignored).

These are the first things to settle before the DirectAdmin adapter hardens past Phase 1.
