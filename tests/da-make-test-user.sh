#!/usr/bin/env bash
#
# da-make-test-user.sh — create a DirectAdmin test account from the CLI (no DA login)
# Project: KISS-Backup-Client
# Summary: Creates <user> with domain <domain> through DA's own API (via `da api-url`, the
#   root-local admin login), plus a database <user>_kbtest and a marker file in public_html,
#   so a backup → restore test has files, mail, DNS and a DB to work with. TEST BOXES ONLY.
#
# Usage:  bash tests/da-make-test-user.sh [user] [domain]     # default: kbuser kbuser.test
#         bash tests/da-make-test-user.sh --delete [user]      # remove it again (DA deletes the
#                                                              # home, mail, DNS and its DBs)
#
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND (rc $?)" >&2' ERR

DEL=0; [ "${1:-}" = --delete ] && { DEL=1; shift; }
U="${1:-kbuser}"; DOM="${2:-$U.test}"
DA=/usr/local/directadmin
[ "$(id -u)" -eq 0 ] || { echo "run as root" >&2; exit 1; }
[[ "$U" =~ ^[a-z][a-z0-9]{0,15}$ ]] && [ "$U" != admin ] || { echo "refusing user '$U'" >&2; exit 1; }
API="$("$DA/directadmin" api-url | tail -1)"
[[ "$API" == http* ]] || { echo "could not get 'directadmin api-url' (DA too old?)" >&2; exit 1; }
IP="$(find "$DA/data/admin/ips/" -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | head -1)"
[ -n "$IP" ] || IP="$(hostname -I | awk '{print $1}')"
echo "API ok, IP $IP"
PW="$(openssl rand -hex 8)"
# DA wants a real-looking address: the admin's own, else admin@<hostname>.
EMAIL="$(sed -n 's/^email=//p' "$DA/data/users/admin/user.conf" 2>/dev/null | head -1)"
[[ "$EMAIL" == *@*.* ]] || EMAIL="admin@$(hostname -f)"

call() {   # call <CMD> <post-data> — prints DA's reply, fails on error=1
    local r; r="$(curl -sk "$API/$1" --data "$2")"
    printf '%s: %s\n' "$1" "$(printf '%s' "$r" | sed 's/+/ /g; s/%20/ /g; s/%2E/./g')"
    case "$r" in *error=0*) ;; *) return 1 ;; esac
}

if [ "$DEL" -eq 1 ]; then
    [ -d "$DA/data/users/$U" ] || { echo "$U does not exist — nothing done" >&2; exit 1; }
    printf 'was uid %s\n' "$(id -u "$U" 2>/dev/null || echo '?')"
    call CMD_API_SELECT_USERS "confirmed=Confirm&delete=yes&select0=$U"
    exit 0
fi
[ -d "$DA/data/users/$U" ] && { echo "$U already exists — nothing done" >&2; exit 1; }

# Unlimited custom account (no package needed), shell off, CGI/PHP/SSL on.
lim=""
for k in bandwidth quota vdomains nsubdomains nemails nemailf nemailml nemailr mysql domainptr ftp; do
    lim="$lim&u$k=ON"
done
call CMD_API_ACCOUNT_USER "action=create&add=Submit&username=$U&email=$EMAIL&passwd=$PW&passwd2=$PW&domain=$DOM&ip=$IP&notify=no&aftp=OFF&cgi=ON&php=ON&spam=ON&cron=ON&ssl=ON&ssh=OFF&sysinfo=OFF&dnscontrol=ON$lim"

# The DB is the user's own — create it with the new account's login.
UAPI="$(printf '%s' "$API" | sed "s#://[^@]*@#://$U:$PW@#")"
API="$UAPI" call CMD_API_DATABASES "action=create&name=kbtest&user=kbtest&passwd=$PW&passwd2=$PW"
mysql -e "CREATE TABLE IF NOT EXISTS ${U}_kbtest.t (v INT); INSERT INTO ${U}_kbtest.t VALUES (1);"

f="/home/$U/domains/$DOM/public_html/kbtest.txt"
echo v1 > "$f" && chown "$U:$U" "$f"
printf '\nCreated %s (uid %s) with %s, DB %s_kbtest (t.v=1), %s\n' "$U" "$(id -u "$U")" "$DOM" "$U" "$f"
printf 'Password (kept nowhere else): %s\n' "$PW"
