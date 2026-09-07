#!/bin/bash
# Offline proof for install_da_vhost_listen.sh --verify: the deploy-drift check itself.
#
# This repo has no deploy pipeline, so --verify is the only thing standing between a
# merged fix and a host still executing the old code. That makes a false "PASS" the worst
# output it can produce, and one was shipping: verify() read each MANAGED entry's declared
# mode and never compared it, so a hook whose executable bit had been stripped was
# reported as "ok". DirectAdmin cannot run a non-executable hook, so backups would pile up
# on local disk exactly as they did before this change, while the check that exists to
# catch that said the host matched the checkout. Proof 3 is that case.
#
# Runs entirely inside a sandbox through the DA_VHOST_* path overrides, so it needs no
# root and touches nothing outside mktemp.
#
# Usage (from repo root):
#   ./scripts/directadmin/prove_install_verify.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="${ROOT}/scripts/directadmin/install_da_vhost_listen.sh"

if [[ ! -f "$SCRIPT" ]]; then
  echo "ERROR: missing $SCRIPT" >&2
  exit 1
fi

SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT

mkdir -p "${SANDBOX}/bin"
# do_install already guards its systemctl calls with `|| true`; stubbing keeps this proof
# from reaching the runner's systemd at all.
cat >"${SANDBOX}/bin/systemctl" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "${SANDBOX}/bin/systemctl"

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# The 700 backup hook: the entry whose mode actually matters at runtime.
HOOK="${SANDBOX}/da-custom/all_backups_post.sh"

run_tool() { # --install|--verify -> sets RC, OUT
  set +e
  OUT="$(env PATH="${SANDBOX}/bin:${PATH}" \
    DA_VHOST_SBIN_DIR="${SANDBOX}/sbin" \
    DA_VHOST_ETC_DIR="${SANDBOX}/etc" \
    DA_VHOST_CRON_DIR="${SANDBOX}/cron.d" \
    DA_VHOST_UNIT_DIR="${SANDBOX}/units" \
    DA_VHOST_LOGROTATE_DIR="${SANDBOX}/logrotate.d" \
    DA_VHOST_DA_CUSTOM_DIR="${SANDBOX}/da-custom" \
    bash "$SCRIPT" "$1" 2>&1)"
  RC=$?
  set -e
}

# The state column of the hook's line, with the path stripped off. Two reasons: a proof
# about one entry cannot be satisfied by another entry's state, and mktemp paths are random
# so a sandbox that happened to contain "ok" would otherwise break proof 3's negative
# assertion.
hook_state() {
  local line
  line="$(grep -F "$HOOK" <<<"$OUT" | head -1)"
  printf '%s' "${line#*"$HOOK"}" | sed 's/^[[:space:]]*//'
}

##############################################################################
echo "== Proof 1: a fresh install must verify clean =="
##############################################################################
run_tool --install
((RC == 0)) || fail "--install failed in a sandbox:"$'\n'"$OUT"

run_tool --verify
((RC == 0)) || fail "a fresh install must verify clean, got ${RC}:"$'\n'"$OUT"
grep -q 'PASS: installed tooling matches this checkout.' <<<"$OUT" \
  || fail "expected a PASS line from a clean install:"$'\n'"$OUT"
[[ -x "$HOOK" ]] || fail "the backup hook was not installed executable"
echo "OK install then verify reports no drift"

##############################################################################
echo "== Proof 2: edited content must be reported stale =="
##############################################################################
# The case --verify was written for: someone patches the hook on the box and the repo no
# longer describes what runs.
echo "# hand-edited on the box" >>"$HOOK"
run_tool --verify
((RC == 1)) || fail "content drift must exit 1, got ${RC}:"$'\n'"$OUT"
grep -q 'STALE (differs from repo)' <<<"$(hook_state)" \
  || fail "an edited hook must be reported STALE:"$'\n'"$OUT"
echo "OK a hand-edited hook is caught"

##############################################################################
echo "== Proof 3: an unchanged hook that lost its executable bit must be drift =="
##############################################################################
# The regression this proof exists for. Content is byte-identical to the repo, so a
# hash-only check prints "ok" and exits 0 -- while DirectAdmin silently cannot execute the
# hook, no backup is ever uploaded or cleaned up, and the volume fills.
run_tool --install
chmod 600 "$HOOK"
run_tool --verify

((RC == 1)) || fail "a hook that cannot be executed must exit 1, got ${RC}:"$'\n'"$OUT"
grep -q 'MODE 600 (expected 700)' <<<"$(hook_state)" \
  || fail "expected the installed mode and the declared mode to be named:"$'\n'"$OUT"
if grep -q 'ok' <<<"$(hook_state)"; then
  fail "a non-executable hook was reported ok -- this is the false PASS:"$'\n'"$OUT"
fi
if grep -q 'STALE' <<<"$(hook_state)"; then
  fail "this case must be mode-only drift; content was reinstalled from the repo"
fi
echo "OK permission drift is caught without content drift"

##############################################################################
echo "== Proof 4: a deleted file must be reported missing, not ok =="
##############################################################################
run_tool --install
rm -f "$HOOK"
run_tool --verify
((RC == 1)) || fail "a missing hook must exit 1, got ${RC}:"$'\n'"$OUT"
grep -q 'MISSING (never installed)' <<<"$(hook_state)" \
  || fail "a deleted hook must be reported missing:"$'\n'"$OUT"
echo "OK a deleted hook is distinguished from an installed one"

echo
echo "PASS: install/verify deploy-drift proofs"
