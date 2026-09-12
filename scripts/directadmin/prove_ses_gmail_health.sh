#!/bin/bash
# Offline proofs for ses_gmail_forward_health.sh.
#
# The check that matters most here is the one that catches an address piping into the
# forwarder without a matching config entry. That address loses mail outright -- the alias
# replaces mailbox delivery, the pipe declines an unallowlisted recipient, and it exits 0,
# so Exim marks the message delivered and nobody is told. Nothing else in the health script
# can see it, which is why it needs assertions of its own.
#
# Runs entirely on fixtures under a sandbox: every path the script reads is overridable by
# environment variable, including the virtual-domain root.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/ses_gmail_forward_health.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

PIPE='"|/usr/local/bin/ses-gmail-forward.py"'
passed=0
failed=0

assert_that() {
  local what="$1" cond="$2"
  if [[ "$cond" == "yes" ]]; then
    echo "  OK   $what"
    passed=$((passed + 1))
  else
    echo "  FAIL $what"
    failed=$((failed + 1))
  fi
}

assert_contains() {
  local what="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then assert_that "$what" yes; else assert_that "$what" no; fi
}

assert_lacks() {
  local what="$1" haystack="$2" needle="$3"
  if [[ "$haystack" != *"$needle"* ]]; then assert_that "$what" yes; else assert_that "$what" no; fi
}

# A fake boto3 on PYTHONPATH, so the dependency check does not fail every case for a
# reason none of these proofs are about.
PYLIB="${SANDBOX}/pylib"
mkdir -p "$PYLIB"
echo "" >"${PYLIB}/boto3.py"

# The enforcer is stubbed: it hardcodes /etc/virtual, so running the real one here would
# reach outside the sandbox, and check 3 is not what is under test.
ENSURE_STUB="${SANDBOX}/ensure-stub.sh"
printf '#!/bin/bash\nexit 0\n' >"$ENSURE_STUB"
chmod 755 "$ENSURE_STUB"

FORWARD_STUB="${SANDBOX}/ses-gmail-forward.py"
printf '#!/usr/bin/env python3\n' >"$FORWARD_STUB"
chmod 755 "$FORWARD_STUB"

# reset_fixtures [managed.conf contents]
reset_fixtures() {
  rm -rf "${SANDBOX}/virtual" "${SANDBOX}/state" "${SANDBOX}/health.log" "${SANDBOX}/forward.log"
  mkdir -p "${SANDBOX}/virtual" "${SANDBOX}/state"
  : >"${SANDBOX}/forward.log"
  cat >"${SANDBOX}/managed.conf" <<'EOF'
# domain localpart[,localpart...]
tellerstech.example brian,bteller
wbat.example brian,bteller
EOF
  for domain in tellerstech.example wbat.example; do
    mkdir -p "${SANDBOX}/virtual/${domain}"
    {
      echo '*: :fail:'
      echo "brian: ${PIPE}"
      echo "bteller: ${PIPE}"
    } >"${SANDBOX}/virtual/${domain}/aliases"
  done
}

# run_health [script] -> prints "exit=<code>" then the reasons line
run_health() {
  local script="${1:-$SCRIPT}" out code reasons
  out="$(
    SES_GMAIL_HEALTH_CONF="${SANDBOX}/absent-health.conf" \
      SES_GMAIL_HEALTH_LOG="${SANDBOX}/health.log" \
      SES_GMAIL_FORWARD_LOG="${SANDBOX}/forward.log" \
      SES_GMAIL_FORWARD_SCRIPT="$FORWARD_STUB" \
      ENSURE_SES_GMAIL_ALIASES="$ENSURE_STUB" \
      SES_GMAIL_HEALTH_STATE="${SANDBOX}/state" \
      SES_GMAIL_ALIASES_CONF="${SANDBOX}/managed.conf" \
      SES_GMAIL_VIRTUAL_ROOT="${SANDBOX}/virtual" \
      PYTHONPATH="$PYLIB" \
      bash "$script" 2>&1
  )"
  code=$?
  reasons="$(grep -h 'HEALTH FAIL' "${SANDBOX}/health.log" 2>/dev/null | tail -1)"
  printf 'exit=%s\n%s\n%s\n' "$code" "$reasons" "$out"
}

echo "a clean host (the baseline these proofs are measured against)"
reset_fixtures
result="$(run_health)"
assert_contains "a host whose aliases match the config passes" "$result" "exit=0"
assert_lacks "with no complaint about unmanaged aliases" "$result" "unmanaged_pipe_alias"
assert_lacks "and none about the managed ones either" "$result" "bad_alias"

echo
echo "a stale local-part beside two managed ones (per-domain checking misses this)"
reset_fixtures
echo "sales: ${PIPE}" >>"${SANDBOX}/virtual/tellerstech.example/aliases"
result="$(run_health)"
assert_contains "the stale address is reported" "$result" "unmanaged_pipe_alias:sales@tellerstech.example"
assert_contains "and the check fails" "$result" "exit=1"
assert_lacks "the managed addresses on that same domain are not reported" "$result" "unmanaged_pipe_alias:brian@tellerstech.example"
assert_that "the domain itself is in the config, which is what would hide this" \
  "$(grep -q '^tellerstech.example ' "${SANDBOX}/managed.conf" && echo yes || echo no)"

echo
echo "a whole unmanaged domain carrying the pipe (the origin.aws case)"
reset_fixtures
mkdir -p "${SANDBOX}/virtual/origin.cdn.example"
{
  echo '*: :fail:'
  echo "brian: ${PIPE}"
  echo "bteller: ${PIPE}"
} >"${SANDBOX}/virtual/origin.cdn.example/aliases"
result="$(run_health)"
assert_contains "both of its addresses are reported" "$result" "unmanaged_pipe_alias:brian@origin.cdn.example"
assert_contains "not just the first one found" "$result" "unmanaged_pipe_alias:bteller@origin.cdn.example"
assert_contains "and the check fails" "$result" "exit=1"

echo
echo "false positives (a check that cries wolf gets switched off)"
reset_fixtures
echo "#old: ${PIPE}" >>"${SANDBOX}/virtual/wbat.example/aliases"
result="$(run_health)"
assert_lacks "a commented-out pipe alias is not a live delivery path" "$result" "unmanaged_pipe_alias"
assert_contains "so the host still passes" "$result" "exit=0"

reset_fixtures
sed -i "s|^brian: |  brian : |" "${SANDBOX}/virtual/wbat.example/aliases"
result="$(run_health)"
assert_lacks "whitespace around a managed local-part does not make it look unmanaged" "$result" "unmanaged_pipe_alias"

reset_fixtures
{
  echo '*: :fail:'
  echo 'info: someone@elsewhere.example'
} >"${SANDBOX}/virtual/wbat.example/aliases"
result="$(run_health)"
assert_lacks "a plain forwarder with no pipe is not reported as unmanaged" "$result" "unmanaged_pipe_alias"

echo
echo "check 5 still works (the reverse direction, after rerooting it)"
reset_fixtures
sed -i "s|^bteller: .*|bteller: someone@elsewhere.example|" "${SANDBOX}/virtual/wbat.example/aliases"
result="$(run_health)"
assert_contains "a managed address that lost its pipe is reported" "$result" "bad_alias:wbat.example:bteller"
assert_contains "and the check fails" "$result" "exit=1"
# Matching the literal text of the script, not expanding it.
# shellcheck disable=SC2016
assert_that "the reroot is what makes that assertion possible" \
  "$(grep -q 'VIRTUAL_ROOT}/\${domain}/aliases' "$SCRIPT" && echo yes || echo no)"

echo
echo "degenerate inputs (cron runs this unattended; a crash is silence)"
reset_fixtures
rm -rf "${SANDBOX}/virtual"
mkdir -p "${SANDBOX}/virtual"
result="$(run_health)"
assert_lacks "an empty virtual root does not glob a literal path into awk" "$result" "No such file"
assert_lacks "nor report a nonexistent address" "$result" "unmanaged_pipe_alias:"

reset_fixtures
rm -f "${SANDBOX}/managed.conf"
result="$(run_health)"
assert_lacks "a missing desired-state file reports nothing rather than everything" "$result" "unmanaged_pipe_alias"
assert_lacks "and does not crash" "$result" "unbound variable"

echo
echo "negative value: this check is load-bearing"
mutant="${SANDBOX}/mutant-per-domain.sh"
# Write a copy of the real script that compares domains instead of addresses -- the flaw
# this check was written to avoid. Exits nonzero if that line has moved, because a mutant
# that no longer mutates makes the assertions below pass for free.
if python3 - "$SCRIPT" "$mutant" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = 'done < <(comm -23 <(printf \'%s\\n\' "$piped_addrs") <(printf \'%s\\n\' "$managed_addrs"))'
new = (
    'done < <(comm -23 <(printf \'%s\\n\' "$piped_addrs" | sed \'s/^[^@]*@//\' | sort -u) '
    '<(printf \'%s\\n\' "$managed_addrs" | sed \'s/^[^@]*@//\' | sort -u))'
)
if old not in text:
    sys.exit(1)
open(dst, "w").write(text.replace(old, new))
PY
then
  assert_that "the mutation target still exists" yes
  reset_fixtures
  echo "sales: ${PIPE}" >>"${SANDBOX}/virtual/tellerstech.example/aliases"
  result="$(run_health "$mutant")"
  assert_lacks "comparing domains is what would miss the stale address" "$result" "unmanaged_pipe_alias"
  assert_contains "and would call the host healthy while it discards mail" "$result" "exit=0"
else
  assert_that "the mutation target still exists" no
fi

echo
echo "----------------------------------------"
echo "passed ${passed}, failed ${failed}"
[[ "$failed" -eq 0 ]] || exit 1
echo "PASS: offline ses-gmail-forward health proofs"
