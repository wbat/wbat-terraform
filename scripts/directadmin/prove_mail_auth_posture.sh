#!/bin/bash
# Offline proofs for mail_auth_posture.sh.
#
# Two things here are worth more than the rest.
#
# The first is that a domain gets examined at all. /etc/virtual/domainowners is `domain: user`,
# so the domain field carries a trailing colon, and forgetting to strip it turns every zone
# path into a miss. The failure mode is not an error -- the sweep finds nothing and prints a
# tidy "zones examined: 0", which reads exactly like a host with nothing to fix. An earlier
# ad-hoc version of this audit shipped with that bug and reported a clean result for 97
# domains. So the count is asserted to be non-zero, and a mutant that drops the strip is
# asserted to break it.
#
# The second is the UNAUTHORIZED verdict, which is the whole reason this is not a grep for
# `_dmarc`. A DMARC record whose rua sits on a domain that does not publish
# `<policy>._report._dmarc.<rua>` collects nothing, while looking configured. Both directions
# need asserting: missing the finding leaves reporting silently dead, and raising it for a
# same-domain rua would send someone chasing an authorization record that is not required.
#
# Runs entirely on fixtures. DNS is injected through MAIL_AUTH_RESOLVER, so no lookup leaves
# the machine and the authorized/unauthorized split is decided by the fixture, not the network.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${HERE}/mail_auth_posture.sh"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

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

# One domain's table row. Needed because the summary prints the literal "rua UNAUTHORIZED:"
# counter, so asserting a domain is *not* flagged has to look at that domain's row rather
# than the whole output -- otherwise the label alone satisfies the search and the assertion
# can never pass, which is how the first draft of this file "passed" four checks it wasn't
# making.
row_for() {
  printf '%s\n' "$1" | awk -v d="$2" '$1 == d { print; exit }'
}

ZONES="${SANDBOX}/named"
VIRTUAL="${SANDBOX}/virtual"
OWNERS="${SANDBOX}/domainowners"

# A resolver that answers only for the names listed in $SANDBOX/authorized. This is what
# makes the authorized/unauthorized split a property of the fixture instead of the network.
RESOLVER="${SANDBOX}/resolver.sh"
cat >"$RESOLVER" <<'EOF'
#!/bin/bash
grep -qxF "$1" "${SANDBOX_AUTH_LIST}" 2>/dev/null && echo '"v=DMARC1;"'
exit 0
EOF
chmod 755 "$RESOLVER"
export SANDBOX_AUTH_LIST="${SANDBOX}/authorized"

# add_domain <domain> <user> [--dmarc <txt>] [--spf] [--mbox] [--pointer <target>]
#                            [--dkim] [--dkim-other] [--dkim-key]
#
# --dkim publishes the selector Exim signs with, --dkim-other a third party's, and
# --dkim-key drops the private key on disk. They are separate because every combination of
# the two is a distinct real state, and only the pair means DKIM works.
add_domain() {
  local domain="$1" user="$2"
  shift 2
  local dmarc="" spf=0 dkim=0 dkim_other=0 dkim_key=0 mbox=0 pointer=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dmarc)
        shift
        dmarc="$1"
        ;;
      --spf) spf=1 ;;
      --dkim) dkim=1 ;;
      --dkim-other) dkim_other=1 ;;
      --dkim-key) dkim_key=1 ;;
      --mbox) mbox=1 ;;
      --pointer)
        shift
        pointer="$1"
        ;;
    esac
    shift
  done

  # The colon is the point: this is the real file format.
  echo "${domain}: ${user}" >>"$OWNERS"

  {
    echo "\$TTL 3600"
    echo "@	IN	SOA	ns1.example.com. root.example.com. ( 1 1h 15m 1w 1h )"
    [[ "$spf" -eq 1 ]] && echo '@	IN	TXT	"v=spf1 a mx ~all"'
    [[ "$dkim" -eq 1 ]] && echo 'x._domainkey	IN	TXT	"v=DKIM1; k=rsa; p=MIIB"'
    [[ "$dkim_other" -eq 1 ]] && echo 's1._domainkey	IN	TXT	"v=DKIM1; k=rsa; p=MIIB"'
    [[ -n "$dmarc" ]] && echo "$dmarc"
    echo 'www	IN	A	192.0.2.1'
  } >"${ZONES}/${domain}.db"

  if [[ -n "$pointer" ]]; then
    ln -sfn "$pointer" "${VIRTUAL}/${domain}"
  else
    mkdir -p "${VIRTUAL}/${domain}"
    [[ "$mbox" -eq 1 ]] && printf 'brian:x:::::\n' >"${VIRTUAL}/${domain}/passwd"
    [[ "$dkim_key" -eq 1 ]] && echo 'PRIVATE' >"${VIRTUAL}/${domain}/dkim.private.key"
  fi
  return 0
}

reset_fixtures() {
  rm -rf "$ZONES" "$VIRTUAL" "$OWNERS" "$SANDBOX_AUTH_LIST"
  mkdir -p "$ZONES" "$VIRTUAL"
  : >"$OWNERS"
  : >"$SANDBOX_AUTH_LIST"
}

# run_audit [args...]
run_audit() {
  local out code
  out="$(
    MAIL_AUTH_DOMAINOWNERS="$OWNERS" \
      MAIL_AUTH_ZONE_DIR="$ZONES" \
      MAIL_AUTH_VIRTUAL_ROOT="$VIRTUAL" \
      MAIL_AUTH_RESOLVER="$RESOLVER" \
      bash "$SCRIPT" "$@" 2>&1
  )"
  code=$?
  printf 'exit=%s\n%s\n' "$code" "$out"
}

echo "the trailing colon in domainowners, which is what silently zeroes the sweep"
reset_fixtures
add_domain live.example alice --spf --dkim --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:dmarc@live.example"'
result="$(run_audit)"
assert_lacks "a domain in the real 'domain: user' format is not skipped" "$result" "zones examined:        0"
assert_contains "it is counted" "$result" "zones examined:        1"
assert_contains "and named in the table" "$result" "live.example"

echo
echo "a rua on the policy domain is not external and needs no authorization"
assert_contains "reported as local" "$(row_for "$result" live.example)" "local"
assert_lacks "not flagged UNAUTHORIZED" "$(row_for "$result" live.example)" "UNAUTHORIZED"
assert_contains "and none counted" "$result" "rua UNAUTHORIZED:      0"
assert_lacks "no finding raised" "$result" "rua_unauthorized"

echo
echo "an external rua that the receiving domain does authorize"
reset_fixtures
add_domain ext.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:tok@reports.example"'
echo "ext.example._report._dmarc.reports.example" >"$SANDBOX_AUTH_LIST"
result="$(run_audit)"
assert_contains "reported as authorized" "$(row_for "$result" ext.example)" "authorized"
assert_lacks "not UNAUTHORIZED" "$(row_for "$result" ext.example)" "UNAUTHORIZED"
assert_contains "the lookup is the exact RFC 7489 name" "$(cat "$SANDBOX_AUTH_LIST")" "ext.example._report._dmarc.reports.example"

echo
echo "an external rua that it does not -- the finding a presence check cannot make"
reset_fixtures
add_domain silent.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:someone@gmail.com"'
result="$(run_audit)"
assert_contains "the record is still seen as present" "$result" "silent.example"
assert_contains "but the destination is UNAUTHORIZED" "$result" "UNAUTHORIZED"
assert_contains "counted" "$result" "rua UNAUTHORIZED:      1"
assert_contains "and named with its destination" "$result" "rua_unauthorized:silent.example->gmail.com"
assert_lacks "not reported as missing DMARC, which it is not" "$result" "no_dmarc_has_mail:silent.example"

echo
echo "--strict keys on that finding and nothing else"
assert_contains "default run still exits 0, so cron stays quiet" "$result" "exit=0"
assert_contains "--strict exits 1 on an unauthorized rua" "$(run_audit --strict)" "exit=1"
reset_fixtures
add_domain plain.example alice --spf --mbox
result_missing="$(run_audit --strict)"
assert_contains "--strict does not fail merely for a missing record" "$result_missing" "exit=0"
assert_contains "which is still reported" "$result_missing" "no_dmarc_has_mail:plain.example"

echo
echo "--no-dns cannot decide the split, and must not guess"
reset_fixtures
add_domain silent.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:someone@gmail.com"'
result="$(run_audit --no-dns)"
assert_contains "left explicitly undecided" "$(row_for "$result" silent.example)" "external?"
assert_lacks "not claimed authorized" "$(row_for "$result" silent.example)" "authorized"
assert_lacks "nor claimed unauthorized" "$(row_for "$result" silent.example)" "UNAUTHORIZED"
assert_contains "so --strict has nothing to fail on" "$(run_audit --no-dns --strict)" "exit=0"

echo
echo "record shapes that appear in real DirectAdmin zones"
reset_fixtures
add_domain fqdn.example alice --spf --mbox \
  --dmarc '_dmarc.fqdn.example.	3600	IN	TXT	"v=DMARC1; p=none; rua=mailto:d@fqdn.example"'
result="$(run_audit)"
assert_contains "a fully qualified _dmarc owner name is parsed" "$result" "local"
assert_lacks "not treated as absent" "$result" "no_dmarc_has_mail:fqdn.example"

reset_fixtures
add_domain split.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; " "rua=mailto:d@split.example"'
result="$(run_audit)"
assert_contains "a TXT split across quoted strings is joined before parsing" "$result" "local"

reset_fixtures
add_domain sized.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:tok@reports.example!10m"'
echo "sized.example._report._dmarc.reports.example" >"$SANDBOX_AUTH_LIST"
result="$(run_audit)"
assert_contains "an rua !size limit is stripped from the domain" "$result" "authorized"

reset_fixtures
add_domain multi.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:d@multi.example,mailto:x@gmail.com"'
result="$(run_audit)"
assert_contains "each destination is classified separately" "$result" "local,UNAUTHORIZED"
assert_contains "and only the external one is a finding" "$result" "rua_unauthorized:multi.example->gmail.com"

reset_fixtures
add_domain norua.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=reject"'
result="$(run_audit)"
assert_contains "a record with no rua at all is called out" "$result" "dmarc_without_rua:norua.example"
assert_lacks "and not counted as unauthorized" "$result" "rua UNAUTHORIZED:      1"

echo
echo "a domain pointer shares the target's passwd, so it must not read as its own backlog item"
reset_fixtures
add_domain real.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:d@real.example"'
add_domain ptr.example alice --spf --pointer real.example
result="$(run_audit)"
assert_contains "flagged as a pointer" "$result" "ptr.example"
assert_contains "counted as one" "$result" "domain pointers:       1"
assert_lacks "not listed as a domain needing DMARC" "$result" "no_dmarc_has_mail:ptr.example"
assert_lacks "nor as one without mail" "$result" "no_dmarc_no_mail:ptr.example"

echo
echo "SPF, and the parked case"
reset_fixtures
add_domain bare.example alice
add_domain full.example alice --spf --dkim --dkim-key --mbox
result="$(run_audit)"
assert_contains "a zone with no SPF is counted" "$result" "missing SPF:           1"
assert_contains "a parked domain with no mailboxes is still reported" "$result" "no_dmarc_no_mail:bare.example"
assert_contains "separately from one with mail" "$result" "no_dmarc_has_mail:full.example"

echo
echo "DKIM is the key and the record together, because either alone is its own failure"
reset_fixtures
add_domain works.example alice --spf --mbox --dkim --dkim-key
result="$(run_audit)"
assert_contains "key plus published selector is the only state that signs" "$(row_for "$result" works.example)" "signing"
assert_contains "counted" "$result" "DKIM signing:          1"
assert_lacks "and raises nothing" "$result" "dkim_"

reset_fixtures
add_domain unsigned.example alice --spf --mbox --dkim
result="$(run_audit)"
assert_contains "a published selector with no key on disk cannot sign" "$(row_for "$result" unsigned.example)" "stale"
assert_lacks "so it is not reported as signing" "$(row_for "$result" unsigned.example)" "signing"
assert_contains "and is named, because a bare record check calls this DKIM" "$result" "dkim_record_without_key:unsigned.example"
assert_contains "counted apart from working DKIM" "$result" "DKIM stale record:     1"
assert_contains "which stays at zero" "$result" "DKIM signing:          0"

reset_fixtures
add_domain broken.example alice --spf --mbox --dkim-key
result="$(run_audit)"
assert_contains "a key with nothing published signs unverifiably" "$(row_for "$result" broken.example)" "BROKEN"
assert_contains "and is a finding of its own" "$result" "dkim_broken_unpublished:broken.example"
assert_contains "counted" "$result" "DKIM BROKEN:           1"
assert_contains "--strict fails on it, as it does on an unauthorized rua" "$(run_audit --strict)" "exit=1"

reset_fixtures
add_domain ses.example alice --spf --mbox --dkim-other
result="$(run_audit)"
assert_contains "a third party's selector is reported, not judged" "$(row_for "$result" ses.example)" "delegated"
assert_lacks "not called stale, since no key of ours is implied" "$(row_for "$result" ses.example)" "stale"
assert_lacks "and raises no finding" "$result" "dkim_record_without_key:ses.example"
assert_contains "counted separately" "$result" "DKIM delegated:        1"

reset_fixtures
add_domain nothing.example alice --spf --mbox
result="$(run_audit)"
assert_contains "no key and no record at all" "$(row_for "$result" nothing.example)" "none"
assert_contains "counted" "$result" "DKIM none:             1"
assert_contains "--strict does not fail merely for absent DKIM" "$(run_audit --strict)" "exit=0"

reset_fixtures
add_domain sel.example alice --spf --mbox --dkim-other --dkim-key
result="$(run_audit --strict)"
assert_contains "the selector is what matters: another one does not satisfy ours" "$(row_for "$result" sel.example)" "BROKEN"
result="$(MAIL_AUTH_DKIM_SELECTOR=s1 run_audit)"
assert_contains "and pointing the selector at it makes the same host healthy" "$(row_for "$result" sel.example)" "signing"

echo
echo "degenerate and hostile inputs"
reset_fixtures
add_domain ok.example alice --spf --mbox
{
  echo "# a comment: notauser"
  echo ""
  echo "orphan.example: bob"
} >>"$OWNERS"
result="$(run_audit)"
assert_contains "a commented line is not treated as a domain" "$result" "zones examined:        1"
assert_lacks "and does not appear in the table" "$result" "notauser"
assert_contains "a domain with no zone file is reported, not silently dropped" "$result" "no_zone_file:orphan.example"

result="$(run_audit --only ok.example)"
assert_contains "--only narrows to one domain" "$result" "zones examined:        1"
assert_lacks "excluding the others" "$result" "orphan.example"

reset_fixtures
result="$(run_audit)"
assert_contains "an empty domainowners is not an error" "$result" "exit=0"
assert_contains "it reports zero rather than crashing" "$result" "zones examined:        0"

result="$(MAIL_AUTH_DOMAINOWNERS="${SANDBOX}/nope" bash "$SCRIPT" 2>&1; echo "exit=$?")"
assert_contains "a missing domainowners file is a hard error, not a clean sweep" "$result" "exit=2"

echo
echo "mutants: each assertion above has to be load-bearing"

reset_fixtures
add_domain live.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:x@gmail.com"'

mutant1="${SANDBOX}/mutant-keeps-colon.sh"
if python3 - "$SCRIPT" "$mutant1" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '  domain="${raw%:}"\n'
if old not in text:
    sys.exit(1)
open(dst, "w").write(text.replace(old, '  domain="${raw}"\n', 1))
PY
then
  out="$(MAIL_AUTH_DOMAINOWNERS="$OWNERS" MAIL_AUTH_ZONE_DIR="$ZONES" \
    MAIL_AUTH_VIRTUAL_ROOT="$VIRTUAL" MAIL_AUTH_RESOLVER="$RESOLVER" \
    bash "$mutant1" 2>&1)"
  assert_contains "without the colon strip the sweep finds nothing" "$out" "zones examined:        0"
  assert_lacks "and so reports no unauthorized rua on a host that has one" "$out" "rua_unauthorized"
else
  assert_that "the colon strip is still the line the mutant targets" no
fi

> "$OWNERS"
add_domain unsigned.example alice --spf --mbox --dkim
mutant_dkim="${SANDBOX}/mutant-record-is-dkim.sh"
if python3 - "$SCRIPT" "$mutant_dkim" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '  if [[ "$dkim_key" == yes && "$dkim_own_record" == yes ]]; then\n'
if old not in text:
    sys.exit(1)
open(dst, "w").write(text.replace(old, '  if [[ "$dkim_own_record" == yes ]]; then\n', 1))
PY
then
  out="$(MAIL_AUTH_DOMAINOWNERS="$OWNERS" MAIL_AUTH_ZONE_DIR="$ZONES" \
    MAIL_AUTH_VIRTUAL_ROOT="$VIRTUAL" MAIL_AUTH_RESOLVER="$RESOLVER" \
    bash "$mutant_dkim" 2>&1)"
  # This is the bug the first version of this script shipped with, on 20 real zones.
  assert_contains "judging DKIM by the record alone calls an unsigned domain signing" \
    "$(row_for "$out" unsigned.example)" "signing"
  assert_lacks "and drops the finding that says otherwise" "$out" "dkim_record_without_key"
else
  assert_that "the DKIM pair test is still the line the mutant targets" no
fi

reset_fixtures
add_domain live.example alice --spf --mbox \
  --dmarc '_dmarc	IN	TXT	"v=DMARC1; p=none; rua=mailto:x@gmail.com"'

mutant2="${SANDBOX}/mutant-all-local.sh"
if python3 - "$SCRIPT" "$mutant2" <<'PY'
import sys

src, dst = sys.argv[1], sys.argv[2]
text = open(src).read()
old = '  [[ "$policy" == "$rua" ]] && return 0\n'
if old not in text:
    sys.exit(1)
open(dst, "w").write(text.replace(old, "  return 0\n", 1))
PY
then
  out="$(MAIL_AUTH_DOMAINOWNERS="$OWNERS" MAIL_AUTH_ZONE_DIR="$ZONES" \
    MAIL_AUTH_VIRTUAL_ROOT="$VIRTUAL" MAIL_AUTH_RESOLVER="$RESOLVER" \
    bash "$mutant2" 2>&1)"
  assert_lacks "treating every rua as local hides the unauthorized destination" \
    "$(row_for "$out" live.example)" "UNAUTHORIZED"
  assert_contains "and leaves the count at zero on a host that has one" "$out" "rua UNAUTHORIZED:      0"
else
  assert_that "the locality test is still the line the mutant targets" no
fi

echo
echo "passed ${passed}, failed ${failed}"
if [[ "$failed" -gt 0 ]]; then
  echo "FAIL: offline mail auth posture proofs"
  exit 1
fi
echo "PASS: offline mail auth posture proofs"
exit 0
