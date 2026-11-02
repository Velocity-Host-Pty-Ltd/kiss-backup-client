# Tests — what is proven, and how

Two kinds of test:

- **Unit tests** run anywhere, unprivileged, in a throwaway temp dir. They drive the real code
  (engine, adapter library) against a local restic repository or stubs.
- **DirectAdmin box tests** run as root on a real DirectAdmin server and test the whole thing end
  to end: the panel's API, Exim, Dovecot, CageFS and the KISS storage over SFTP. Each is one script
  that sets up what it needs, does the damage, restores, checks, and prints `PASS`/`FAIL` per check
  and `ALL PASSED` at the end. **Test servers only** — they delete and re-create accounts.

Test server for the results below: **CloudLinux 8.10 + DirectAdmin 1.713**, restic 0.19.1, backing
up over SFTP to a KISS storage zone.

---

## Unit tests

### `verify-restore-inplace.sh` — the in-place restore, against a real restic repo

```bash
RESTIC_BIN=/path/to/restic bash tests/verify-restore-inplace.sh
```

Builds a fake server tree with two accounts, backs it up into a local restic repo, damages
account `u1`, and drives `restore-unit` with a stub adapter.

| Check | Why it matters |
|---|---|
| dry run lists the delete, changes nothing | the preview is trustworthy |
| mirror: deleted file back, changed file rolled back, extra file removed | "exactly as it was" really is |
| `--delete` stayed inside `u1` (a new file in `u2` survives) | restoring one account can't damage another |
| safety snapshot taken / skipped with `--no-safety-snapshot` | undo is there unless you opt out |
| no work directory left behind | files are restored in place, nothing staged |
| merge keeps extras | merge mode doesn't delete |
| an account path that is a whole backup root is refused | a broken adapter can't make "one account" mean `/home` |
| a repository failure leaves the `<account>.failed` marker; a good restore clears it | failures are visible in the console |

**Last result:** 10/10 PASS (2026-11-02).

### `verify-restore-owner-remap.sh` — re-owning files when user/group IDs moved

```bash
bash tests/verify-restore-owner-remap.sh
```

Feeds the adapter library's re-owner an ID map (as the engine builds it from the backup's
`/etc/passwd` + `/etc/group` vs the live ones) with `chown` replaced by a logger.

Checks: empty map → nothing; dry run → nothing; user + group moved → exactly the account's files
re-owned; files outside the account untouched; a group-only move keeps the user; an ID no file
carries → nothing; root entries are ignored.

**Last result:** 7/7 PASS (2026-11-02).

### Also verified by hand (2026-11-02, restic 0.19.1)

- `restic restore --target / --include <path> --delete` deletes only inside the included path.
- An interrupted restore, run again, skips finished files, rewrites half-written ones and fetches
  the missing ones; a third run touches nothing.

---

## DirectAdmin box tests

Helper: **`da-make-test-user.sh [user] [domain]`** creates a DirectAdmin account from the CLI
through DirectAdmin's own API (`directadmin api-url`) — with a domain, a database
`<user>_kbtest` holding one row, and a marker file `kbtest.txt` (`v1`) in `public_html`.
`--delete [user]` removes it again through DirectAdmin (home, mail, DNS and databases).
Default: `kbuser` / `kbuser.test`.

### Per-account restore through the console (mirror)

The account was damaged — `kbtest.txt` changed to `v2`, a `backdoor.php` planted, the database row
changed to 2 — then restored from **Backups → Restore an account → Exactly as it was**, with a
safety snapshot.

- Preview listed only `kbtest.txt` (updated) and `backdoor.php` (deleted), and touched only the
  account's four areas: home, DirectAdmin user data, `/etc/virtual/<domain>`, `/var/named/<domain>.db`.
- After: `kbtest.txt` back to `v1`, `backdoor.php` gone, database back to 1, safety snapshot in the
  repository, DirectAdmin httpd rewrite queued, DNS reloaded.

**Result:** PASS (2026-11-01).

### Interrupted restore (kill test)

A 300 MB file was backed up and deleted; while restoring it, restic was killed 8 seconds in.

- The engine logged the failure, waited 30 s, retried by itself and finished.
- SHA-256 of the restored file matched the original; owner and mode correct.

**Result:** PASS (2026-11-01).

### Browse a backup

`kbtest.txt` deleted, then fetched back with **Backups → Browse a backup** (restic mount + `mc`, F5).

- File back, owner and timestamp as in the backup; mount gone after quitting `mc`; nothing staged
  on local disk.

**Result:** PASS (2026-11-01).

### `da-uid-recreate-test.sh` — restore onto a re-created account with new IDs

```bash
bash tests/da-uid-recreate-test.sh [user]      # then: --cleanup
```

The disaster case: the account is gone, comes back with different user/group IDs, and its *old*
IDs now belong to someone else.

1. Finds the newest backup that still has the user in its `/etc/passwd` (and reads the old IDs) —
   a later hourly backup no longer contains a deleted account, so "latest" would be wrong.
2. Deletes the account through DirectAdmin; re-creates it; moves it to new IDs; gives the old IDs
   to a placeholder user.
3. Previews, then restores (mirror, with safety snapshot) from that backup.
4. Checks: no file left on the old user or group ID; `kbtest.txt` back and owned by the account;
   `/home/<user>` keeps DirectAdmin's shared `access` group; database back; mail config and DNS
   zone present; **DirectAdmin's mail login file no longer names the old user ID**.

Found by this test and fixed: DirectAdmin's `/etc/virtual/<domain>/passwd` stores the user ID
*inside* the file, so a restore put the old ID back and mail would have run as the placeholder
user. The adapter now rewrites those IDs.

**Result:** ALL PASSED, 11 checks (2026-11-01).

### `da-mail-restore-test.sh` — a restored mailbox really works

```bash
bash tests/da-mail-restore-test.sh [user] [domain]
```

1. CageFS: the account is caged (CloudLinux).
2. Creates mailbox `kbtest@<domain>`, delivers message A through Exim, checks it lands and an
   IMAP login sees it.
3. Backs up; deletes the mailbox's messages; restores the account's files (mirror).
4. Checks: message A back and owned `user:mail`; IMAP login works; a new message B is delivered
   after the restore and IMAP sees it.

Found on the way: DirectAdmin refuses an unlimited send limit for a new mailbox, so the test
uses a daily limit of 100.

**Result:** ALL PASSED, 8 checks (2026-11-01). CageFS is not installed on the test server, so the
CageFS check was skipped — not yet tested.

---

## Older scripts (inherited)

`verify-backup-mutex.sh`, `verify-backup-configured-email.sh`, `verify-granular-db-restore.sh`,
`verify-restic-forget-prune.sh`, `verify-restic-wrap-mariabackup.sh` and
`verify-restore-step-b.sh` come from the Velocity headless platform this tool was extracted from.
They still call that platform's script names and paths and are kept as references until they
are ported to this product's commands.

Console helpers: `preview-console-palette.sh`, `preview-console-buttons.sh` (show the console's
colours) and `probe-whiptail-buttons.py` (measures which whiptail button is really highlighted —
the focus colours are easy to get backwards).
