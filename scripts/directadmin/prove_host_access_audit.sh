#!/bin/bash
# Offline proof that host_access_audit.sh classifies SSH password exposure
# correctly, including the case that motivates the check.
#
# The interesting one is case 3: PasswordAuthentication is "no", which is what
# an operator greps for and what most hardening guides stop at, while PAM
# keyboard-interactive still accepts passwords. The box stays brute-forceable
# and the config reads as hardened. An audit that misses this is worse than
# none, so it is worth a test rather than trust.
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

echo "PASS: host access audit SSH classification proofs"
