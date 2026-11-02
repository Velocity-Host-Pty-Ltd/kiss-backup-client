# Roadmap

What KISS Backup Client does today and what is planned. Done items are ~~struck through~~,
with the release they shipped in. No dates — items move up when they are ready.
Ideas and requests: [GitHub Issues](https://github.com/Velocity-Host-Pty-Ltd/kiss-backup-client/issues).

## Backup & restore
- ~~Hourly encrypted offsite backups, daily database dumps, GFS retention~~ (0.1)
- ~~Per-account restore for DirectAdmin: files, mail, DNS and databases; merge or exactly as it was~~ (0.1)
- ~~Preview before restoring, safety snapshot so a restore can be undone~~ (0.1)
- ~~Browse a backup and fetch single files~~ (0.1)
- ~~Weekly integrity check and restore drill~~ (0.1)
- ~~Account checkpoints (files, databases or both, labelled) and per-account restore points~~ (0.2)
- Hourly per-account database restore from the on-server MariaDB snapshots
- Re-create the panel account itself during a restore (full-server rebuilds)
- Retention limit for checkpoints

## Control panels & platforms
- ~~DirectAdmin on CloudLinux 8, including CageFS~~ (0.1 / 0.2)
- Debian / Ubuntu
- CloudLinux 9 / AlmaLinux 9
- cPanel
- Plesk

## Hosting providers
- Reseller access: resellers restore their own clients' accounts
- Type-to-filter account picker for servers with hundreds of accounts
- Sign up for KISS storage from the setup wizard
