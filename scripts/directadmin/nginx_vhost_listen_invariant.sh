#!/bin/bash
# Static invariant: every nginx server_name block must listen on ARRIVAL_IP
# for both :80 and :443.
#
# Usage:
#   nginx_vhost_listen_invariant.sh --arrival 172.16.0.10 [--file nginx-T.txt]
#   nginx -T 2>/dev/null | nginx_vhost_listen_invariant.sh --arrival 172.16.0.10
#
# Exit 0 = OK, 1 = drift, 2 = usage error.

set -euo pipefail

ARRIVAL=""
FILE=""
ALLOWLIST="${ALLOWLIST_CATCHALL_HOSTS:-}"

usage() {
  sed -n '2,10p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arrival) ARRIVAL="${2:-}"; shift 2 ;;
    --file) FILE="${2:-}"; shift 2 ;;
    --allowlist) ALLOWLIST="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$ARRIVAL" ]]; then
  echo "ERROR: --arrival IP is required" >&2
  exit 2
fi

TMP=""
cleanup() { [[ -n "${TMP:-}" && -f "$TMP" ]] && rm -f "$TMP"; return 0; }
trap cleanup EXIT

if [[ -n "$FILE" ]]; then
  SRC="$FILE"
elif [[ ! -t 0 ]]; then
  TMP="$(mktemp)"
  cat >"$TMP"
  SRC="$TMP"
else
  TMP="$(mktemp)"
  NGINX_BIN="$(command -v nginx || true)"
  [[ -x "$NGINX_BIN" ]] || NGINX_BIN=/usr/sbin/nginx
  # Config goes to stdout; warnings to stderr. Keep stdout even when exit != 0.
  "$NGINX_BIN" -T >"$TMP" 2>"${TMP}.err" || true
  if [[ ! -s "$TMP" ]]; then
    echo "ERROR: nginx -T produced no config (bin=$NGINX_BIN)" >&2
    [[ -s "${TMP}.err" ]] && head -20 "${TMP}.err" >&2
    rm -f "${TMP}.err"
    exit 1
  fi
  rm -f "${TMP}.err"
  SRC="$TMP"
fi

python3 - "$ARRIVAL" "$SRC" "$ALLOWLIST" <<'PY'
import re
import sys

arrival, path, allow_raw = sys.argv[1], sys.argv[2], sys.argv[3]
allow = set(allow_raw.split()) if allow_raw.strip() else set()
text = open(path, errors="replace").read()
blocks = re.split(r"(?m)^server\s*\{", text)
name_re = re.compile(r"^\s*server_name\s+([^;]+);", re.M)
listen_re = re.compile(r"^\s*listen\s+([^;]+);", re.M)
fail = 0
checked = 0


def port_of(addr):
    if addr in ("80", "443"):
        return int(addr)
    if ":" in addr:
        # IPv4:port or *:port — not IPv6 here (DA uses [addr]:port)
        if addr.startswith("["):
            m = re.search(r"\]:(\d+)$", addr)
            return int(m.group(1)) if m else None
        return int(addr.rsplit(":", 1)[-1])
    return None


def is_wildcard(addr):
    if addr in ("80", "443", "*", "0.0.0.0"):
        return True
    return addr.startswith("*:") or addr.startswith("0.0.0.0:")


def covers(listen, arrival, want_port, want_ssl):
    toks = listen.split()
    addr = toks[0]
    ssl = "ssl" in toks
    if want_ssl and not (ssl or port_of(addr) == 443):
        return False
    if not want_ssl and (ssl or port_of(addr) == 443):
        return False
    p = port_of(addr)
    if p is not None and p != want_port:
        return False
    if is_wildcard(addr):
        return p == want_port or addr in (str(want_port),)
    if addr == arrival:
        # bare IP listen implies the port from context; DA always uses IP:port
        return True
    if addr == f"{arrival}:{want_port}":
        return True
    return False


for block in blocks[1:]:
    names = []
    for m in name_re.finditer(block):
        names.extend(n for n in m.group(1).split() if n and n != "_")
    if not names:
        continue
    if all(
        (n in allow)
        or (n[4:] in allow if n.startswith("www.") else False)
        or (f"www.{n}" in allow)
        for n in names
    ):
        continue
    listens = [m.group(1).strip() for m in listen_re.finditer(block)]
    if not listens:
        continue
    # DA emits separate server{} blocks for :80 and :443. Only require the
    # arrival IP for ports this block actually declares.
    declares80 = False
    declares443 = False
    for L in listens:
        toks = L.split()
        addr = toks[0]
        ssl = "ssl" in toks
        p = port_of(addr)
        if ssl or p == 443:
            declares443 = True
        elif p == 80 or (p is None and not ssl):
            declares80 = True
    if not declares80 and not declares443:
        continue
    checked += 1
    missing = []
    if declares80 and not any(covers(L, arrival, 80, False) for L in listens):
        missing.append(":80")
    if declares443 and not any(covers(L, arrival, 443, True) for L in listens):
        missing.append(":443")
    if missing:
        label = " ".join(names[:6])
        print(
            f"FAIL {label} missing listen {arrival}{','.join(missing)}; have: {listens}"
        )
        fail = 1

if checked == 0:
    print("ERROR: no server_name blocks found in input", file=sys.stderr)
    sys.exit(1)
if fail:
    print(f"FAIL invariant: {checked} server blocks checked; drift detected")
    sys.exit(1)
print(f"OK invariant: {checked} server blocks cover arrival {arrival} on declared ports")
sys.exit(0)
PY
