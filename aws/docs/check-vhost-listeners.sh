#!/bin/bash
# Verify every hosted domain is matched to its OWN nginx vhost (not the catch-all).
#
# Detects the regression in nginx-vhost-catchall-regression.md: when an explicit listen
# address is injected into one vhost, every vhost missing that address stops matching and
# falls through to the DirectAdmin catch-all (default page + CN=server.wbat.net cert).
#
# Runs from anywhere with network access; no AWS credentials and no shell on the box needed.
#
# Usage: ./check-vhost-listeners.sh [domain ...]
#        ./check-vhost-listeners.sh --ip 44.214.133.234 iots.com lmgt.com
#
# Exit status: 0 = every domain matched its own vhost, 1 = at least one hit the catch-all.

set -uo pipefail

# Fingerprints of the DirectAdmin catch-all vhost on this host.
CATCHALL_CERT_CN="server.wbat.net"
CATCHALL_BODY="webserver is functioning normally"

SERVER_IP=""
DOMAINS=()

while [ $# -gt 0 ]; do
  case "$1" in
    --ip)
      SERVER_IP="${2:-}"
      shift 2
      ;;
    -h | --help)
      sed -n '2,16p' "$0"
      exit 0
      ;;
    *)
      DOMAINS+=("$1")
      shift
      ;;
  esac
done

# Pass the real DirectAdmin domain list for a full sweep; these defaults are only a smoke
# test. Hostnames with no site vhost of their own (e.g. server.wbat.net) will report
# CATCH-ALL legitimately, so do not add them here.
if [ "${#DOMAINS[@]}" -eq 0 ]; then
  DOMAINS=(tellerstech.com origin.tellerstech.com iots.com lmgt.com)
  echo "No domains given; checking defaults: ${DOMAINS[*]}"
fi

# Resolve the origin IP once so every probe hits the same box even if DNS is split.
if [ -z "$SERVER_IP" ]; then
  SERVER_IP=$(dig +short origin.tellerstech.com A | grep -E '^[0-9.]+$' | head -1)
fi
if [ -z "$SERVER_IP" ]; then
  echo "Could not resolve the origin IP. Pass it explicitly: $0 --ip 44.214.133.234 <domain>"
  exit 1
fi

echo "Origin IP: $SERVER_IP"
echo
printf '%-32s %-30s %-8s %s\n' "HOSTNAME" "CERT SUBJECT CN" "HTTP" "VERDICT"
printf '%-32s %-30s %-8s %s\n' "--------" "---------------" "----" "-------"

failed=0

for d in "${DOMAINS[@]}"; do
  cert_cn=$(echo \
    | timeout 15 openssl s_client -connect "${SERVER_IP}:443" -servername "$d" 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -e 's/.*CN *= *//' -e 's/,.*//')
  [ -z "$cert_cn" ] && cert_cn="(tls failed)"

  # --resolve pins the connection to this box without trusting public DNS.
  code=$(curl -sk --max-time 15 "https://${d}/" --resolve "${d}:443:${SERVER_IP}" \
    -o /tmp/vhost-body.$$ -w '%{http_code}' 2>/dev/null)
  body=$(head -c 200 /tmp/vhost-body.$$ 2>/dev/null)
  rm -f /tmp/vhost-body.$$

  # Catch-all cert AND catch-all body means the domain never reached its own server block.
  if [ "$cert_cn" = "$CATCHALL_CERT_CN" ] && [[ "$body" == *"$CATCHALL_BODY"* ]]; then
    verdict="CATCH-ALL (no vhost match, no valid SSL)"
    failed=1
  elif [ "$cert_cn" = "$CATCHALL_CERT_CN" ]; then
    verdict="WRONG CERT (default vhost cert)"
    failed=1
  elif [ "$cert_cn" = "(tls failed)" ]; then
    verdict="TLS HANDSHAKE FAILED"
    failed=1
  else
    verdict="ok"
  fi

  printf '%-32s %-30s %-8s %s\n' "$d" "$cert_cn" "$code" "$verdict"
done

echo
if [ "$failed" -ne 0 ]; then
  cat <<'EOF'
FAIL: at least one domain is served by the catch-all vhost.
See aws/docs/nginx-vhost-catchall-regression.md — the domain's nginx vhost is not bound to
the local address that public traffic arrives on. Do NOT fix it per domain; correct the
DirectAdmin IP / vhost template so all domains bind it, then `da build rewrite_confs`.
EOF
  exit 1
fi

echo "PASS: every domain matched its own vhost with a domain-appropriate certificate."
