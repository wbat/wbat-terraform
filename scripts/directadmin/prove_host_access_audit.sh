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
# Usage (from repo root):
#   ./scripts/directadmin/prove_host_access_audit.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AUDIT="${ROOT}/scripts/directadmin/host_access_audit.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

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
echo "OK hardened config reports clean on every SSH check"

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
printf 'brute_force_log_scanner=1\nbrute_force_scan_apache_logs=0\nnginx=1\n' >"$TMP/da.nginx"
out="$(HOST_AUDIT_SSHD_T_FILE="$TMP/hardened" HOST_AUDIT_DA_CONF="$TMP/da.nginx" \
  bash "$AUDIT" --json 2>/dev/null || true)"
[ "$(printf '%s' "$out" | verdict_for da/brute-force)" = "OK" ] \
  || { echo "FAIL: enabled scanner masked by an irrelevant disabled key" >&2; exit 1; }
[ "$(printf '%s' "$out" | verdict_for da/brute-force-disabled)" = "MISSING" ] \
  || { echo "FAIL: apache log scanning should not be a finding on nginx" >&2; exit 1; }
echo "OK the scanner's own state is the verdict"

echo "PASS: host access audit proofs (16 cases)"
