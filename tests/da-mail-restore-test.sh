#!/usr/bin/env bash
#
# da-mail-restore-test.sh — mail survives a restore end to end (DirectAdmin test box)
# Project: KISS-Backup-Client
# Summary: Proves a restored mailbox is really usable, not just present on disk:
#     1. the account is caged (CloudLinux CageFS), if CageFS is installed;
#     2. creates mailbox kbtest@<domain> (DA API), delivers message A through Exim and
#        checks it lands in the Maildir and an IMAP login sees it;
#     3. backs the box up (kiss-backup.service);
#     4. deletes the mailbox's messages (the "damage");
#     5. restores the account's files (mirror, CLI);
#     6. checks message A is back, owned user:mail, IMAP login still works, and a NEW
#        message B is delivered after the restore (Exim/Dovecot ids line up).
#   Prints PASS/FAIL. TEST BOXES ONLY — it resets the account's password (DA API) to drive
#   the mailbox API, and replaces the account's files with the backup.
#
# Needs: an existing DA account with a domain (default kbuser / kbuser.test — make one with
#        tests/da-make-test-user.sh), Exim + Dovecot (DA defaults), curl with IMAP.
# Usage:  bash tests/da-mail-restore-test.sh [user] [domain]
#
set -uo pipefail

U="${1:-kbuser}"; DOM="${2:-$U.test}"; BOX=kbtest; ADDR="$BOX@$DOM"
DA=/usr/local/directadmin
MD="/home/$U/imap/$DOM/$BOX/Maildir"
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[ -f "$DA/data/users/$U/user.conf" ] || { echo "no DA account $U — run tests/da-make-test-user.sh first" >&2; exit 1; }

fail=0
step() { printf '\n== %s\n' "$*"; }
ok()   { printf 'PASS  %s\n' "$*"; }
bad()  { printf 'FAIL  %s\n' "$*"; fail=1; }
note() { printf 'note  %s\n' "$*"; }

API="$("$DA/directadmin" api-url | tail -1)"
[[ "$API" == http* ]] || { echo "could not get 'directadmin api-url'" >&2; exit 1; }
call() {   # call <base-url> <CMD> <post-data>
    local r; r="$(curl -sk "$1/$2" --data "$3")"
    case "$r" in *error=0*) return 0 ;; *) printf '%s: %s\n' "$2" "$(printf '%s' "$r" | sed 's/+/ /g; s/%20/ /g')" >&2; return 1 ;; esac
}
# The mailbox API runs as the account: give it a fresh password through the admin API.
UPW="$(openssl rand -hex 8)"; MPW="$(openssl rand -hex 8)"
call "$API" CMD_API_USER_PASSWD "username=$U&passwd=$UPW&passwd2=$UPW" || { echo "could not set $U's password" >&2; exit 1; }
UAPI="$(printf '%s' "$API" | sed "s#://[^@]*@#://$U:$UPW@#")"

imap_count() {   # number of messages IMAP reports in the INBOX, or "login-failed"
    local r
    r="$(curl -s --max-time 15 --url "imap://127.0.0.1/INBOX" --user "$ADDR:$MPW" -X 'EXAMINE INBOX' 2>&1)" \
        || { echo login-failed; return; }
    sed -n 's/^\* \([0-9]*\) EXISTS.*/\1/p' <<<"$r" | head -1
}
wait_for() {     # wait_for <subject> — up to 60 s for it to land in the Maildir
    for _ in $(seq 30); do
        grep -rlq "^Subject: $1" "$MD"/new "$MD"/cur 2>/dev/null && return 0
        sleep 2
    done
    return 1
}
send() { printf 'From: root@%s\nTo: %s\nSubject: %s\n\nkiss-backup mail restore test\n' "$(hostname -f)" "$ADDR" "$1" \
    | /usr/sbin/sendmail -f "root@$(hostname -f)" "$ADDR"; }

step "1. CageFS"
# DA refuses an unlimited send limit (limit=0), hence a normal daily 100 below.
CFS="$(command -v cagefsctl || ls /usr/sbin/cagefsctl 2>/dev/null || true)"
if [ -n "$CFS" ]; then
    if "$CFS" --list-enabled 2>/dev/null | grep -qx "$U"; then ok "$U is caged (CageFS enabled)"
    else bad "$U is not in 'cagefsctl --list-enabled' (mode: $("$CFS" --display-user-mode 2>/dev/null | head -1))"; fi
elif [ -e /etc/cloudlinux-release ] || grep -qi cloudlinux /etc/os-release 2>/dev/null; then
    note "CloudLinux, but CageFS is not installed ($(rpm -q cagefs 2>&1 | head -1)) — not tested"
else note "not a CloudLinux box — CageFS not tested"; fi

step "2. mailbox $ADDR + message A"
call "$UAPI" CMD_API_POP "action=delete&domain=$DOM&user=$BOX" 2>/dev/null || true
call "$UAPI" CMD_API_POP "action=create&domain=$DOM&user=$BOX&passwd=$MPW&passwd2=$MPW&quota=0&limit=100" \
    || { echo "could not create $ADDR" >&2; exit 1; }
send KBTEST-A
wait_for KBTEST-A && ok "message A delivered to $MD" || bad "message A not delivered (exim -bp / exigrep KBTEST-A)"
n="$(imap_count)"
[ "${n:-0}" -ge 1 ] 2>/dev/null && ok "IMAP login works, INBOX has $n message(s)" || bad "IMAP before restore: ${n:-no answer}"

step "3. backup"
systemctl start kiss-backup.service && ok "backup taken" || bad "kiss-backup.service failed (journalctl -u kiss-backup)"

step "4. damage: delete the mailbox's messages"
rm -f "$MD"/new/* "$MD"/cur/*
grep -rlq '^Subject: KBTEST-A' "$MD"/new "$MD"/cur 2>/dev/null && bad "messages not deleted" || echo "deleted"

step "5. restore $U's files (mirror)"
kiss-backup restore-unit "$U" --files-only --mirror --yes > /root/mail-test-restore.log 2>&1
tail -4 /root/mail-test-restore.log
grep -q "restore of $U done" /root/mail-test-restore.log && ok "restore finished" || bad "restore failed (see /root/mail-test-restore.log)"

step "6. checks"
f="$(grep -rl '^Subject: KBTEST-A' "$MD"/new "$MD"/cur 2>/dev/null | head -1)"
[ -n "$f" ] && ok "message A is back" || bad "message A not restored"
[ -n "$f" ] && { o="$(stat -c %U:%G "$f")"; [ "$o" = "$U:mail" ] && ok "restored message owned $o" || bad "restored message owned $o (want $U:mail)"; }
n="$(imap_count)"
[ "${n:-0}" -ge 1 ] 2>/dev/null && ok "IMAP login works after restore, INBOX has $n message(s)" || bad "IMAP after restore: ${n:-no answer}"
send KBTEST-B
wait_for KBTEST-B && ok "new message B delivered after the restore" || bad "message B not delivered after the restore"
n2="$(imap_count)"
[ "${n2:-0}" -gt "${n:-0}" ] 2>/dev/null && ok "IMAP sees message B ($n2 message(s))" || bad "IMAP count after B: ${n2:-?}"

printf '\n%s\n' "$([ "$fail" -eq 0 ] && echo 'ALL PASSED' || echo 'SOME CHECKS FAILED')"
exit "$fail"
