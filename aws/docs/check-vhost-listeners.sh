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
#        ./check-vhost-listeners.sh --strict-tls --ports 80,443 iots.com
#
# Port 80 is the authoritative regression signal: the catch-all regression breaks plain
# HTTP as well as TLS, so a domain whose :80 vhost answers correctly is bound to the
# arrival address. A :443 catch-all on such a domain means only that no HTTPS vhost or
# certificate exists for it, which is a normal state for parked domains. That is reported
# as NO-TLS (a warning) rather than a failure, so this exits 0 on a healthy host instead of
# crying wolf and masking a real recurrence. Pass --strict-tls to fail on those too, and
# note the inference needs both ports (--ports 80,443); checking :443 alone stays strict.
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
STRICT_TLS=0

need_arg() {
  local opt="$1"
  if [ $# -lt 2 ] || [ -z "${2}" ] || [[ "${2}" == -* ]]; then
    echo "ERROR: ${opt} requires a value" >&2
    sed -n '2,25p' "$0" >&2
    exit 2
  fi
}

while [ $# -gt 0 ]; do
  case "$1" in
    --ip)
      need_arg "$@"
      SERVER_IP="$2"
      shift 2
      ;;
    --ports)
      need_arg "$@"
      IFS=',' read -r -a PORTS <<<"$2"
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
      need_arg "$@"
      ALLOWLIST="$2"
      shift 2
      ;;
    --strict-tls)
      STRICT_TLS=1
      shift
      ;;
    -h | --help)
      sed -n '2,25p' "$0"
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
warned=0
json_items=()

# Evaluate :80 before :443 so a domain's plain-HTTP result is known when judging TLS.
CHECKS_PORT_80=0
for _p in "${PORTS[@]}"; do
  [ "$_p" = "80" ] && CHECKS_PORT_80=1
done
if [ "$CHECKS_PORT_80" -eq 1 ]; then
  ordered=(80)
  for _p in "${PORTS[@]}"; do
    [ "$_p" != "80" ] && ordered+=("$_p")
  done
  PORTS=("${ordered[@]}")
fi

# Set per domain by check_one when :80 matched the domain's own vhost.
port80_ok=0

is_allowlisted() {
  local d="$1" a
  for a in $ALLOWLIST; do
    [ "$d" = "$a" ] && return 0
  done
  return 1
}

# Return 0 if the PEM on stdin covers hostname $1 (CN or SAN, including wildcards).
cert_covers_host() {
  local host="$1"
  local pem
  pem="$(cat)"
  [ -n "$pem" ] || return 1
  # OpenSSL 1.0.2+: -checkhost understands wildcards.
  if printf '%s\n' "$pem" | openssl x509 -noout -checkhost "$host" >/dev/null 2>&1; then
    return 0
  fi
  # Fallback for older openssl: compare CN and DNS SANs manually.
  local cn sans name
  cn=$(printf '%s\n' "$pem" | openssl x509 -noout -subject 2>/dev/null \
    | sed -e 's/.*CN *= *//' -e 's/,.*//')
  [ "$cn" = "$host" ] && return 0
  if [[ "$cn" == \*.* ]]; then
    local suffix="${cn#\*.}"
    [[ "$host" == *."$suffix" && "$host" != *.*."$suffix" ]] && return 0
  fi
  sans=$(printf '%s\n' "$pem" | openssl x509 -noout -ext subjectAltName 2>/dev/null || true)
  while IFS= read -r name; do
    name="${name#DNS:}"
    name="${name// /}"
    [ -z "$name" ] && continue
    [ "$name" = "$host" ] && return 0
    if [[ "$name" == \*.* ]]; then
      local suffix="${name#\*.}"
      [[ "$host" == *."$suffix" && "$host" != *.*."$suffix" ]] && return 0
    fi
  done < <(printf '%s\n' "$sans" | tr ',' '\n' | grep -i 'DNS:')
  return 1
}

check_one() {
  local d="$1" port="$2"
  local cert_cn="-" code body verdict catchall_hdr url resolve
  local tmp pem cert_ok=0
  # Snapshot so we can tell whether *this* check failed, not an earlier domain.
  local failed_before="$failed"
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
    pem=$(echo | _openssl s_client -connect "${SERVER_IP}:443" -servername "$d" 2>/dev/null \
      | openssl x509 2>/dev/null || true)
    if [ -n "$pem" ]; then
      cert_cn=$(printf '%s\n' "$pem" | openssl x509 -noout -subject 2>/dev/null \
        | sed -e 's/.*CN *= *//' -e 's/,.*//')
      if printf '%s\n' "$pem" | cert_covers_host "$d"; then
        cert_ok=1
      fi
    else
      cert_cn="(tls failed)"
    fi
    [ -z "$cert_cn" ] && cert_cn="(tls failed)"
    url="https://${d}/"
    resolve="${d}:443:${SERVER_IP}"
  else
    url="http://${d}/"
    resolve="${d}:80:${SERVER_IP}"
  fi

  # Fetch body/headers. -k is intentional: certificate identity is validated via
  # openssl above; curl only retrieves the HTTP fingerprint here.
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
  elif [[ "$body" == *"$CATCHALL_BODY"* ]]; then
    # Catch-all body is a failure on its own (any port), even if the cert CN changed.
    verdict="CATCH-ALL (default page body)"
    failed=1
  elif [ "$port" = "443" ] && [ "$cert_cn" = "$CATCHALL_CERT_CN" ]; then
    verdict="WRONG CERT (default vhost cert)"
    failed=1
  elif [ "$port" = "443" ] && [ "$cert_cn" = "(tls failed)" ]; then
    verdict="TLS HANDSHAKE FAILED"
    failed=1
  elif [ "$port" = "443" ] && [ "$cert_ok" -ne 1 ]; then
    verdict="WRONG CERT (does not cover ${d})"
    failed=1
  else
    verdict="ok"
  fi

  # Downgrade a TLS-only miss to a warning when plain HTTP already proved this domain's
  # vhost is bound to the arrival address. The regression breaks :80 too, so :80 passing
  # means the listen config is right and only a cert/HTTPS vhost is absent.
  if [ "$port" = "443" ] && [ "$failed_before" -eq 0 ] && [ "$failed" -eq 1 ] \
    && [ "$STRICT_TLS" -eq 0 ] && [ "$CHECKS_PORT_80" -eq 1 ] && [ "$port80_ok" -eq 1 ]; then
    verdict="NO-TLS (no HTTPS vhost for this domain; :80 ok)"
    failed="$failed_before"
    warned=$((warned + 1))
  fi

  # Remember the plain-HTTP outcome for the :443 judgement on this same domain.
  if [ "$port" = "80" ]; then
    if [ "$verdict" = "ok" ]; then port80_ok=1; else port80_ok=0; fi
  fi

  if [ "$CHECK_ACME" -eq 1 ]; then
    local acme_code acme_body
    acme_code=$(curl -sk --max-time 15 -o /dev/null -w '%{http_code}' \
      "http://${d}/.well-known/acme-challenge/probe-test" \
      --resolve "${d}:80:${SERVER_IP}" 2>/dev/null)
    [ -n "$acme_code" ] || acme_code="000"
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
    json_items+=("$(printf '{"port":%s,"host":"%s","cert_cn":"%s","http":"%s","verdict":"%s","catchall_header":"%s"}' \
      "$port" "$d" "$cert_cn" "$code" "$verdict" "$catchall_hdr")")
  else
    printf '%-8s %-32s %-30s %-8s %s\n' "$port" "$d" "$cert_cn" "$code" "$verdict"
  fi
}

for d in "${DOMAINS[@]}"; do
  port80_ok=0
  for port in "${PORTS[@]}"; do
    check_one "$d" "$port"
  done
done

if [ "$JSON" -eq 1 ]; then
  printf '{"origin_ip":"%s","failed":%s,"warnings":%s,"results":[' "$SERVER_IP" "$failed" "$warned"
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
  if [ "$warned" -gt 0 ]; then
    echo "PASS: every domain is bound to the arrival address (:80 verified)."
    echo "NOTE: ${warned} domain(s) have no HTTPS vhost or certificate (NO-TLS above)."
    echo "      That is expected for parked domains and is not the catch-all regression."
    echo "      Use --strict-tls to treat those as failures instead."
  else
    echo "PASS: every domain matched its own vhost with a domain-appropriate certificate."
  fi
fi
exit 0
