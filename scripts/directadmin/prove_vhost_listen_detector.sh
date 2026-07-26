#!/bin/bash
# Offline proof that the nginx -T invariant detector catches the known-bad
# catch-all regression fixture (and would pass if every vhost listened on the
# stale linked IP). No production changes.
#
# Usage (from repo root):
#   ./scripts/directadmin/prove_vhost_listen_detector.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INV="${ROOT}/scripts/directadmin/nginx_vhost_listen_invariant.sh"
FIX="${ROOT}/aws/docs/fixtures/nginx-catchall-broken-2026-07-26/nginx-T.full.txt"
ALLOW="server.wbat.net wbat.net"

if [[ ! -f "$FIX" ]]; then
  echo "ERROR: missing fixture $FIX" >&2
  exit 1
fi

echo "== Proof 1: known-bad fixture MUST fail for arrival IP 172.30.0.71 =="
if "$INV" --arrival 172.30.0.71 --file "$FIX" --allowlist "$ALLOW" >/tmp/prove-vhost-71.out; then
  echo "FAIL: detector returned OK on known-bad fixture" >&2
  exit 1
fi
grep -q 'iots.com' /tmp/prove-vhost-71.out
grep -q 'FAIL invariant' /tmp/prove-vhost-71.out
# tellerstech was hand-patched and must NOT be reported as missing .71
if grep -q 'FAIL tellerstech.com www.tellerstech.com' /tmp/prove-vhost-71.out; then
  echo "FAIL: tellerstech.com incorrectly flagged (it has .71 listens)" >&2
  exit 1
fi
echo "OK detector flags broken domains and spares hand-patched tellerstech.com"

echo "== Proof 2: same fixture MUST pass for stale linked IP 172.30.0.87 =="
"$INV" --arrival 172.30.0.87 --file "$FIX" --allowlist "$ALLOW" >/tmp/prove-vhost-87.out
grep -q '^OK invariant' /tmp/prove-vhost-87.out
echo "OK detector is arrival-IP-specific (not a blunt always-fail)"

echo "PASS: offline detector proofs"
