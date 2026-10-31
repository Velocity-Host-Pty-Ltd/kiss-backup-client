# packaging/ — installer & release packaging

- `ansible/backups_foundation/` — the original Ansible role, kept as a **reference** for the
  standalone installer (systemd timers/services it lays down, the `backup.env`/excludes templates).
  The standalone product will install its own way (no ansible-pull assumption) — see EXTRACTION §6.

Release format (ship-as-files vs versioned tarball vs rpm/deb) is deferred to first-release time
(HANDOVER §7).
