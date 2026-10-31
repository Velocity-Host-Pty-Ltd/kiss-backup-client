# packaging/ — installer & release packaging

- `install.sh` — the **standalone installer** (no ansible). Run as root from a checkout:
  `packaging/install.sh`, then `kiss-backup-setup`. Lays down:
  - code → `/usr/local/lib/kiss-backup/` (engine, wizard, notifier, brand header, console), with
    `kiss-backup` / `kiss-backup-setup` / `kiss-console` commands in `/usr/local/sbin`;
  - systemd units → `/etc/systemd/system/`, rendered from the role's templates + `defaults/main.yml`
    (one source of truth for the schedule; check-failure alerting always off standalone);
  - config scaffolding → `/etc/kiss-backup/` (console menus, excludes created once, target example).
  It installs but does **not** enable timers — the wizard does that after the verify round-trip.
  Missing tools (curl, bzip2, whiptail, flock) are installed via dnf or apt. `--uninstall` removes
  code + units, keeping config, the repo key/passphrase and the offsite repo.

- `ansible/backups_foundation/` — the original Ansible role, kept as a **reference** for the
  standalone installer (systemd timers/services it lays down, the `backup.env`/excludes templates).
  The standalone product will install its own way (no ansible-pull assumption) — see EXTRACTION §6.

Release format (ship-as-files vs versioned tarball vs rpm/deb) is deferred to first-release time
(HANDOVER §7).
