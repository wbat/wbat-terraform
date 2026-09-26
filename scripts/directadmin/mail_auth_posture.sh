#!/bin/bash
# Read-only SPF / DKIM / DMARC posture for every DirectAdmin mail domain on this host.
#
# The reason this exists rather than a one-line grep for `_dmarc`: a DMARC record can be
# present and still collect nothing. RFC 7489 7.1 makes a `rua` mailbox on another domain
# an *external destination*, which only works if that domain publishes
# `<policy-domain>._report._dmarc.<rua-domain>`. Spec-following reporters send nothing
# otherwise, so `rua=mailto:you@gmail.com` is reporting that silently never happens. This
# script resolves that record per destination and says UNAUTHORIZED when it is missing --
# the finding a presence check cannot make.
#
# DKIM is reported the same way, for the same reason. DirectAdmin signs from
# /etc/exim.dkim.conf with selector `x` and the key at
# /etc/virtual/<domain>/dkim.private.key, falling back to `{0}` -- do not sign -- when that
# file is absent. So a published `x._domainkey` proves nothing on its own: without the key
# the domain advertises a public key that nothing ever signs with, and a bare presence check
# calls that DKIM. The state is the pair, not the record.
#
# Changes nothing, reads only zone files and /etc/virtual. Exits 0 so it is safe on cron;
# pass --strict to exit 1 when there is an actionable finding.
#
# Usage:
#   mail_auth_posture.sh                 # table + summary + findings
#   mail_auth_posture.sh --strict        # exit 1 on any actionable finding
#   mail_auth_posture.sh --no-dns        # skip the rua authorization lookups
#   mail_auth_posture.sh --only <domain> # one domain
#
# Overridable for testing:
#   MAIL_AUTH_DOMAINOWNERS  MAIL_AUTH_ZONE_DIR  MAIL_AUTH_VIRTUAL_ROOT  MAIL_AUTH_RESOLVER
#   MAIL_AUTH_DKIM_SELECTOR

# Deliberately no -e: nearly every lookup here is a grep that is *expected* to fail on some
# domain, and aborting the sweep on the first one would report a partial host as a clean one.
set -uo pipefail

DOMAINOWNERS="${MAIL_AUTH_DOMAINOWNERS:-/etc/virtual/domainowners}"
ZONE_DIR="${MAIL_AUTH_ZONE_DIR:-/var/named}"
VIRTUAL_ROOT="${MAIL_AUTH_VIRTUAL_ROOT:-/etc/virtual}"
RESOLVER="${MAIL_AUTH_RESOLVER:-}"
# The selector Exim signs with. Anything published under a different one belongs to a third
# party (SES publishes CNAMEs, for instance) and is not what DirectAdmin would use.
DKIM_SELECTOR="${MAIL_AUTH_DKIM_SELECTOR:-x}"

use_dns=1
strict=0
only=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-dns) use_dns=0 ;;
    --strict) strict=1 ;;
    --only)
      shift
      only="${1:-}"
      [[ -z "$only" ]] && {
        echo "--only needs a domain" >&2
        exit 2
      }
      ;;
    -h | --help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [[ ! -f "$DOMAINOWNERS" ]]; then
  echo "no domainowners file at ${DOMAINOWNERS}" >&2
  exit 2
fi

if [[ -z "$RESOLVER" ]] && ! command -v dig >/dev/null 2>&1; then
  echo "NOTE dig not found, skipping rua authorization lookups"
  use_dns=0
fi

resolve_txt() {
  if [[ -n "$RESOLVER" ]]; then
    "$RESOLVER" "$1" 2>/dev/null
  else
    dig +short TXT "$1" 2>/dev/null
  fi
}

# First _dmarc TXT in a zone file, with the quoted strings of a split record joined.
# Matches both `_dmarc` and a fully qualified `_dmarc.example.com.` owner name.
dmarc_txt() {
  awk '
    tolower($1) ~ /^_dmarc(\.|$)/ && /TXT/ {
      out = ""
      n = split($0, parts, "\"")
      for (i = 2; i <= n; i += 2) out = out parts[i]
      if (out ~ /v=DMARC1/) { print out; exit }
    }
  ' "$1"
}

# Domain of each rua mailto: URI, lowercased, with any !size limit dropped.
rua_domains() {
  printf '%s\n' "$1" |
    tr ';' '\n' |
    grep -i 'rua=' |
    sed 's/.*[Rr][Uu][Aa]=//' |
    tr ',' '\n' |
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
      -e 's/^mailto://I' -e 's/!.*$//' |
    awk -F'@' 'NF == 2 && $2 != "" { print tolower($2) }'
}

# A destination under the policy domain is not external, so it needs no authorization.
# Compared both ways because either side may be the subdomain.
is_local_rua() {
  local policy="$1" rua="$2"
  [[ "$policy" == "$rua" ]] && return 0
  [[ "$rua" == *".${policy}" ]] && return 0
  [[ "$policy" == *".${rua}" ]] && return 0
  return 1
}

total=0
n_mail=0
n_pointer=0
n_no_dmarc=0
n_no_spf=0
n_dkim_signing=0
n_dkim_broken=0
n_dkim_stale=0
n_dkim_delegated=0
n_dkim_none=0
n_unauth=0
findings=()

printf '%-34s %-6s %-5s %-10s %-4s %-8s %s\n' DOMAIN DMARC SPF DKIM MBOX POINTER RUA
printf '%-34s %-6s %-5s %-10s %-4s %-8s %s\n' '------' '-----' '---' '----' '----' '-------' '---'

while read -r raw _; do
  # domainowners is `domain: user`, so the domain field arrives with a trailing colon.
  # Leaving it on turns every zone path into a miss and reports a host with no domains
  # at all, which reads exactly like a clean result.
  domain="${raw%:}"
  [[ -z "$domain" || "$domain" == \#* ]] && continue
  [[ -n "$only" && "$domain" != "$only" ]] && continue

  zone="${ZONE_DIR}/${domain}.db"
  if [[ ! -f "$zone" ]]; then
    findings+=("no_zone_file:${domain}")
    continue
  fi
  total=$((total + 1))

  has_spf=no
  has_mbox=no
  is_pointer=no
  grep -qi 'v=spf1' "$zone" && has_spf=yes
  [[ -s "${VIRTUAL_ROOT}/${domain}/passwd" ]] && has_mbox=yes

  # DKIM is the pair, not the record. Exim signs only when the private key exists, so the
  # key decides whether anything is signed and the record decides whether it can be
  # verified -- and each without the other is its own kind of broken.
  dkim_key=no
  dkim_own_record=no
  dkim_other_record=no
  [[ -s "${VIRTUAL_ROOT}/${domain}/dkim.private.key" ]] && dkim_key=yes
  grep -qiE "^${DKIM_SELECTOR}\._domainkey" "$zone" && dkim_own_record=yes
  grep -qiE '^[a-z0-9_-]+\._domainkey' "$zone" && dkim_other_record=yes

  if [[ "$dkim_key" == yes && "$dkim_own_record" == yes ]]; then
    dkim_state=signing
    n_dkim_signing=$((n_dkim_signing + 1))
  elif [[ "$dkim_key" == yes ]]; then
    # Signing with a key nobody can fetch. Worse than not signing, because every receiver
    # now sees a signature that fails rather than a message that never claimed one.
    dkim_state=BROKEN
    n_dkim_broken=$((n_dkim_broken + 1))
    findings+=("dkim_broken_unpublished:${domain}")
  elif [[ "$dkim_own_record" == yes ]]; then
    # Advertises a public key with no signer behind it. Harmless in itself, but it is what
    # makes a bare record check report DKIM on a domain whose mail is entirely unsigned.
    dkim_state=stale
    n_dkim_stale=$((n_dkim_stale + 1))
    findings+=("dkim_record_without_key:${domain}")
  elif [[ "$dkim_other_record" == yes ]]; then
    # Another selector, so something else signs -- SES publishes CNAMEs this way. Reported
    # rather than judged: this script cannot see that provider's key.
    dkim_state=delegated
    n_dkim_delegated=$((n_dkim_delegated + 1))
  else
    dkim_state=none
    n_dkim_none=$((n_dkim_none + 1))
  fi
  # A DirectAdmin domain pointer is a symlink to the target's config directory, so it
  # shares the target's passwd and looks like a mail domain in its own right. Flagged
  # rather than skipped: it is a real recipient, but it is not a separate thing to fix.
  [[ -L "${VIRTUAL_ROOT}/${domain}" ]] && is_pointer=yes

  record="$(dmarc_txt "$zone")"
  has_dmarc=no
  rua_state="-"
  if [[ -n "$record" ]]; then
    has_dmarc=yes
    mapfile -t ruas < <(rua_domains "$record")
    if [[ ${#ruas[@]} -eq 0 ]]; then
      rua_state="none"
      findings+=("dmarc_without_rua:${domain}")
    else
      states=()
      for rua in "${ruas[@]}"; do
        if is_local_rua "$domain" "$rua"; then
          states+=("local")
        elif [[ "$use_dns" -eq 0 ]]; then
          states+=("external?")
        elif resolve_txt "${domain}._report._dmarc.${rua}" | grep -qi 'v=DMARC1'; then
          states+=("authorized")
        else
          states+=("UNAUTHORIZED")
          n_unauth=$((n_unauth + 1))
          findings+=("rua_unauthorized:${domain}->${rua}")
        fi
      done
      rua_state="$(
        IFS=,
        echo "${states[*]}"
      )"
    fi
  fi

  [[ "$has_mbox" == yes ]] && n_mail=$((n_mail + 1))
  [[ "$is_pointer" == yes ]] && n_pointer=$((n_pointer + 1))
  [[ "$has_spf" == no ]] && n_no_spf=$((n_no_spf + 1))
  if [[ "$has_dmarc" == no ]]; then
    n_no_dmarc=$((n_no_dmarc + 1))
    # A domain that never sends is the cheapest DMARC win, not a lesser one: nothing can
    # break, and without a record anyone may spoof it.
    if [[ "$has_mbox" == yes && "$is_pointer" == no ]]; then
      findings+=("no_dmarc_has_mail:${domain}")
    elif [[ "$is_pointer" == no ]]; then
      findings+=("no_dmarc_no_mail:${domain}")
    fi
  fi

  printf '%-34s %-6s %-5s %-10s %-4s %-8s %s\n' \
    "$domain" "$has_dmarc" "$has_spf" "$dkim_state" "$has_mbox" "$is_pointer" "$rua_state"
done <"$DOMAINOWNERS"

echo
echo "zones examined:        ${total}"
echo "with mailboxes:        ${n_mail}"
echo "domain pointers:       ${n_pointer}"
echo "missing DMARC:         ${n_no_dmarc}"
echo "missing SPF:           ${n_no_spf}"
echo "DKIM signing:          ${n_dkim_signing}"
echo "DKIM BROKEN:           ${n_dkim_broken}"
echo "DKIM stale record:     ${n_dkim_stale}"
echo "DKIM delegated:        ${n_dkim_delegated}"
echo "DKIM none:             ${n_dkim_none}"
echo "rua UNAUTHORIZED:      ${n_unauth}"

if [[ ${#findings[@]} -gt 0 ]]; then
  echo
  echo "findings:"
  printf '  %s\n' "${findings[@]}" | sort
fi

# --strict keys on the two findings that are actively misleading rather than merely absent:
# a rua that looks configured and reports nowhere, and a signature no receiver can verify.
# A missing record is honest about itself and is a backlog item, not a regression.
if [[ "$strict" -eq 1 ]] && ((n_unauth > 0 || n_dkim_broken > 0)); then
  exit 1
fi
exit 0
