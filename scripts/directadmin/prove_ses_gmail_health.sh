#!/bin/bash
# Offline proofs for ses_gmail_forward_health.sh.
#
# The check that matters most here is the one that catches an address piping into the
# forwarder without a matching config entry. Whether that loses the message depends on
# whether the local-part has a mailbox: DA's virtual_forwarder sets unseen= when it does, so
# the Maildir gets a copy and only the Gmail copy is missing. With no mailbox the pipe is the
# whole delivery, the unallowlisted recipient is declined, and the pipe exits 0 -- so Exim
# marks the message delivered and nobody is told. Both halves need asserting: failing on the
# first would page someone about a healthy host, and passing the second would lose mail
# quietly. Nothing else in the health script can see either.
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
    # DA's virtual_forwarder only sets unseen (and so only gives the Maildir a copy) when
    # the local-part is in passwd, which is what decides whether a declined address merely
    # misses Gmail or loses the message outright.
    printf 'brian:x:::::\nbteller:x:::::\n' >"${SANDBOX}/virtual/${domain}/passwd"
  done
}

# add_alias <domain> <localpart> [mailbox]
add_alias() {
  echo "$2: ${PIPE}" >>"${SANDBOX}/virtual/$1/aliases"
  [[ "${3:-}" == "mailbox" ]] && printf '%s:x:::::\n' "$2" >>"${SANDBOX}/virtual/$1/passwd"
  return 0
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
  # The whole log, not just the failure line: NOTE lines are how this check reports the
  # cases it deliberately does not fail on, and those need asserting too.
  reasons="$(cat "${SANDBOX}/health.log" 2>/dev/null)"
  printf 'exit=%s\n%s\n%s\n' "$code" "$reasons" "$out"
}

echo "a clean host (the baseline these proofs are measured against)"
reset_fixtures
result="$(run_health)"
assert_contains "a host whose aliases match the config passes" "$result" "exit=0"
assert_lacks "with no complaint about unmanaged aliases" "$result" "pipe_alias_no_mailbox"
assert_lacks "and none about the managed ones either" "$result" "bad_alias"

echo
echo "a stale local-part with no mailbox (the pipe is the whole delivery: mail is lost)"
reset_fixtures
add_alias tellerstech.example sales
result="$(run_health)"
assert_contains "the stale address is reported as losing mail" "$result" "pipe_alias_no_mailbox:sales@tellerstech.example"
assert_contains "and the check fails" "$result" "exit=1"
assert_lacks "the managed addresses on that same domain are not reported" "$result" "brian@tellerstech.example"
assert_that "the domain itself is in the config, which is what per-domain checking would hide behind" \
  "$(grep -q '^tellerstech.example ' "${SANDBOX}/managed.conf" && echo yes || echo no)"

echo
echo "a stale local-part that does have a mailbox (only the Gmail copy is missing)"
reset_fixtures
add_alias tellerstech.example sales mailbox
result="$(run_health)"
assert_contains "it is reported as a NOTE naming the address" "$result" "NOTE piped but not forwarded, mailbox still receives: sales@tellerstech.example"
assert_lacks "not as a lost-mail failure, because unseen= gave the Maildir a copy" "$result" "pipe_alias_no_mailbox"
assert_contains "so the check still passes" "$result" "exit=0"

echo
echo "a whole unmanaged domain carrying the pipe (a real directory, not a pointer)"
reset_fixtures
mkdir -p "${SANDBOX}/virtual/origin.cdn.example"
{
  echo '*: :fail:'
  echo "brian: ${PIPE}"
  echo "bteller: ${PIPE}"
} >"${SANDBOX}/virtual/origin.cdn.example/aliases"
result="$(run_health)"
assert_contains "both of its addresses are reported" "$result" "pipe_alias_no_mailbox:brian@origin.cdn.example"
assert_contains "not just the first one found" "$result" "pipe_alias_no_mailbox:bteller@origin.cdn.example"
assert_contains "and the check fails" "$result" "exit=1"

echo
echo "false positives (a check that cries wolf gets switched off)"
reset_fixtures
echo "#old: ${PIPE}" >>"${SANDBOX}/virtual/wbat.example/aliases"
result="$(run_health)"
assert_lacks "a commented-out pipe alias is not a live delivery path" "$result" "pipe_alias_no_mailbox"
assert_contains "so the host still passes" "$result" "exit=0"

reset_fixtures
sed -i "s|^brian: |  brian : |" "${SANDBOX}/virtual/wbat.example/aliases"
result="$(run_health)"
assert_lacks "whitespace around a managed local-part does not make it look unmanaged" "$result" "brian@wbat.example"

reset_fixtures
{
  echo '*: :fail:'
  echo 'info: someone@elsewhere.example'
} >"${SANDBOX}/virtual/wbat.example/aliases"
result="$(run_health)"
assert_lacks "a plain forwarder with no pipe is not reported at all" "$result" "info@wbat.example"

echo
echo "a DirectAdmin domain pointer (one aliases file, two recipient identities)"
# DA points a domain at another by symlinking the whole directory, so the same aliases and
# passwd are read under each name. localpart@pointer is a recipient Exim accepts in its own
# right and allowlists separately, so it belongs in the comparison -- but it shares the
# target's passwd, so it has a mailbox and loses nothing. Reporting it as lost mail would be
# a permanent false alarm; hiding it entirely would mask a pointer with no mailbox.
reset_fixtures
ln -s tellerstech.example "${SANDBOX}/virtual/origin.cdn.example"
assert_that "the fixture really is a symlink to the target domain" \
  "$([[ -L "${SANDBOX}/virtual/origin.cdn.example" ]] && echo yes || echo no)"
assert_that "and both names reach one inode" \
  "$([[ "$(stat -c %i "${SANDBOX}/virtual/origin.cdn.example/aliases")" == "$(stat -c %i "${SANDBOX}/virtual/tellerstech.example/aliases")" ]] && echo yes || echo no)"
result="$(run_health)"
assert_contains "the pointer's addresses are still seen, as a NOTE" "$result" "NOTE piped but not forwarded, mailbox still receives: brian@origin.cdn.example"
assert_lacks "and not called lost mail, because the shared passwd gives them mailboxes" "$result" "pipe_alias_no_mailbox"
assert_contains "so a host with a pointer domain still passes" "$result" "exit=0"

# A pointer whose local-part has no mailbox is the case that must still fail: the shared
# aliases pipe it, nothing gives it a Maildir, and the message is gone.
add_alias tellerstech.example sales
result="$(run_health)"
assert_contains "a mailbox-less local-part is caught on the real domain" "$result" "pipe_alias_no_mailbox:sales@tellerstech.example"
assert_contains "and again at the pointer, which is a separate recipient" "$result" "pipe_alias_no_mailbox:sales@origin.cdn.example"
assert_contains "so the check fails" "$result" "exit=1"

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
assert_lacks "nor report a nonexistent address" "$result" "pipe_alias_no_mailbox:"

reset_fixtures
rm -f "${SANDBOX}/managed.conf"
result="$(run_health)"
assert_lacks "a missing desired-state file reports nothing rather than everything" "$result" "pipe_alias_no_mailbox"
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
  assert_lacks "comparing domains is what would miss the stale address" "$result" "pipe_alias_no_mailbox"
  assert_contains "and would call the host healthy while it discards mail" "$result" "exit=0"
else
  assert_that "the mutation target still exists" no
fi

# The mailbox test is the other half. Treating every declined address as lost mail is the
# version that would page someone every five minutes about a pointer domain that is fine.
mutant2="${SANDBOX}/mutant-ignores-mailbox.sh"
if python3 - "$SCRIPT" "$mutant2" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '      if [[ -f "$passwd_file" ]] && grep -qE "^${lp}:" "$passwd_file" 2>/dev/null; then\n'
if old not in text:
    sys.exit(1)
open(dst, "w").write(text.replace(old, "      if false; then\n", 1))
PY
then
  assert_that "the mailbox test is still there to remove" yes
  reset_fixtures
  ln -s tellerstech.example "${SANDBOX}/virtual/origin.cdn.example"
  result="$(run_health "$mutant2")"
  assert_contains "without it a pointer domain is called lost mail" "$result" "pipe_alias_no_mailbox:brian@origin.cdn.example"
  assert_contains "which would fail the check on a healthy host, every five minutes" "$result" "exit=1"
  assert_that "while the real script passes the same fixture" \
    "$(case "$(run_health)" in *exit=0*) echo yes ;; *) echo no ;; esac)"
else
  assert_that "the mailbox test is still there to remove" no
fi

echo
echo "----------------------------------------"
echo "passed ${passed}, failed ${failed}"
[[ "$failed" -eq 0 ]] || exit 1
echo "PASS: offline ses-gmail-forward health proofs"
