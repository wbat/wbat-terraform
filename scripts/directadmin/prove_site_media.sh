#!/bin/bash
# Offline proof that sync_site_media.sh will not let live site content end up backed up
# nowhere. No box access, no S3, no DirectAdmin: rclone and mail are stubbed and every
# path is redirected into a temp sandbox.
#
# The property under test is not "it uploads files". It is the ordering guarantee, which
# is the only thing standing between this design and data loss: excluding a path from the
# nightly account backup makes the S3 copy the sole off-host copy of live website
# content, so an exclusion written without a verified copy behind it is exactly the
# silent gap this runbook exists because of. Every proof below is a way that could
# happen by accident.
#
# Usage (from repo root):
#   ./scripts/directadmin/prove_site_media.sh

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/scripts/directadmin/sync_site_media.sh"

if [[ ! -x "$SCRIPT" ]]; then
  echo "ERROR: missing or non-executable script $SCRIPT" >&2
  exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

pass=0
fail=0
ok() {
  printf '  OK   %s\n' "$1"
  pass=$((pass + 1))
}
bad() {
  printf '  FAIL %s\n' "$1"
  fail=$((fail + 1))
}
assert() {
  local what="$1" cond="$2"
  if eval "$cond"; then ok "$what"; else bad "$what"; fi
}

mkdir -p "${SANDBOX}/bin"

# Stub rclone. STUB_COPY_RC and STUB_CHECK_RC drive the two outcomes that matter, and
# every invocation is recorded so a proof can assert that nothing was asked to delete.
cat >"${SANDBOX}/bin/rclone" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >>"${STUB_CALLS}"
case "${1:-}" in
  copy)  exit "${STUB_COPY_RC:-0}" ;;
  check) exit "${STUB_CHECK_RC:-0}" ;;
esac
exit 0
STUB
chmod +x "${SANDBOX}/bin/rclone"

cat >"${SANDBOX}/bin/mail" <<'STUB'
#!/bin/bash
{
  printf 'TO: %s\n' "${!#}"
  printf 'ARGS: %s\n' "$*"
  cat
} >>"${STUB_MAIL}"
STUB
chmod +x "${SANDBOX}/bin/mail"

export PATH="${SANDBOX}/bin:${PATH}"

HOMES="${SANDBOX}/home"
STATE="${SANDBOX}/state"
CONF="${SANDBOX}/vhost-listen.conf"
MANIFEST="${SANDBOX}/site-media.conf"

cat >"$CONF" <<EOF
HEALTH_ALERT_TO="ops@wbat.test.invalid"
EOF

# A real address, for the one proof that asserts mail is actually sent. The placeholder
# guard in the script deliberately refuses .invalid, which is itself worth not tripping
# over by accident.
CONF_REAL="${SANDBOX}/vhost-listen-real.conf"
cat >"$CONF_REAL" <<EOF
HEALTH_ALERT_TO="ops@wbat.net"
EOF

reset_world() {
  rm -rf "$HOMES" "$STATE"
  mkdir -p "${HOMES}/teller/domains/site.com/public_html/gallery"
  mkdir -p "${HOMES}/teller/domains/site.com/public_html/videos"
  echo "photo" >"${HOMES}/teller/domains/site.com/public_html/gallery/a.jpg"
  echo "clip" >"${HOMES}/teller/domains/site.com/public_html/videos/b.mp4"
  cat >"$MANIFEST" <<'EOF'
teller domains/site.com/public_html/gallery
teller domains/site.com/public_html/videos
EOF
  export STUB_CALLS="${SANDBOX}/rclone.calls"
  export STUB_MAIL="${SANDBOX}/mail.out"
  : >"$STUB_CALLS"
  : >"$STUB_MAIL"
  unset STUB_COPY_RC STUB_CHECK_RC
}

run() {
  SITE_MEDIA_HOME="$HOMES" \
    SITE_MEDIA_MANIFEST="$MANIFEST" \
    SITE_MEDIA_CONF="${USE_CONF:-$CONF}" \
    SITE_MEDIA_LOG="${SANDBOX}/run.log" \
    SITE_MEDIA_LOCK="${SANDBOX}/run.lock" \
    SITE_MEDIA_STATE="$STATE" \
    SITE_MEDIA_BUCKET="test-bucket" \
    SITE_MEDIA_RCLONE="rclone" \
    "$SCRIPT" "$@" >"${SANDBOX}/out" 2>&1
  echo $?
}

exclude_file="${HOMES}/teller/.backup_exclude_paths"

echo "== 1. exclusions are refused when nothing has been verified =="
reset_world
rc=$(run --write-exclusions)
assert "exits non-zero" "[[ $rc -ne 0 ]]"
assert "writes no exclusion file" "[[ ! -e '$exclude_file' ]]"
assert "says why" "grep -q 'REFUSING to write exclusions for teller' '${SANDBOX}/out'"

echo "== 2. a successful sync copies, verifies and records a receipt =="
reset_world
rc=$(run --sync)
assert "exits zero" "[[ $rc -eq 0 ]]"
assert "copied both paths" "[[ \$(grep -c '^copy ' '$STUB_CALLS') -eq 2 ]]"
assert "verified both paths" "[[ \$(grep -c '^check ' '$STUB_CALLS') -eq 2 ]]"
assert "receipt written" "[[ -s '${STATE}/teller.receipt' ]]"
assert "receipt names the bucket" "grep -q '^bucket=test-bucket' '${STATE}/teller.receipt'"

echo "== 3. nothing is ever asked to delete =="
assert "no rclone sync/delete/purge/rmdir in any call" \
  "! grep -Eq '^(sync|delete|deletefile|purge|rmdir|rmdirs) ' '$STUB_CALLS'"
assert "copy is the only mutating verb used" \
  "[[ \$(grep -Ec '^(copy|check) ' '$STUB_CALLS') -eq \$(grep -c . '$STUB_CALLS') ]]"

echo "== 4. after a verified sync, exclusions are written =="
rc=$(run --write-exclusions)
assert "exits zero" "[[ $rc -eq 0 ]]"
assert "exclusion file exists" "[[ -s '$exclude_file' ]]"
assert "lists both paths" "[[ \$(grep -c . '$exclude_file') -eq 2 ]]"
assert "paths are relative, no leading slash" "! grep -q '^/' '$exclude_file'"
assert "no trailing slash on any entry" "! grep -q '/$' '$exclude_file'"

echo "== 5. a failed verification blocks the receipt, so exclusions stay refused =="
reset_world
STUB_CHECK_RC=1 run --sync >/dev/null
assert "no receipt after failed verification" "[[ ! -e '${STATE}/teller.receipt' ]]"
rc=$(run --write-exclusions)
assert "exclusions refused" "[[ $rc -ne 0 ]]"
assert "still no exclusion file" "[[ ! -e '$exclude_file' ]]"

echo "== 6. a failed copy blocks the receipt too =="
reset_world
STUB_COPY_RC=1 run --sync >/dev/null
assert "no receipt after failed copy" "[[ ! -e '${STATE}/teller.receipt' ]]"

echo "== 7. a receipt for a different path set is not accepted =="
reset_world
run --sync >/dev/null
assert "receipt exists to begin with" "[[ -s '${STATE}/teller.receipt' ]]"
# Someone adds a path to the manifest and reaches for --write-exclusions without
# re-syncing. The new path has never been copied, so the old receipt must not cover it.
mkdir -p "${HOMES}/teller/domains/site.com/public_html/docs"
echo "pdf" >"${HOMES}/teller/domains/site.com/public_html/docs/c.pdf"
echo "teller domains/site.com/public_html/docs" >>"$MANIFEST"
rc=$(run --write-exclusions)
assert "exclusions refused" "[[ $rc -ne 0 ]]"
assert "says the path set differs" "grep -q 'different set of paths' '${SANDBOX}/out'"
assert "no exclusion file" "[[ ! -e '$exclude_file' ]]"

echo "== 8. a stale receipt is not accepted =="
reset_world
run --sync >/dev/null
# Backdate the receipt past the age limit.
sed -i "s/^verified_epoch=.*/verified_epoch=1/" "${STATE}/teller.receipt"
rc=$(run --write-exclusions)
assert "exclusions refused" "[[ $rc -ne 0 ]]"
assert "says the receipt is old" "grep -q 'receipt is .* old' '${SANDBOX}/out'"

echo "== 9. a receipt from another bucket is not accepted =="
reset_world
run --sync >/dev/null
sed -i "s/^bucket=.*/bucket=some-other-bucket/" "${STATE}/teller.receipt"
rc=$(run --write-exclusions)
assert "exclusions refused" "[[ $rc -ne 0 ]]"
assert "names the wrong bucket" "grep -q 'not test-bucket' '${SANDBOX}/out'"

echo "== 10. failing to protect already-excluded content raises an alert =="
reset_world
run --sync >/dev/null
USE_CONF="$CONF_REAL" run --write-exclusions >/dev/null
assert "exclusions are in place" "[[ -s '$exclude_file' ]]"
: >"$STUB_MAIL"
USE_CONF="$CONF_REAL" STUB_CHECK_RC=1 run --sync >/dev/null
assert "mail was sent" "[[ -s '$STUB_MAIL' ]]"
assert "subject says the content is unprotected" "grep -q 'content is unprotected' '$STUB_MAIL'"
assert "names the account" "grep -q 'teller' '$STUB_MAIL'"

echo "== 11. no alert when the same failure happens with no exclusions in place =="
reset_world
: >"$STUB_MAIL"
USE_CONF="$CONF_REAL" STUB_CHECK_RC=1 run --sync >/dev/null
assert "nothing mailed" "[[ ! -s '$STUB_MAIL' ]]"

echo "== 12. manifest entries that would exclude the wrong thing are rejected =="
reset_world
cat >"$MANIFEST" <<'EOF'
teller /domains/site.com/public_html/gallery
teller domains/site.com/public_html/videos/
teller ../../etc
teller domains/site.com/public_html/gallery
EOF
rc=$(run --list)
assert "absolute path rejected" "grep -q 'ignoring absolute path' '${SANDBOX}/out'"
assert "trailing slash rejected" "grep -q 'trailing slash is not honoured' '${SANDBOX}/out'"
assert "dot-dot rejected" "grep -q 'contains ..' '${SANDBOX}/out'"
assert "the one good entry survives" "grep -q 'public_html/gallery' '${SANDBOX}/out'"

echo "== 13. a symlinked or oversized manifest is refused outright =="
reset_world
ln -sf "$MANIFEST" "${SANDBOX}/manifest-link.conf"
rc=$(MANIFEST="${SANDBOX}/manifest-link.conf" run --list)
assert "symlink refused" "[[ $rc -ne 0 ]]"
reset_world
head -c 70000 /dev/zero | tr '\0' '#' >"$MANIFEST"
rc=$(run --list)
assert "oversized refused" "[[ $rc -ne 0 ]]"

# Non-vacuity. Each check removes one guard and confirms the corresponding proof then
# stops holding. A proof that passes against a script with its guard deleted is proving
# nothing, and the way that happens in practice is a fixture that would have satisfied
# the guard anyway -- so each case below starts from exactly the state its proof does,
# and asserts the unmutated script disagrees with the mutant on the same fixture.
echo "== non-vacuity =="
MUT="${SANDBOX}/mutant.sh"

run_mutant() {
  SITE_MEDIA_HOME="$HOMES" SITE_MEDIA_MANIFEST="$MANIFEST" SITE_MEDIA_CONF="$CONF" \
    SITE_MEDIA_LOG="${SANDBOX}/mut.log" SITE_MEDIA_LOCK="${SANDBOX}/mut.lock" \
    SITE_MEDIA_STATE="$STATE" SITE_MEDIA_BUCKET="test-bucket" SITE_MEDIA_RCLONE="rclone" \
    "$MUT" "$@" >"${SANDBOX}/mut.out" 2>&1
  echo $?
}

# NV1: no receipt at all, which is proof 1's fixture. Deleting the gate must let the
# exclusion through; leaving it must not. Both halves are asserted, because only the
# pair rules out a fixture that was never going to be refused in the first place.
reset_world
control=$(run --write-exclusions)
cp "$SCRIPT" "$MUT"
sed -i 's/if ! reason="\$(receipt_is_current "\$user")"; then/if false; then/' "$MUT"
chmod +x "$MUT"
assert "NV1 mutant differs from the original" "! cmp -s '$SCRIPT' '$MUT'"
rm -f "$exclude_file"
mutant=$(run_mutant --write-exclusions)
assert "NV1: unmutated script refuses with no receipt" "[[ $control -ne 0 ]]"
assert "NV1: without the receipt gate the same fixture is excluded unverified" "[[ $mutant -eq 0 ]]"
assert "NV1: and the mutant really wrote the file" "[[ -s '$exclude_file' ]]"

# NV2: a valid receipt that covers fewer paths than the manifest now asks for, which is
# proof 7's fixture. Without the path-set comparison the stale receipt is accepted and a
# never-copied path is excluded.
reset_world
run --sync >/dev/null
echo "teller domains/site.com/public_html/nonexistent" >>"$MANIFEST"
control=$(run --write-exclusions)
cp "$SCRIPT" "$MUT"
sed -i 's/if \[\[ "\$want" != "\$have" \]\]; then/if false; then/' "$MUT"
chmod +x "$MUT"
assert "NV2 mutant differs from the original" "! cmp -s '$SCRIPT' '$MUT'"
rm -f "$exclude_file"
mutant=$(run_mutant --write-exclusions)
assert "NV2: unmutated script refuses a receipt covering a different path set" "[[ $control -ne 0 ]]"
assert "NV2: without the path-set check the grown manifest is excluded unverified" "[[ $mutant -eq 0 ]]"

# NV3: exclusions in place and verification failing, which is proof 10's fixture. The
# alert exists to make that state loud; without the check it goes out silently.
reset_world
run --sync >/dev/null
USE_CONF="$CONF_REAL" run --write-exclusions >/dev/null
cp "$SCRIPT" "$MUT"
sed -i 's/if exclusions_in_place "\$user"; then/if false; then/' "$MUT"
chmod +x "$MUT"
assert "NV3 mutant differs from the original" "! cmp -s '$SCRIPT' '$MUT'"
: >"$STUB_MAIL"
USE_CONF="$CONF_REAL" STUB_CHECK_RC=1 run --sync >/dev/null
assert "NV3: unmutated script alerts" "[[ -s '$STUB_MAIL' ]]"
: >"$STUB_MAIL"
STUB_CHECK_RC=1 SITE_MEDIA_CONF="$CONF_REAL" run_mutant --sync >/dev/null
assert "NV3: without the exclusions check the same failure is silent" "[[ ! -s '$STUB_MAIL' ]]"

echo
printf 'passed %d, failed %d\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
