#!/bin/bash
# Verify every hosted domain is matched to its OWN nginx vhost (not the catch-all).
#
# Detects the regression in nginx-vhost-catchall-regression.md: when an explicit listen
# address is injected into one vhost, every vhost missing that address stops matching and
# falls through to the DirectAdmin catch-all (default page + CN=server.wbat.net cert).
#
# Runs from anywhere with network access; no AWS credentials and no shell on the box needed.
# When run on-box, pass no domains to auto-enumerate from /etc/virtual/domainowners.
#
# Usage: ./check-vhost-listeners.sh [domain ...]
#        ./check-vhost-listeners.sh --ip 44.214.133.234 iots.com lmgt.com
#        ./check-vhost-listeners.sh --json --ports 80,443 tellerstech.com iots.com
#        ./check-vhost-listeners.sh --acme iots.com
#
# Exit status: 0 = every domain matched its own vhost, 1 = at least one hit the catch-all.

set -uo pipefail

# Fingerprints of the DirectAdmin catch-all vhost on this host.
CATCHALL_CERT_CN="server.wbat.net"
CATCHALL_BODY="webserver is functioning normally"

SERVER_IP=""
DOMAINS=()
PORTS=(443)
JSON=0
CHECK_ACME=0
ALLOWLIST=""

while [ $# -gt 0 ]; do
  case "$1" in
    --ip)
      SERVER_IP="${2:-}"
      shift 2
      ;;
    --ports)
      IFS=',' read -r -a PORTS <<<"${2:-443}"
      shift 2
      ;;
    --json)
      JSON=1
      shift
      ;;
    --acme)
      CHECK_ACME=1
      shift
      ;;
    --allowlist)
      ALLOWLIST="${2:-}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,20p' "$0"
      exit 0
      ;;
    *)
      DOMAINS+=("$1")
      shift
      ;;
  esac
done

# On-box: enumerate real DA domains when none were passed.
if [ "${#DOMAINS[@]}" -eq 0 ] && [ -f /etc/virtual/domainowners ]; then
  while IFS= read -r d; do
    [ -n "$d" ] && DOMAINS+=("$d")
  done < <(cut -d: -f1 /etc/virtual/domainowners | sort -u)
  if [ "$JSON" -eq 0 ]; then
    echo "No domains given; using /etc/virtual/domainowners (${#DOMAINS[@]} domains)"
  fi
fi

# Pass the real DirectAdmin domain list for a full sweep; these defaults are only a smoke
# test. Hostnames with no site vhost of their own (e.g. server.wbat.net) will report
# CATCH-ALL legitimately, so do not add them here (or put them in --allowlist).
if [ "${#DOMAINS[@]}" -eq 0 ]; then
  DOMAINS=(tellerstech.com origin.tellerstech.com iots.com lmgt.com)
  if [ "$JSON" -eq 0 ]; then
    echo "No domains given; checking defaults: ${DOMAINS[*]}"
  fi
fi

# Resolve the origin IP once so every probe hits the same box even if DNS is split.
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(dig +short origin.tellerstech.com A | grep -E '^[0-9.]+$' | head -1)
fi
if [ -z "$SERVER_IP" ]; then
  echo "Could not resolve the origin IP. Pass it explicitly: $0 --ip 44.214.133.234 <domain>" >&2
  exit 1
fi

if [ "$JSON" -eq 0 ]; then
  echo "Origin IP: $SERVER_IP"
  echo "Ports: ${PORTS[*]}"
  echo
  printf '%-8s %-32s %-30s %-8s %s\n' "PORT" "HOSTNAME" "CERT/HEADER" "HTTP" "VERDICT"
  printf '%-8s %-32s %-30s %-8s %s\n' "----" "--------" "-----------" "----" "-------"
fi

failed=0
json_items=()

is_allowlisted() {
  local d="$1" a
  for a in $ALLOWLIST; do
    [ "$d" = "$a" ] && return 0
  done
  return 1
}

check_one() {
  local d="$1" port="$2"
  local cert_cn="-" code body verdict catchall_hdr url resolve
  local tmp
  tmp="$(mktemp)"

  if [ "$port" = "443" ]; then
    # macOS often lacks GNU timeout(1); prefer gtimeout, else bare openssl.
    if command -v timeout >/dev/null 2>&1; then
      _openssl() { timeout 15 openssl "$@"; }
    elif command -v gtimeout >/dev/null 2>&1; then
      _openssl() { gtimeout 15 openssl "$@"; }
    else
      _openssl() { openssl "$@"; }
    fi
    cert_cn=$(echo \
      | _openssl s_client -connect "${SERVER_IP}:443" -servername "$d" 2>/dev/null \
      | openssl x509 -noout -subject 2>/dev/null \
      | sed -e 's/.*CN *= *//' -e 's/,.*//')
    [ -z "$cert_cn" ] && cert_cn="(tls failed)"
    url="https://${d}/"
    resolve="${d}:443:${SERVER_IP}"
  else
    url="http://${d}/"
    resolve="${d}:80:${SERVER_IP}"
  fi

  # Capture headers + body; prefer X-DA-Catchall when present.
  code=$(curl -sk --max-time 15 -D "${tmp}.hdr" -o "$tmp" -w '%{http_code}' \
    "$url" --resolve "$resolve" 2>/dev/null)
  [ -n "$code" ] || code="000"
  body=$(head -c 200 "$tmp" 2>/dev/null || true)
  catchall_hdr=$(awk -F': ' 'tolower($1)=="x-da-catchall" {gsub(/\r/,"",$2); print $2; exit}' "${tmp}.hdr" 2>/dev/null || true)
  rm -f "$tmp" "${tmp}.hdr"

  if is_allowlisted "$d"; then
    verdict="ok (allowlisted)"
  elif [ -n "$catchall_hdr" ]; then
    verdict="CATCH-ALL (X-DA-Catchall=${catchall_hdr})"
    failed=1
  elif [ "$port" = "443" ] && [ "$cert_cn" = "$CATCHALL_CERT_CN" ] && [[ "$body" == *"$CATCHALL_BODY"* ]]; then
    verdict="CATCH-ALL (no vhost match, no valid SSL)"
    failed=1
  elif [ "$port" = "443" ] && [ "$cert_cn" = "$CATCHALL_CERT_CN" ]; then
    verdict="WRONG CERT (default vhost cert)"
    failed=1
  elif [ "$port" = "443" ] && [ "$cert_cn" = "(tls failed)" ]; then
    verdict="TLS HANDSHAKE FAILED"
    failed=1
  elif [ "$port" = "80" ] && [[ "$body" == *"$CATCHALL_BODY"* ]]; then
    verdict="CATCH-ALL (default page body)"
    failed=1
  else
    verdict="ok"
  fi

  if [ "$CHECK_ACME" -eq 1 ]; then
    local acme_code
    acme_code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
      "http://${d}/.well-known/acme-challenge/probe-test" \
      --resolve "${d}:80:${SERVER_IP}" 2>/dev/null || echo "000")
    # 404 from the domain docroot is fine; catching catch-all is not (same body).
    local acme_body
    acme_body=$(curl -sk --max-time 15 \
      "http://${d}/.well-known/acme-challenge/probe-test" \
      --resolve "${d}:80:${SERVER_IP}" 2>/dev/null | head -c 200 || true)
    if [[ "$acme_body" == *"$CATCHALL_BODY"* ]]; then
      verdict="${verdict}; ACME->CATCH-ALL"
      failed=1
    else
      verdict="${verdict}; ACME_HTTP=${acme_code}"
    fi
  fi

  if [ "$JSON" -eq 1 ]; then
    # shellcheck disable=SC2086
    json_items+=("$(printf '{"port":%s,"host":"%s","cert_cn":"%s","http":"%s","verdict":"%s","catchall_header":"%s"}' \
      "$port" "$d" "$cert_cn" "$code" "$verdict" "$catchall_hdr")")
  else
    printf '%-8s %-32s %-30s %-8s %s\n' "$port" "$d" "$cert_cn" "$code" "$verdict"
  fi
}

for d in "${DOMAINS[@]}"; do
  for port in "${PORTS[@]}"; do
    check_one "$d" "$port"
  done
done

if [ "$JSON" -eq 1 ]; then
  printf '{"origin_ip":"%s","failed":%s,"results":[' "$SERVER_IP" "$failed"
  i=0
  for item in "${json_items[@]}"; do
    [ "$i" -gt 0 ] && printf ','
    printf '%s' "$item"
    i=$((i + 1))
  done
  printf ']}\n'
fi

if [ "$JSON" -eq 0 ]; then
  echo
fi
if [ "$failed" -ne 0 ]; then
  if [ "$JSON" -eq 0 ]; then
    cat <<'EOF'
FAIL: at least one domain is served by the catch-all vhost.
See aws/docs/nginx-vhost-catchall-regression.md — the domain's nginx vhost is not bound to
the local address that public traffic arrives on. Do NOT fix it per domain; correct the
DirectAdmin Linked IP so all domains bind the arrival address, then rewrite httpd.
EOF
  fi
  exit 1
fi

if [ "$JSON" -eq 0 ]; then
  echo "PASS: every domain matched its own vhost with a domain-appropriate certificate."
fi
exit 0
