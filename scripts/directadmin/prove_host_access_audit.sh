#!/bin/bash
# Offline proof that host_access_audit.sh does not hand out clean verdicts to
# exposed hosts. Every case here is a way an audit can look green while a
# password path stays open -- which is worse than having no audit, because it
# ends the investigation.
#
# Case 3 is the one that motivates the whole script: PasswordAuthentication is
# "no", which is what an operator greps for and where most hardening guides
# stop, while PAM keyboard-interactive still accepts passwords.
#
# Cases 4-6 cover what `sshd -T` alone cannot see, cases 7-8 that a check which
# could not run never reads as a pass, case 9 that a setting can be present and
# switched off, and case 10 that one busy fail2ban jail cannot vouch for a
# broken one.
#
# Cases 23-24 are the mirror image, and they arrived later because the failure
# is quieter: an audit that keeps reporting a finding after the control is in
# place asks for work already done, and an operator who is told that twice stops
# reading the report. They assert both directions, since the cost of getting
# this wrong the other way is the audit vouching for access it never checked.
#
# Usage (from repo root):
#   ./scripts/directadmin/prove_host_access_audit.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUDIT="${ROOT}/scripts/directadmin/host_access_audit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# Default the machine-sniffing fallbacks to "nothing here" so no case can
# accidentally assert against the box running the proof. Cases that are about
# the fallback itself override this per-run. Case 16 was failing on a CI runner
# that ships /etc/apache2 while passing everywhere else.
export HOST_AUDIT_APACHE_EVIDENCE=0

# Minimal `sshd -T` dumps. Real output has ~90 keys; only the ones the audit
# reads matter, and extra keys are ignored by the awk lookups.
cat >"$TMP/hardened" <<'EOF'
port 22
passwordauthentication no
kbdinteractiveauthentication no
usepam yes
permitrootlogin no
allowgroups sshusers
EOF

cat >"$TMP/passwords-open" <<'EOF'
port 22
passwordauthentication yes
kbdinteractiveauthentication no
usepam yes
permitrootlogin prohibit-password
EOF

cat >"$TMP/kbd-hole" <<'EOF'
port 22
passwordauthentication no
kbdinteractiveauthentication yes
usepam yes
permitrootlogin no
allowgroups sshusers
EOF

run() { HOST_AUDIT_SSHD_T_FILE="$1" bash "$AUDIT" --json 2>/dev/null || true; }

verdict_for() {
  python3 -c "
import json,sys
d=json.load(sys.stdin)
for i in d['items']:
    if i['area']=='$1':
        print(i['verdict']); break
else:
    print('MISSING')
"
}

echo "== Case 1: fully hardened sshd =="
out="$(run "$TMP/hardened")"
[ "$(printf '%s' "$out" | verdict_for ssh/password)" = "OK" ] \
  || { echo "FAIL: hardened config not reported OK" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for ssh/kbd-interactive)" = "OK" ] \
  || { echo "FAIL: hardened kbd-interactive not reported OK" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for ssh/allowlist)" = "OK" ] \
  || { echo "FAIL: AllowGroups not detected" >&2; exit 1; }

# Every allowed group, not just the first. Reporting `allowgroups sshusers wheel`
# as `allowgroups=sshusers` understates who may log in, in the one check whose
# whole job is to state that.
printf 'port 22\npasswordauthentication no\nkbdinteractiveauthentication no\nusepam yes\npermitrootlogin no\nallowgroups sshusers wheel\nallowusers ops1 ops2\n' \
  >"$TMP/allow-multi"
run "$TMP/allow-multi" | grep -q 'allowgroups=sshusers,wheel' \
  || { echo "FAIL: additional allowed groups dropped from the report" >&2; exit 1; }
run "$TMP/allow-multi" | grep -q 'allowusers=ops1,ops2' \
  || { echo "FAIL: additional allowed users dropped from the report" >&2; exit 1; }
echo "OK hardened config reports clean on every SSH check, naming every allowed principal"

echo "== Case 2: PasswordAuthentication yes =="
out="$(run "$TMP/passwords-open")"
[ "$(printf '%s' "$out" | verdict_for ssh/password)" = "FAIL" ] \
  || { echo "FAIL: open password auth not flagged" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for ssh/allowlist)" = "WARN" ] \
  || { echo "FAIL: missing AllowUsers/AllowGroups not warned" >&2; exit 1; }
echo "OK open password auth is flagged"

echo "== Case 3: passwords 'off' but PAM keyboard-interactive still on =="
out="$(run "$TMP/kbd-hole")"
[ "$(printf '%s' "$out" | verdict_for ssh/password)" = "OK" ] \
  || { echo "FAIL: expected the obvious check to pass here" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for ssh/kbd-interactive)" = "FAIL" ] \
  || { echo "FAIL: the kbd-interactive password path was missed" >&2; exit 1; }
echo "OK the config that looks hardened but is not gets caught"

echo "== Case 4: a Match block re-enables passwords for one account =="
# Bare `sshd -T` reports the base config, so the hardened dump above is exactly
# what an audit sees on a host whose Match block reopens a password path. The
# per-context probe is the only thing standing between that and a clean verdict.
mkdir -p "$TMP/ctx"
cp "$TMP/hardened" "$TMP/ctx/root.txt"
cp "$TMP/hardened" "$TMP/ctx/user01.txt"
cp "$TMP/kbd-hole" "$TMP/ctx/user09.txt"
cat >"$TMP/sshd_config.match" <<'EOF'
PasswordAuthentication no
Match User user09
    KbdInteractiveAuthentication yes
EOF
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" \
  HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.match" \
  HOST_AUDIT_SSHD_T_CTX_DIR="$TMP/ctx" \
  HOST_AUDIT_USERS="root user01 user09" \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for ssh/password)" = "OK" ] \
  || { echo "FAIL: base config should still read OK here" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for ssh/match)" = "FAIL" ] \
  || { echo "FAIL: Match block re-enabling passwords was missed" >&2; exit 1; }
printf '%s' "$out" | grep -q 'user09(kbd-interactive)' \
  || { echo "FAIL: the offending account was not named" >&2; exit 1; }
echo "OK a Match block that bare 'sshd -T' cannot see is caught, and named"

echo "== Case 5: Match blocks present but keyed on address =="
cat >"$TMP/sshd_config.addr" <<'EOF'
PasswordAuthentication no
Match Address 10.0.0.0/8
    PasswordAuthentication yes
EOF
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" \
  HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.addr" \
  HOST_AUDIT_SSHD_T_CTX_DIR="$TMP/ctx" \
  HOST_AUDIT_USERS="root user01" \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for ssh/match-coverage)" = "WARN" ] \
  || { echo "FAIL: unexhaustible address-keyed Match not surfaced" >&2; exit 1; }
echo "OK address-keyed Match blocks are reported as not exhausted, not as clean"

echo "== Case 6: no Match blocks at all =="
printf 'PasswordAuthentication no\n' >"$TMP/sshd_config.plain"
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" \
  HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for ssh/match)" = "OK" ] \
  || { echo "FAIL: absence of Match blocks should be a clean OK" >&2; exit 1; }
echo "OK a config with no Match blocks is not penalised"

echo "== Case 7: a skipped check must not read as a pass =="
# The failure this guards: an unprivileged run inspects nothing and still exits
# 0 with "no findings", so automation accepts a posture never looked at.
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/nonexistent" bash "$AUDIT" --json 2>/dev/null || true)"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d["skipped"] >= 1, "skips were not counted: %r" % d
assert d["complete"] is False, "audit claimed completeness despite a skip: %r" % d
assert "ssh/config" in d["skipped_areas"], d["skipped_areas"]
PY
echo "OK skips are counted, reported, and mark the audit incomplete"

echo "== Case 8: exit status distinguishes incomplete from clean =="
set +e
HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
  bash "$AUDIT" >/dev/null 2>&1
rc=$?
set -e
# 1 (findings) or 3 (incomplete) are both acceptable off a real host, where
# fail2ban and DA are absent. What must not happen is 0, which would claim a
# complete clean audit.
[ "$rc" -ne 0 ] \
  || { echo "FAIL: exited 0 despite checks that could not run" >&2; exit 1; }
echo "OK non-zero exit (${rc}) when the audit is not both complete and clean"

echo "== Case 9: DirectAdmin settings present but switched off =="
# brute_force_log_scanner=0 is a *matched* key. Reporting on key presence would
# hand a clean verdict to a host whose scanner is disabled -- the exact state
# this check exists to find.
printf 'brute_force_log_scanner=0\nbrute_force_time_limit=300\n' >"$TMP/da.off"
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_DA_CONF="$TMP/da.off" \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for da/brute-force)" = "FAIL" ] \
  || { echo "FAIL: disabled DA brute-force scanner reported as configured" >&2; exit 1; }

printf 'brute_force_log_scanner=1\nmax_bfm_attempts=10\n' >"$TMP/da.on"
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_DA_CONF="$TMP/da.on" \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for da/brute-force)" = "OK" ] \
  || { echo "FAIL: an enabled DA scanner should be OK" >&2; exit 1; }
echo "OK DirectAdmin values are read, not just key names"

echo "== Case 10: one busy jail must not vouch for a broken one =="
# A working sshd jail accumulates bans; summed with a DirectAdmin jail whose
# logpath does not exist, the total is comfortably positive and the broken jail
# disappears from an aggregate check. Shim fail2ban-client to that exact shape:
# sshd healthy and busy, directadmin present, quiet, and watching nothing.
mkdir -p "$TMP/bin"
: >"$TMP/real-sshd.log"
export F2B_OK_LOG="$TMP/real-sshd.log"
export F2B_BROKEN_LOG="$TMP/nowhere/da.log"
cat >"$TMP/bin/fail2ban-client" <<'SHIM'
#!/bin/bash
case "$*" in
  "status")               printf '  `- Jail list:\tsshd, directadmin\n' ;;
  "status sshd")          printf '     |- Total banned:\t412\n' ;;
  "status directadmin")   printf '     |- Total banned:\t0\n' ;;
  "get sshd logpath")        printf '`- %s\n' "$F2B_OK_LOG" ;;
  "get directadmin logpath") printf '`- %s\n' "$F2B_BROKEN_LOG" ;;
esac
exit 0
SHIM
cat >"$TMP/bin/systemctl" <<'SHIM'
#!/bin/bash
case "$*" in
  *list-unit-files*) echo amazon-ssm-agent.service ;;
esac
exit 0
SHIM
chmod +x "$TMP/bin/fail2ban-client" "$TMP/bin/systemctl"
out="$(PATH="$TMP/bin:$PATH" HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for fail2ban/logpath)" = "FAIL" ] \
  || { echo "FAIL: jail watching a nonexistent logpath was not caught" >&2; exit 1; }
printf '%s' "$out" | grep -q "directadmin:$TMP/nowhere/da.log" \
  || { echo "FAIL: the broken jail was not named with its path" >&2; exit 1; }
printf '%s' "$out" | grep -q "sshd:$TMP/real-sshd.log" \
  && { echo "FAIL: the healthy jail was wrongly implicated" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for fail2ban/effective)" = "WARN" ] \
  || { echo "FAIL: a permanently quiet jail was masked by the busy one" >&2; exit 1; }
printf '%s' "$out" | grep -q 'zero bans ever recorded for: directadmin' \
  || { echo "FAIL: expected the quiet jail named, not an aggregate" >&2; exit 1; }
echo "OK each jail is judged on its own logpath and ban count"

echo "== Case 11: CSF/lfd is a rate limiter, not an absence of one =="
# The shape of the real primary: CSF with lfd, no fail2ban. Demanding fail2ban
# here reported "nothing rate-limits password guessing" and would have pushed an
# operator into installing a second iptables manager alongside CSF.
cat >"$TMP/csf.conf" <<'EOF'
TCP_IN = "20,21,22,25,80,110,143,443,465,587,993,995,2222"
LF_SSHD = "5"
LF_DIRECTADMIN = "5"
LF_SMTPAUTH = "5"
LF_POP3D = "10"
LF_IMAPD = "10"
LF_FTPD = "10"
EOF
csf_run() {
  env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" \
    HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
    HOST_AUDIT_CSF_CONF="${1:-$TMP/csf.conf}" \
    HOST_AUDIT_LFD_ACTIVE="${2:-1}" \
    HOST_AUDIT_LISTENERS="${3:-22,25,2222}" \
    HOST_AUDIT_INSTANCE_ID="i-000000000000000" \
    bash "$AUDIT" --json 2>/dev/null || true
}
out="$(csf_run)"
[ "$(printf '%s' "$out" | verdict_for ratelimit/lfd)" = "OK" ] \
  || { echo "FAIL: active lfd not recognised as a rate limiter" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for ratelimit/lfd-coverage)" = "OK" ] \
  || { echo "FAIL: fully configured lfd thresholds not accepted" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for fail2ban/installed)" = "MISSING" ] \
  || { echo "FAIL: still demanding fail2ban on a CSF host" >&2; exit 1; }
echo "OK CSF/lfd satisfies the rate-limiting requirement"

echo "== Case 12: an lfd threshold of 0 is a service nobody is watching =="
sed 's/^LF_DIRECTADMIN = "5"/LF_DIRECTADMIN = "0"/' "$TMP/csf.conf" >"$TMP/csf.lf-off"
out="$(csf_run "$TMP/csf.lf-off")"
[ "$(printf '%s' "$out" | verdict_for ratelimit/lfd-coverage)" = "FAIL" ] \
  || { echo "FAIL: LF_DIRECTADMIN=0 accepted as coverage" >&2; exit 1; }
printf '%s' "$out" | grep -q 'LF_DIRECTADMIN' \
  || { echo "FAIL: the unwatched service was not named" >&2; exit 1; }
echo "OK a zero threshold is reported as unmetered, not as configured"

echo "== Case 13: lfd installed but not running =="
out="$(csf_run "$TMP/csf.conf" 0)"
[ "$(printf '%s' "$out" | verdict_for ratelimit/lfd)" = "FAIL" ] \
  || { echo "FAIL: stopped lfd reported as protection" >&2; exit 1; }
echo "OK CSF present with lfd stopped is a failure, not a pass"

echo "== Case 14: MySQL bound to every interface must not read as OK =="
# The first real run listed 3306 among "world-bound ports" and reported OK,
# because only 2222 was ever special-cased. A datastore has no lfd or fail2ban
# in front of it and a success there is the whole dataset.
out="$(csf_run "$TMP/csf.conf" 1 "22,2222,3306")"
[ "$(printf '%s' "$out" | verdict_for exposure/datastore)" = "WARN" ] \
  || { echo "FAIL: 3306 bound but firewalled should warn" >&2; exit 1; }
printf '%s' "$out" | grep -q 'mysql/3306' \
  || { echo "FAIL: the datastore port was not named" >&2; exit 1; }

sed 's/2222"/2222,3306"/' "$TMP/csf.conf" >"$TMP/csf.mysql-open"
out="$(csf_run "$TMP/csf.mysql-open" 1 "22,2222,3306")"
[ "$(printf '%s' "$out" | verdict_for exposure/datastore)" = "FAIL" ] \
  || { echo "FAIL: 3306 bound AND allowed by TCP_IN must fail" >&2; exit 1; }
echo "OK bound-and-allowed fails, bound-but-firewalled warns, and they are distinguished"

echo "== Case 15: plaintext credential ports are surfaced =="
out="$(csf_run "$TMP/csf.conf" 1 "21,22,110,143,993,995")"
[ "$(printf '%s' "$out" | verdict_for exposure/plaintext-auth)" = "WARN" ] \
  || { echo "FAIL: plaintext auth ports not surfaced" >&2; exit 1; }
echo "OK ftp/pop3/imap without implicit TLS are reported"

echo "== Case 16: an irrelevant disabled DA key must not mask the scanner =="
# First real run: brute_force_scan_apache_logs=0 became the finding, and whether
# the scanner itself was enabled went unreported. On an nginx host there are no
# Apache logs to scan, so it is not a finding at all.
#
# webserver= is pinned rather than left to the audit's fallback. Without it the
# fallback looks for Apache on whatever machine is running the proof, and this
# case passed on a developer box and failed on a CI runner that happens to ship
# /etc/apache2 -- a proof that reads the host is not offline.
printf 'brute_force_log_scanner=1\nbrute_force_scan_apache_logs=0\nnginx=1\n' >"$TMP/da.nginx"
printf 'webserver=nginx\n' >"$TMP/cb.nginx"
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_DA_CONF="$TMP/da.nginx" \
  HOST_AUDIT_CB_OPTIONS="$TMP/cb.nginx" bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for da/brute-force)" = "OK" ] \
  || { echo "FAIL: enabled scanner masked by an irrelevant disabled key" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for da/brute-force-disabled)" = "MISSING" ] \
  || { echo "FAIL: apache log scanning should not be a finding on nginx" >&2; exit 1; }
echo "OK the scanner's own state is the verdict"

echo "== Case 17: nginx in front of Apache still needs Apache logs scanned =="
# DirectAdmin's nginx_apache mode runs nginx as a reverse proxy and Apache still
# serves, so the nginx binary is present and Apache logs are real. Treating
# "nginx exists" as "Apache is absent" would drop a genuine finding.
printf 'brute_force_log_scanner=1\nbrute_force_scan_apache_logs=0\nnginx=1\n' >"$TMP/da.nginx"
printf 'webserver=nginx_apache\n' >"$TMP/cb.hybrid"
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_DA_CONF="$TMP/da.nginx" \
  HOST_AUDIT_CB_OPTIONS="$TMP/cb.hybrid" bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for da/brute-force-disabled)" = "WARN" ] \
  || { echo "FAIL: unscanned Apache logs dropped on a hybrid host" >&2; exit 1; }

printf 'webserver=nginx\n' >"$TMP/cb.nginx"
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_DA_CONF="$TMP/da.nginx" \
  HOST_AUDIT_CB_OPTIONS="$TMP/cb.nginx" bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for da/brute-force-disabled)" = "MISSING" ] \
  || { echo "FAIL: nginx-only host should not warn about Apache logs" >&2; exit 1; }

# With no CustomBuild answer, Apache's own presence decides. Installed or
# running Apache keeps the finding even though nginx is also there.
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_DA_CONF="$TMP/da.nginx" \
  HOST_AUDIT_CB_OPTIONS="$TMP/absent" HOST_AUDIT_APACHE_EVIDENCE=1 \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for da/brute-force-disabled)" = "WARN" ] \
  || { echo "FAIL: Apache present with no CustomBuild answer should keep the finding" >&2; exit 1; }

out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_DA_CONF="$TMP/da.nginx" \
  HOST_AUDIT_CB_OPTIONS="$TMP/absent" HOST_AUDIT_APACHE_EVIDENCE=0 \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for da/brute-force-disabled)" = "MISSING" ] \
  || { echo "FAIL: no Apache anywhere is real evidence, not a guess" >&2; exit 1; }
echo "OK the web server mode decides; without one, Apache's own presence does"

echo "== Case 18: real lfd config, with the _PERM siblings present =="
# Verbatim shape from server.wbat.net. LF_SSHD_PERM must not be mistaken for
# LF_SSHD, and every threshold here is set and non-zero.
cat >"$TMP/csf.real" <<'EOF'
LF_SSHD = "5"
LF_SSHD_PERM = "1"
LF_FTPD = "10"
LF_FTPD_PERM = "1"
LF_SMTPAUTH = "5"
LF_SMTPAUTH_PERM = "1"
LF_POP3D = "10"
LF_POP3D_PERM = "1"
LF_IMAPD = "10"
LF_IMAPD_PERM = "1"
LF_DIRECTADMIN = "5"
LF_DIRECTADMIN_PERM = "1"
TCP_IN = "35000:35999,20,21,22,25,53,80,110,143,443,465,587,993,995,2222"
EOF
out="$(csf_run "$TMP/csf.real" 1 "21,22,25,110,143,465,587,993,995,2222,3306,4190")"
[ "$(printf '%s' "$out" | verdict_for ratelimit/lfd-coverage)" = "OK" ] \
  || { echo "FAIL: a fully configured real lfd was not accepted" >&2; exit 1; }
printf '%s' "$out" | grep -q 'LF_SSHD=5' \
  || { echo "FAIL: LF_SSHD value misparsed (likely confused with LF_SSHD_PERM)" >&2; exit 1; }
# 3306 is bound but absent from that TCP_IN, and 2222 is bound and present.
[ "$(printf '%s' "$out" | verdict_for exposure/datastore)" = "WARN" ] \
  || { echo "FAIL: 3306 bound-but-firewalled misclassified" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for exposure/da-panel)" = "OK" ] \
  || { echo "FAIL: the socket-level 2222 fact should be reported, not judged" >&2; exit 1; }
# Nothing here can reach EC2, so the boundary is unknown -- and unknown must
# leave the audit incomplete rather than reading as either safe or exposed.
[ "$(printf '%s' "$out" | verdict_for exposure/da-panel-sg)" = "SKIP" ] \
  || { echo "FAIL: unknown security group should skip" >&2; exit 1; }
echo "OK the live host's configuration is classified correctly end to end"

echo "== Case 19: the 2222 boundary is the security group, not the socket =="
# Warning purely on "bound and passed by TCP_IN" would keep reporting a finding
# on a host whose panel is already closed at the security group. A verdict that
# doing the right thing cannot clear is one people learn to ignore.
: >"$TMP/sg-none.txt"
printf '0.0.0.0/0\n' >"$TMP/sg-open.txt"
printf '174.49.138.101/32\t44.214.133.234/32\n' >"$TMP/sg-restricted.txt"
sg_run() {
  env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
    HOST_AUDIT_CSF_CONF="$TMP/csf.conf" HOST_AUDIT_LFD_ACTIVE=1 \
    HOST_AUDIT_LISTENERS="22,2222" HOST_AUDIT_SG_RULES_FILE="$1" \
    bash "$AUDIT" --json 2>/dev/null || true
}
[ "$(sg_run "$TMP/sg-open.txt" | verdict_for exposure/da-panel-sg)" = "FAIL" ] \
  || { echo "FAIL: 0.0.0.0/0 on 2222 not reported" >&2; exit 1; }
[ "$(sg_run "$TMP/sg-restricted.txt" | verdict_for exposure/da-panel-sg)" = "OK" ] \
  || { echo "FAIL: a restricted panel should clear" >&2; exit 1; }
[ "$(sg_run "$TMP/sg-none.txt" | verdict_for exposure/da-panel-sg)" = "OK" ] \
  || { echo "FAIL: a fully closed panel should clear" >&2; exit 1; }
sg_run "$TMP/sg-none.txt" | grep -q 'closed to the internet entirely' \
  || { echo "FAIL: closed and restricted should be distinguishable" >&2; exit 1; }

# ::/0 is exactly as open as 0.0.0.0/0, and a rule set of only null columns is
# the CLI's way of printing "no sources", not a set of allowed addresses.
printf '::/0\n' >"$TMP/sg-v6.txt"
printf 'None\tNone\tNone\tNone\n' >"$TMP/sg-nulls.txt"
printf 'pl-0abc123\n' >"$TMP/sg-prefix.txt"
printf 'sg-0e674f4e2937c6392\n' >"$TMP/sg-selfref.txt"
[ "$(sg_run "$TMP/sg-v6.txt" | verdict_for exposure/da-panel-sg)" = "FAIL" ] \
  || { echo "FAIL: ::/0 on 2222 is an open panel" >&2; exit 1; }
[ "$(sg_run "$TMP/sg-nulls.txt" | verdict_for exposure/da-panel-sg)" = "OK" ] \
  || { echo "FAIL: all-null columns mean no sources, not restricted sources" >&2; exit 1; }
sg_run "$TMP/sg-nulls.txt" | grep -q 'closed to the internet entirely' \
  || { echo "FAIL: all-null columns should read as closed" >&2; exit 1; }
# A prefix list is an indirection this vantage point cannot see through, so it
# is neither a pass nor a failure -- claiming either would be inventing a fact.
[ "$(sg_run "$TMP/sg-prefix.txt" | verdict_for exposure/da-panel-sg)" = "WARN" ] \
  || { echo "FAIL: an unexpanded prefix list must not read as restricted" >&2; exit 1; }
[ "$(sg_run "$TMP/sg-selfref.txt" | verdict_for exposure/da-panel-sg)" = "OK" ] \
  || { echo "FAIL: a group self-reference is a restricted source" >&2; exit 1; }

# And with no way to ask AWS, it must skip rather than guess either way.
out="$(env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
  HOST_AUDIT_CSF_CONF="$TMP/csf.conf" HOST_AUDIT_LFD_ACTIVE=1 \
  HOST_AUDIT_LISTENERS="22,2222" HOST_AUDIT_INSTANCE_ID="i-000000000000000" \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for exposure/da-panel-sg)" = "SKIP" ] \
  || { echo "FAIL: unknown security group should skip, not pass or fail" >&2; exit 1; }
echo "OK the security group decides, and an unanswerable question skips"

echo "== Case 20: the security-group query itself, not a copy of it =="
# Case 19 injects rules through HOST_AUDIT_SG_RULES_FILE, which proves the
# classification but never runs the JMESPath. That gap hid a real bug: the
# query was missing the `[]` flatten after the filter, so against actual AWS
# output it returned nothing for a world-open group -- and "nothing" was read
# as "no rule allows 2222". The check would have certified an open panel as
# closed. So evaluate the exact query the script ships, with the same engine
# the CLI uses, against recorded describe-security-groups shapes.
# A hard requirement, not a skip. This case is the one that caught the query
# being wrong, so quietly passing without it would restore the original problem.
command -v python3 >/dev/null 2>&1 \
  || { echo "FAIL: python3 is required to evaluate the security-group query" >&2; exit 1; }
python3 - "$AUDIT" <<'PY' || exit 1
import json, re, subprocess, sys

src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'^DA_PANEL_SG_QUERY="(.+)"$', src, re.M)
if not m:
    sys.exit("FAIL: could not extract DA_PANEL_SG_QUERY from the audit script")
# The script stores it for a double-quoted shell context, where \` is a literal.
query = m.group(1).replace("\\`", "`")

try:
    import jmespath
except ImportError:
    sys.exit("FAIL: jmespath is required to prove the security-group query "
             "(pip install jmespath) -- it is the engine the AWS CLI applies "
             "--query with, so nothing else proves the same thing")


def perm(proto="tcp", frm=None, to=None, v4=(), v6=(), pl=(), sg=()):
    p = {"IpProtocol": proto,
         "IpRanges": [{"CidrIp": c} for c in v4],
         "Ipv6Ranges": [{"CidrIpv6": c} for c in v6],
         "PrefixListIds": [{"PrefixListId": i} for i in pl],
         "UserIdGroupPairs": [{"GroupId": g} for g in sg]}
    if frm is not None:
        p["FromPort"], p["ToPort"] = frm, to
    return p


web = perm("tcp", 443, 443, v4=["0.0.0.0/0"])
cases = [
    ("as applied: two server EIPs plus the group self-reference",
     [perm("tcp", 2222, 2222, v4=["44.214.133.234/32", "34.205.151.236/32"],
           sg=["sg-0e674f4e2937c6392"]), web],
     {"44.214.133.234/32", "34.205.151.236/32", "sg-0e674f4e2937c6392"}),
    ("world-open on 2222 -- the case the broken query missed entirely",
     [perm("tcp", 2222, 2222, v4=["0.0.0.0/0"])], {"0.0.0.0/0"}),
    ("open over IPv6 only",
     [perm("tcp", 2222, 2222, v6=["::/0"])], {"::/0"}),
    ("an all-traffic -1 rule, which carries no FromPort",
     [perm("-1", v4=["0.0.0.0/0"])], {"0.0.0.0/0"}),
    ("a 2000-3000 range that covers 2222 without naming it",
     [perm("tcp", 2000, 3000, v4=["0.0.0.0/0"])], {"0.0.0.0/0"}),
    ("a prefix list as the source",
     [perm("tcp", 2222, 2222, pl=["pl-0abc123"])], {"pl-0abc123"}),
    ("genuinely closed: 2222 appears in no rule",
     [web], set()),
    ("adjacent ports must not be picked up",
     [perm("tcp", 2223, 2223, v4=["0.0.0.0/0"]),
      perm("tcp", 22, 22, v4=["1.2.3.4/32"])], set()),
    ("rules spread across two security groups both count",
     None, {"0.0.0.0/0", "sg-0aaa"}),
]

fail = 0
for name, perms, expected in cases:
    if perms is None:
        doc = {"SecurityGroups": [
            {"IpPermissions": [perm("tcp", 2222, 2222, v4=["0.0.0.0/0"])]},
            {"IpPermissions": [perm("tcp", 2222, 2222, sg=["sg-0aaa"])]}]}
    else:
        doc = {"SecurityGroups": [{"IpPermissions": perms}]}
    got = {t for t in (jmespath.search(query, doc) or []) if t}
    if got != expected:
        print("FAIL: %s\n  expected %s\n  got      %s" % (name, expected or "{}", got or "{}"))
        fail += 1

if fail:
    sys.exit("%d security-group query case(s) failed" % fail)
print("OK the shipped JMESPath resolves every source kind and port shape")
PY

echo "== Case 21: a denied DescribeSecurityGroups is not an all-clear =="
# The dangerous direction. If the API call fails, the rule set is unknown, and
# unknown must not collapse into "no rule allows 2222".
mkdir -p "$TMP/bin"
cat >"$TMP/bin/aws" <<'EOF'
#!/bin/bash
# describe-instances succeeds; describe-security-groups is denied.
case "$2" in
  describe-instances) echo "sg-0e674f4e2937c6392"; exit 0 ;;
  *) echo "An error occurred (UnauthorizedOperation)" >&2; exit 254 ;;
esac
EOF
chmod +x "$TMP/bin/aws"
aws_run() {
  env -i PATH="$TMP/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
    HOST_AUDIT_CSF_CONF="$TMP/csf.conf" HOST_AUDIT_LFD_ACTIVE=1 \
    HOST_AUDIT_LISTENERS="22,2222" HOST_AUDIT_INSTANCE_ID="i-0118b8ede80b52ef7" \
    bash "$AUDIT" --json 2>/dev/null || true
}
[ "$(aws_run | verdict_for exposure/da-panel-sg)" = "SKIP" ] \
  || { echo "FAIL: a denied describe-security-groups must skip, not report closed" >&2; exit 1; }

# And when the call succeeds and the group really is world-open, it must fail.
cat >"$TMP/bin/aws" <<'EOF'
#!/bin/bash
case "$2" in
  describe-instances) echo "sg-0e674f4e2937c6392"; exit 0 ;;
  *) printf '0.0.0.0/0\tNone\tNone\tNone\n'; exit 0 ;;
esac
EOF
chmod +x "$TMP/bin/aws"
[ "$(aws_run | verdict_for exposure/da-panel-sg)" = "FAIL" ] \
  || { echo "FAIL: a successful query showing 0.0.0.0/0 must fail" >&2; exit 1; }
echo "OK an unreadable security group skips, and a readable open one fails"

echo "== Case 22: an installed key is a built path, not a hypothetical one =="
# The primary reported 14 shell accounts and no allowlist, which reads as a
# theoretical escalation. Twelve of those accounts already had authorized_keys,
# which is the same finding with the work already done. Counting shells without
# counting installed keys hides the difference.
mkdir -p "$TMP/homes/opsuser/.ssh" "$TMP/homes/site1/.ssh" "$TMP/homes/site2/.ssh" \
  "$TMP/homes/nokey" "$TMP/homes/daemon"
K1="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGuMHhVQ0Fh0OMwLIVGZ4iVQ5eXqIY4z5F1CQaGqQ0Xj op@example"
K2="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIB4TxV0kZ7l2yZ9v0X8y1KqQ8mFq4bN3sT6uW2eR5cPd site@example"
acct_passwd() { printf '%s' "$1" >"$TMP/passwd.accts"; }

# A lone operator key is the expected shape and must not warn.
printf '%s\n' "$K1" >"$TMP/homes/opsuser/.ssh/authorized_keys"
acct_passwd "opsuser:x:1001:1001::${TMP}/homes/opsuser:/bin/bash
daemonx:x:1002:1002::${TMP}/homes/daemon:/sbin/nologin
"
# No allowlist, which is the state this case is about: with one in force the
# question stops being how many files exist and becomes how many of them can
# still authenticate, which is case 23.
cat >"$TMP/no-allowlist" <<'EOF'
port 22
passwordauthentication no
kbdinteractiveauthentication no
usepam yes
permitrootlogin no
EOF

acct_run() {
  env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOST_AUDIT_SSHD_T_FILE="$TMP/no-allowlist" HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
    HOST_AUDIT_PASSWD="$TMP/passwd.accts" HOST_AUDIT_LISTENERS="22" \
    HOST_AUDIT_CSF_CONF="$TMP/csf.conf" HOST_AUDIT_LFD_ACTIVE=1 \
    HOST_AUDIT_INSTANCE_ID="i-000000000000000" \
    bash "$AUDIT" --json 2>/dev/null || true
}
out="$(acct_run)"
[ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "OK" ] \
  || { echo "FAIL: a single operator key should not warn" >&2; exit 1; }
printf '%s' "$out" | grep -q '"accounts/shells"' \
  || { echo "FAIL: shell count missing" >&2; exit 1; }

# A key on an account with no login shell must still be counted. On the primary,
# DirectAdmin's `admin` holds two keys and has no login shell, and a
# shell-filtered scan omitted it -- while nologin blocks only the interactive
# session, not `ssh -N -L` or sftp.
mkdir -p "$TMP/homes/daemon/.ssh"
printf '%s\n' "$K2" >"$TMP/homes/daemon/.ssh/authorized_keys"
out="$(acct_run)"
[ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "WARN" ] \
  || { echo "FAIL: a key on a nologin account must not be invisible" >&2; exit 1; }
printf '%s' "$out" | grep -q 'no login shell, which blocks the interactive session' \
  || { echo "FAIL: the nologin caveat should be stated, not silently dropped" >&2; exit 1; }
rm -f "$TMP/homes/daemon/.ssh/authorized_keys"

# Site accounts with keys are the reported shape, and must warn.
printf '%s\n' "$K1" >"$TMP/homes/site1/.ssh/authorized_keys"
printf '%s\n' "$K2" >"$TMP/homes/site2/.ssh/authorized_keys"
acct_passwd "opsuser:x:1001:1001::${TMP}/homes/opsuser:/bin/bash
site1:x:1003:1003::${TMP}/homes/site1:/bin/bash
site2:x:1004:1004::${TMP}/homes/site2:/bin/bash
nokey:x:1005:1005::${TMP}/homes/nokey:/bin/bash
daemonx:x:1002:1002::${TMP}/homes/daemon:/sbin/nologin
"
out="$(acct_run)"
[ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "WARN" ] \
  || { echo "FAIL: keys installed across site accounts must warn" >&2; exit 1; }
printf '%s' "$out" | grep -q '3 account(s) already hold' \
  || { echo "FAIL: should count the accounts that hold a key" >&2; exit 1; }
# One key everywhere and a key per account mean different things -- a template
# or a migration versus that many separate provisioning events -- so the
# distinct count has to be reported, not just the number of files.
if command -v ssh-keygen >/dev/null 2>&1; then
  printf '%s' "$out" | grep -q '2 distinct key' \
    || { echo "FAIL: distinct key count not reported" >&2; exit 1; }
  # K1 is on opsuser and site1, so the widest key opens 2 of the 3.
  printf '%s' "$out" | grep -q 'most widely installed of which is on 2 of them' \
    || { echo "FAIL: blast radius of the most-shared key not reported" >&2; exit 1; }

  # The shape the primary is actually in: one key on every account. Six keys
  # across fourteen accounts reads as unremarkable until one opens all fourteen,
  # so the widest count has to move even when the distinct count falls.
  printf '%s\n' "$K1" >"$TMP/homes/site2/.ssh/authorized_keys"
  out="$(acct_run)"
  printf '%s' "$out" | grep -q '1 distinct key' \
    || { echo "FAIL: one key templated across accounts should read as one key" >&2; exit 1; }
  printf '%s' "$out" | grep -q 'most widely installed of which is on 3 of them' \
    || { echo "FAIL: a single key on every account must report that radius" >&2; exit 1; }

  # A duplicate line within one file is one account, not two.
  printf '%s\n%s\n' "$K1" "$K1" >"$TMP/homes/site2/.ssh/authorized_keys"
  printf '%s' "$(acct_run)" | grep -q 'most widely installed of which is on 3 of them' \
    || { echo "FAIL: a repeated key in one file must not inflate its reach" >&2; exit 1; }
  printf '%s\n' "$K1" >"$TMP/homes/site2/.ssh/authorized_keys"
fi

# And no account names in the output: they are public already, so reprinting
# them here would add exposure without adding information.
printf '%s' "$out" | grep -qE 'site1|site2|opsuser' \
  && { echo "FAIL: account names must not be reprinted" >&2; exit 1; }

# An unreadable home must not read as an empty one. A .ssh is mode 700 and a
# DirectAdmin home is 711, so unprivileged both an absent key and a key nobody
# may look at test false -- and the answer was a clean "no account has one",
# a false all-clear on the check that says whether the escalation is built.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$TMP/homes/site1/.ssh"
  out="$(acct_run)"
  [ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "SKIP" ] \
    || { echo "FAIL: an unreadable .ssh must skip, not report no keys" >&2; exit 1; }
  printf '%s' "$out" | grep -q 'could not inspect 1 account' \
    || { echo "FAIL: the number of unreadable accounts should be named" >&2; exit 1; }
  chmod 700 "$TMP/homes/site1/.ssh"

  # The all-clear itself has to be unreachable while anything is unreadable.
  rm -f "$TMP/homes/opsuser/.ssh/authorized_keys" \
    "$TMP/homes/site1/.ssh/authorized_keys" "$TMP/homes/site2/.ssh/authorized_keys"
  chmod 000 "$TMP/homes/site1/.ssh"
  [ "$(acct_run | verdict_for accounts/authorized-keys)" = "SKIP" ] \
    || { echo "FAIL: no readable keys plus an unreadable home is not an all-clear" >&2; exit 1; }
  chmod 700 "$TMP/homes/site1/.ssh"
fi
echo "OK installed keys are counted, de-duplicated, never named, and never guessed"

echo "== Case 23: after an allowlist, most of those keys authenticate nothing =="
# The regression this case exists for: the primary applied `AllowGroups
# sshusers` and the audit went on reporting all 14 key files as "a working
# access path today", telling the operator to apply the control they had just
# applied. A finding whose remedy is already in place is how an audit trains
# someone to stop reading it.
#
# Both directions matter. Calling a refused key live is noise; calling a live
# key inert would be the audit vouching for access it never checked.
mkdir -p "$TMP/homes/ops2/.ssh"
printf '%s\n' "$K1" >"$TMP/homes/opsuser/.ssh/authorized_keys"
printf '%s\n' "$K1" >"$TMP/homes/site1/.ssh/authorized_keys"
printf '%s\n' "$K1" >"$TMP/homes/site2/.ssh/authorized_keys"
acct_passwd "opsuser:x:1001:1001::${TMP}/homes/opsuser:/bin/bash
site1:x:1003:1003::${TMP}/homes/site1:/bin/bash
site2:x:1004:1004::${TMP}/homes/site2:/bin/bash
"
cat >"$TMP/user-groups" <<'EOF'
opsuser:opsuser,sshusers
site1:site1
site2:site2
root:root
EOF

allow_run() {
  env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    HOST_AUDIT_SSHD_T_FILE="${1:-$TMP/hardened}" HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
    HOST_AUDIT_PASSWD="$TMP/passwd.accts" HOST_AUDIT_LISTENERS="22" \
    HOST_AUDIT_USER_GROUPS_FILE="$TMP/user-groups" \
    HOST_AUDIT_CSF_CONF="$TMP/csf.conf" HOST_AUDIT_LFD_ACTIVE=1 \
    HOST_AUDIT_INSTANCE_ID="i-000000000000000" \
    bash "$AUDIT" --json 2>/dev/null || true
}

out="$(allow_run)"
printf '%s' "$out" | grep -q 'admits 1 of them, so 2 cannot authenticate today' \
  || { echo "FAIL: refused accounts still counted as live access paths" >&2; exit 1; }
printf '%s' "$out" | grep -q 'latent rather than live' \
  || { echo "FAIL: the allowlist should reclassify those keys, not ignore them" >&2; exit 1; }

# The part an allowlist does not fix, and the part that is easiest to lose in
# the reclassification: one key on every account, including an admitted one,
# is still one private key that opens a session.
printf '%s' "$out" | grep -q 'most widely installed key is also on an admitted account' \
  || { echo "FAIL: a shared key on an admitted account must stay a live finding" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "WARN" ] \
  || { echo "FAIL: a live shared key is a finding whatever the allowlist says" >&2; exit 1; }

# Move the shared key off the admitted account: the reach caveat must go with
# it, because now no admitted account holds it.
printf '%s\n' "$K2" >"$TMP/homes/opsuser/.ssh/authorized_keys"
printf '%s' "$(allow_run)" | grep -q 'most widely installed key is also on an admitted account' \
  && { echo "FAIL: caveat fired for a key no admitted account holds" >&2; exit 1; }

# And an allowlist that admits nobody holding a key means no installed key
# authenticates anything -- the one shape that earns an OK here.
cat >"$TMP/user-groups" <<'EOF'
opsuser:opsuser
site1:site1
site2:site2
root:root
EOF
[ "$(allow_run | verdict_for accounts/authorized-keys)" = "OK" ] \
  || { echo "FAIL: keys nobody may authenticate with should not read as exposure" >&2; exit 1; }

# The unsafe direction: an allowlist that refuses nobody is not protection, and
# must not be reported as if it were.
cat >"$TMP/user-groups" <<'EOF'
opsuser:opsuser,sshusers
site1:site1,sshusers
site2:site2,sshusers
root:root
EOF
out="$(allow_run)"
[ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "WARN" ] \
  || { echo "FAIL: an allowlist admitting every key holder is not an all-clear" >&2; exit 1; }
printf '%s' "$out" | grep -q 'not narrowing anything here' \
  || { echo "FAIL: an allowlist that refuses nobody should be named as such" >&2; exit 1; }

# Unresolvable membership is not a refusal. Guessing here would hand out the
# same false all-clear the unreadable-home case already covers.
cat >"$TMP/user-groups" <<'EOF'
root:root
EOF
out="$(allow_run)"
[ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "WARN" ] \
  || { echo "FAIL: unresolved membership must not clear the finding" >&2; exit 1; }
printf '%s' "$out" | grep -q 'could not be resolved' \
  || { echo "FAIL: unresolved membership should be stated" >&2; exit 1; }
echo "OK installed keys are judged against what the allowlist actually admits"

echo "== Case 24: PermitRootLogin against an allowlist that excludes root =="
# sshd consults PermitRootLogin only for a connection the allowlist already let
# through, so `without-password` plus an AllowGroups without root is not a way
# in. Warning about it is a finding on a session that cannot happen -- and the
# coupling runs the other way too, so the reverse must still warn.
cat >"$TMP/root-key-only" <<'EOF'
port 22
passwordauthentication no
kbdinteractiveauthentication no
usepam yes
permitrootlogin without-password
allowgroups sshusers
EOF
cat >"$TMP/user-groups" <<'EOF'
opsuser:opsuser,sshusers
site1:site1
site2:site2
root:root
EOF
out="$(allow_run "$TMP/root-key-only")"
[ "$(printf '%s' "$out" | verdict_for ssh/root)" = "OK" ] \
  || { echo "FAIL: root cannot authenticate at all here; this is not a finding" >&2; exit 1; }
printf '%s' "$out" | grep -q 'prefer PermitRootLogin no as well' \
  || { echo "FAIL: the re-open-by-group-membership coupling should be stated" >&2; exit 1; }

# Put root in the allowed group and the same PermitRootLogin is live again.
cat >"$TMP/user-groups" <<'EOF'
opsuser:opsuser,sshusers
site1:site1
site2:site2
root:root,sshusers
EOF
out="$(allow_run "$TMP/root-key-only")"
[ "$(printf '%s' "$out" | verdict_for ssh/root)" = "WARN" ] \
  || { echo "FAIL: root in the allowed group makes PermitRootLogin live" >&2; exit 1; }
printf '%s' "$out" | grep -q 'admits root' \
  || { echo "FAIL: should name the allowlist as the reason this is live" >&2; exit 1; }

# With no allowlist there is nothing to weigh it against, and the original
# warning stands.
[ "$(run "$TMP/passwords-open" | verdict_for ssh/root)" = "WARN" ] \
  || { echo "FAIL: key-only root with no allowlist is still a finding" >&2; exit 1; }
echo "OK root login is judged on whether a root session can authenticate at all"

echo "== Case 25: AllowUsers wildcards must not expand against the filesystem =="
# OpenSSH permits `*` and `?` in AllowUsers (sshd_config(5)). The matcher used
# to iterate `for pat in $SSH_ALLOW_USERS` with pathname expansion on, so a
# pattern like `user*` run from a directory containing `userjunk` became the
# pathname `userjunk` before the case comparison -- and two key-bearing accounts
# that the pattern admits were reported as refused. That is a false all-clear
# on the check that says whether an installed key still authenticates.
mkdir -p "$TMP/homes/user01/.ssh" "$TMP/homes/user02/.ssh" "$TMP/globcwd"
printf '%s\n' "$K1" >"$TMP/homes/user01/.ssh/authorized_keys"
printf '%s\n' "$K1" >"$TMP/homes/user02/.ssh/authorized_keys"
# The pathname that would steal the pattern under an expanding for-loop.
touch "$TMP/globcwd/userjunk"
acct_passwd "user01:x:1101:1101::${TMP}/homes/user01:/bin/bash
user02:x:1102:1102::${TMP}/homes/user02:/bin/bash
"
cat >"$TMP/user-groups" <<'EOF'
user01:user01
user02:user02
root:root
EOF
cat >"$TMP/allow-wildcard" <<'EOF'
port 22
passwordauthentication no
kbdinteractiveauthentication no
usepam yes
permitrootlogin no
allowusers user*
EOF
# cwd is the trap: without set -f the pattern expands here before matching.
out="$(
  cd "$TMP/globcwd" &&
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
      HOST_AUDIT_SSHD_T_FILE="$TMP/allow-wildcard" HOST_AUDIT_SSHD_CONFIG="$TMP/sshd_config.plain" \
      HOST_AUDIT_PASSWD="$TMP/passwd.accts" HOST_AUDIT_LISTENERS="22" \
      HOST_AUDIT_USER_GROUPS_FILE="$TMP/user-groups" \
      HOST_AUDIT_CSF_CONF="$TMP/csf.conf" HOST_AUDIT_LFD_ACTIVE=1 \
      HOST_AUDIT_INSTANCE_ID="i-000000000000000" \
      bash "$AUDIT" --json 2>/dev/null || true
)"
[ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "WARN" ] \
  || { echo "FAIL: AllowUsers user* must still admit user01/user02 when cwd has userjunk" >&2; exit 1; }
printf '%s' "$out" | grep -q 'not narrowing anything here\|admits 2 of them' \
  || { echo "FAIL: both wildcard matches should still count as live" >&2; exit 1; }
# And the pattern itself must still match -- a set -f that also broke case
# matching would refuse everyone and look like the bug from the other side.
printf '%s' "$out" | grep -q 'admits none of them' \
  && { echo "FAIL: set -f must not stop the wildcard matching the account name" >&2; exit 1; }
echo "OK AllowUsers wildcards match account names, not pathnames in cwd"

echo "== Case 26: every fingerprint tied for widest reach must be tested =="
# Two keys on the same number of accounts, one only on refused accounts and one
# on an admitted account. Taking `head -1` after sorting by count keeps an
# arbitrary member of the tie; if that member is the refused-only key, the
# live one is never checked against fps_live and the reach caveat is silently
# dropped. Preserve and test every fingerprint at the maximum count.
mkdir -p "$TMP/homes/site3/.ssh"
printf '%s\n' "$K2" >"$TMP/homes/opsuser/.ssh/authorized_keys"   # admitted
printf '%s\n' "$K1" >"$TMP/homes/site1/.ssh/authorized_keys"     # refused
printf '%s\n' "$K1" >"$TMP/homes/site2/.ssh/authorized_keys"     # refused
printf '%s\n' "$K2" >"$TMP/homes/site3/.ssh/authorized_keys"     # refused
acct_passwd "opsuser:x:1001:1001::${TMP}/homes/opsuser:/bin/bash
site1:x:1003:1003::${TMP}/homes/site1:/bin/bash
site2:x:1004:1004::${TMP}/homes/site2:/bin/bash
site3:x:1005:1005::${TMP}/homes/site3:/bin/bash
"
cat >"$TMP/user-groups" <<'EOF'
opsuser:opsuser,sshusers
site1:site1
site2:site2
site3:site3
root:root
EOF
# Both keys are on exactly 2 accounts. K1 is refused-only; K2 is on the
# admitted opsuser. Either one could be head -1 depending on fingerprint order.
out="$(allow_run)"
printf '%s' "$out" | grep -q 'most widely installed of which is on 2 of them' \
  || { echo "FAIL: tied keys should both count as widest" >&2; exit 1; }
printf '%s' "$out" | grep -q 'most widely installed key is also on an admitted account' \
  || { echo "FAIL: a tied live key must not be silenced by a tied refused-only peer" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for accounts/authorized-keys)" = "WARN" ] \
  || { echo "FAIL: a live shared key among a tie is still a finding" >&2; exit 1; }
echo "OK every fingerprint at the maximum reach is tested, not just one of a tie"

echo "PASS: host access audit proofs (26 cases)"
