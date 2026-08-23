#!/bin/bash
# Reconcile DirectAdmin Linked IP / lan_ip so every vhost listens on the
# address public traffic actually arrives on (primary private IP after EIP NAT).
#
# Modes:
#   --check     read-only; exit non-zero on drift (default)
#   --dry-run   same as --check but prints the enforce actions that would run
#   --enforce   apply Linked IP + lan_ip, synchronous rewrite, nginx -t gate
#
# Install:
#   install -m 755 da_vhost_listen_reconcile.sh /usr/local/sbin/da-vhost-listen-reconcile.sh
#   install -m 600 vhost-listen.conf.example /etc/da-vhost-listen/vhost-listen.conf
#   # edit EXPECTED_PUBLIC_IP / HEALTH_ALERT_TO
#
# Conventions match ensure_ses_gmail_aliases.sh (flock, /var/log, OK/FIXED/SKIP/ERROR).

set -euo pipefail

CONFIG="${DA_VHOST_LISTEN_CONF:-/etc/da-vhost-listen/vhost-listen.conf}"
LOG="${DA_VHOST_LISTEN_LOG:-/var/log/da-vhost-listen.log}"
LOCK_ROOT="${DA_VHOST_LISTEN_LOCK_DIR:-/var/lock}"
LOCK="${LOCK_ROOT}/da-vhost-listen.lock"
STATE_DIR="${DA_VHOST_LISTEN_STATE:-/var/lib/da-vhost-listen}"
ALERT_STAMP="${STATE_DIR}/alert.stamp"
ALERT_COOLDOWN_SEC="${DA_VHOST_LISTEN_ALERT_COOLDOWN:-3600}"
BACKUP_ROOT="${DA_VHOST_LISTEN_BACKUP:-/var/backups/da-vhost-listen}"

DA_CONF="${DA_CONF:-/usr/local/directadmin/conf/directadmin.conf}"
DA_BIN="${DA_BIN:-/usr/local/directadmin/directadmin}"
TASK_QUEUE="${DA_TASK_QUEUE:-/usr/local/directadmin/data/task.queue}"
IP_LIST="${DA_IP_LIST:-/usr/local/directadmin/data/admin/ip.list}"
IPS_DIR="${DA_IPS_DIR:-/usr/local/directadmin/data/admin/ips}"

HEALTH_ALERT_TO=""
EXPECTED_PUBLIC_IP=""
ARRIVAL_IP=""
ALLOWLIST_CATCHALL_HOSTS=""
ENFORCE_REQUIRE_PUBLIC_IP=""

MODE="check"

usage() {
  cat <<EOF
Usage: $0 [--check|--dry-run|--enforce]

  --check     Detect drift only (default). Exit 1 when arrival IP is missing
              from domain vhost listens or lan_ip / Linked IP is wrong.
  --dry-run   Like --check, but print the enforce steps that would run.
  --enforce   Register/link arrival IP, set lan_ip, rewrite httpd, gate on
              nginx -t, reload on success, revert + alert on failure.
EOF
}

log() {
  local msg
  msg="$(date -Iseconds) $*"
  if [[ -w "$(dirname "$LOG")" ]] 2>/dev/null || [[ -w "$LOG" ]] 2>/dev/null; then
    echo "$msg" >>"$LOG" 2>/dev/null || true
  fi
  echo "$msg" >&2
}

load_config() {
  if [[ -f "$CONFIG" ]]; then
    # shellcheck disable=SC1090
    source "$CONFIG"
  fi
}

imds_token() {
  curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 60" \
    --connect-timeout 2 --max-time 3 2>/dev/null || true
}

imds_get() {
  local path="$1" token="$2"
  curl -sS -H "X-aws-ec2-metadata-token: ${token}" \
    "http://169.254.169.254/latest/meta-data/${path}" \
    --connect-timeout 2 --max-time 3 2>/dev/null || true
}

detect_public_ip() {
  local token pub
  if [[ -n "${EXPECTED_PUBLIC_IP}" ]]; then
    echo "${EXPECTED_PUBLIC_IP}"
    return 0
  fi
  token="$(imds_token)"
  if [[ -n "$token" ]]; then
    pub="$(imds_get public-ipv4 "$token")"
    if [[ "$pub" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$pub"
      return 0
    fi
  fi
  return 1
}

# Prefer the ENI whose public-ipv4s contains our EIP, then its primary local-ipv4.
detect_arrival_ip() {
  local token macs mac pubs local_ips first route_ip
  if [[ -n "${ARRIVAL_IP}" ]]; then
    echo "${ARRIVAL_IP}"
    return 0
  fi
  token="$(imds_token)"
  if [[ -n "$token" ]]; then
    macs="$(imds_get network/interfaces/macs/ "$token" | tr -d '/')"
    for mac in $macs; do
      [[ -z "$mac" ]] && continue
      pubs="$(imds_get "network/interfaces/macs/${mac}/public-ipv4s" "$token" | tr '\n' ' ')"
      if [[ -n "${EXPECTED_PUBLIC_IP}" && " ${pubs} " != *" ${EXPECTED_PUBLIC_IP} "* ]]; then
        continue
      fi
      if [[ -z "${EXPECTED_PUBLIC_IP}" ]]; then
        # No expected EIP configured: take the first ENI that has any public IP.
        [[ -z "${pubs// /}" ]] && continue
      fi
      local_ips="$(imds_get "network/interfaces/macs/${mac}/local-ipv4s" "$token")"
      first="$(echo "$local_ips" | head -1 | tr -d '[:space:]')"
      if [[ "$first" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$first"
        return 0
      fi
    done
    # Fallback: bare local-ipv4
    first="$(imds_get local-ipv4 "$token" | tr -d '[:space:]')"
    if [[ "$first" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$first"
      return 0
    fi
  fi
  route_ip="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')"
  if [[ "$route_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "$route_ip"
    return 0
  fi
  return 1
}

current_lan_ip() {
  awk -F= '/^lan_ip=/{print $2; exit}' "$DA_CONF" 2>/dev/null || true
}

# Decode DA's percent-encoded linked_ips value into "ip<TAB>flags" lines.
# Observed forms after URL-decode:
#   172.30.0.87=apache=yes&dns=no
#   172.30.0.71=apache=yes&dns=no&172.30.0.87=apache=yes&dns=no
linked_ips_for() {
  local public_ip="$1"
  local f="${IPS_DIR}/${public_ip}"
  [[ -f "$f" ]] || return 0
  local raw
  raw="$(awk -F= '/^linked_ips=/{print substr($0, index($0,$2)); exit}' "$f" 2>/dev/null || true)"
  [[ -z "$raw" ]] && return 0
  python3 - "$raw" <<'PY' 2>/dev/null || true
import re, sys, urllib.parse
raw = sys.argv[1]
decoded = urllib.parse.unquote(raw)
# Split on boundaries before an IPv4=
parts = re.split(r'(?=(?:^|&)\d{1,3}(?:\.\d{1,3}){3}=)', decoded)
for part in parts:
    part = part.lstrip('&')
    if not part or '=' not in part:
        continue
    ip, flags = part.split('=', 1)
    if re.fullmatch(r'\d{1,3}(?:\.\d{1,3}){3}', ip):
        print(f"{ip}\t{flags}")
PY
}

arrival_linked() {
  local public_ip="$1" arrival="$2"
  local ip
  while IFS=$'\t' read -r ip _flags; do
    [[ "$ip" == "$arrival" ]] && return 0
  done < <(linked_ips_for "$public_ip")
  return 1
}

# Print Linked IPs on $public_ip that are not the arrival address (stale cutover IPs, etc.).
stale_linked_ips() {
  local public_ip="$1" arrival="$2"
  local ip
  while IFS=$'\t' read -r ip _flags; do
    [[ -z "$ip" || "$ip" == "$arrival" ]] && continue
    printf '%s\n' "$ip"
  done < <(linked_ips_for "$public_ip")
}

INVARIANT_BIN="${DA_VHOST_INVARIANT:-/usr/local/sbin/nginx-vhost-listen-invariant.sh}"
if [[ ! -x "$INVARIANT_BIN" ]]; then
  # Repo filename (underscore) if installed alongside the reconciler.
  INVARIANT_BIN="$(dirname "$(readlink -f "$0" 2>/dev/null || echo "$0")")/nginx_vhost_listen_invariant.sh"
fi

# Parse nginx -T (or a fixture file): for every server_name, require a listen
# covering $arrival on declared :80 / :443 ports. Prints FAIL lines; exit 1 on drift.
invariant_check() {
  local arrival="$1"
  local source="${2:-}"
  local -a args=(--arrival "$arrival")
  local tmp=""
  if [[ -n "${ALLOWLIST_CATCHALL_HOSTS:-}" ]]; then
    args+=(--allowlist "${ALLOWLIST_CATCHALL_HOSTS}")
  fi
  if [[ -n "$source" ]]; then
    args+=(--file "$source")
  else
    # Capture nginx -T here so the helper always gets a file (more reliable under cron/SSM).
    tmp="$(mktemp)"
    local nginx_bin
    nginx_bin="$(command -v nginx || true)"
    [[ -x "$nginx_bin" ]] || nginx_bin=/usr/sbin/nginx
    "$nginx_bin" -T >"$tmp" 2>/dev/null || "$nginx_bin" -T >"$tmp" 2>&1 || true
    args+=(--file "$tmp")
  fi
  if [[ ! -x "$INVARIANT_BIN" ]]; then
    log "ERROR invariant helper missing: $INVARIANT_BIN"
    [[ -n "$tmp" ]] && rm -f "$tmp"
    return 1
  fi
  "$INVARIANT_BIN" "${args[@]}"
  local rc=$?
  [[ -n "$tmp" ]] && rm -f "$tmp"
  return "$rc"
}

rate_limited_alert() {
  local subject="$1"
  local body="$2"
  mkdir -p "$STATE_DIR"
  local now last
  now="$(date +%s)"
  last=0
  [[ -f "$ALERT_STAMP" ]] && last="$(cat "$ALERT_STAMP" 2>/dev/null || echo 0)"
  if (( now - last < ALERT_COOLDOWN_SEC )); then
    log "SKIP alert cooldown (${ALERT_COOLDOWN_SEC}s)"
    return 0
  fi
  echo "$now" >"$ALERT_STAMP"
  if [[ -n "${HEALTH_ALERT_TO}" ]] && command -v mail >/dev/null 2>&1; then
    printf '%s\n' "$body" | mail -s "$subject" "$HEALTH_ALERT_TO" || true
    log "OK alert mailed to $HEALTH_ALERT_TO"
  else
    log "ERROR alert (no HEALTH_ALERT_TO or mail): $subject"
  fi
}

netmask_for_arrival() {
  local arrival="$1"
  # Prefer CIDR from `ip addr`; default /24 for RFC1918 if unknown.
  local cidr
  cidr="$(ip -4 -o addr show 2>/dev/null | awk -v a="$arrival" '$4 ~ ("^"a"/") {split($4,p,"/"); print p[2]; exit}')"
  case "$cidr" in
    8) echo 255.0.0.0 ;;
    16) echo 255.255.0.0 ;;
    24) echo 255.255.255.0 ;;
    32) echo 255.255.255.255 ;;
    *) echo 255.255.255.0 ;;
  esac
}

ip_registered() {
  local ip="$1"
  grep -qxF "$ip" "$IP_LIST" 2>/dev/null
}

backup_state() {
  local stamp="$1"
  local dest="${BACKUP_ROOT}/${stamp}"
  mkdir -p "$dest"
  cp -a "$DA_CONF" "$dest/directadmin.conf" 2>/dev/null || true
  cp -a "$IP_LIST" "$dest/ip.list" 2>/dev/null || true
  cp -a "$IPS_DIR" "$dest/ips" 2>/dev/null || true
  if [[ -d /etc/nginx ]]; then
    tar -C /etc -czf "$dest/nginx-etc.tgz" nginx 2>/dev/null || true
  fi
  # User nginx.conf snapshots (generated)
  tar -C /usr/local/directadmin/data -czf "$dest/users-nginx.tgz" \
    --wildcards 'users/*/nginx.conf' 2>/dev/null || true
  echo "$dest"
}

restore_state() {
  local dest="$1"
  [[ -d "$dest" ]] || return 1
  [[ -f "$dest/directadmin.conf" ]] && cp -a "$dest/directadmin.conf" "$DA_CONF"
  [[ -f "$dest/ip.list" ]] && cp -a "$dest/ip.list" "$IP_LIST"
  if [[ -d "$dest/ips" ]]; then
    rm -rf "${IPS_DIR}.bad" 2>/dev/null || true
    mkdir -p "$IPS_DIR"
    cp -a "$dest/ips/." "$IPS_DIR/"
  fi
  log "OK restored backup from $dest"
}

set_lan_ip() {
  local arrival="$1"
  if grep -q '^lan_ip=' "$DA_CONF"; then
    sed -i.bak-da-vhost -e "s/^lan_ip=.*/lan_ip=${arrival}/" "$DA_CONF"
  else
    echo "lan_ip=${arrival}" >>"$DA_CONF"
  fi
}

queue_linked_ip() {
  local public_ip="$1" arrival="$2"
  # Register private IP without touching the NIC (DA API via task.queue style).
  # Prefer task.queue linked_ips add with apply=yes.
  # Note: linked_ips *delete* via task.queue is a no-op on current DA ("unknown
  # taskq action"); use set_linked_ips_keep_only instead.
  printf 'action=linked_ips&ip_action=add&ip=%s&ip_to_link=%s&apache=yes&dns=no&apply=yes\n' \
    "$public_ip" "$arrival" >>"$TASK_QUEUE"
}

queue_register_ip() {
  local arrival="$1" mask="$2"
  # DirectAdmin IP manager add without adding to device.
  printf 'action=ipmanager&type=api&method=POST&command=CMD_API_IP_MANAGER&action=add&ip=%s&netmask=%s&add_to_device=no&add_to_device_aware=yes\n' \
    "$arrival" "$mask" >>"$TASK_QUEUE"
}

# Set EIP linked_ips to a single private IP (apache=yes, dns=no). Used to drop
# stale cutover Linked IPs — task.queue linked_ips delete does not work here.
set_linked_ips_keep_only() {
  local public_ip="$1" keep="$2"
  local f="${IPS_DIR}/${public_ip}"
  [[ -f "$f" ]] || {
    log "ERROR missing IP file $f"
    return 1
  }
  python3 - "$f" "$keep" <<'PY'
import pathlib, sys, urllib.parse
path = pathlib.Path(sys.argv[1])
keep = sys.argv[2]
enc = urllib.parse.quote(keep, safe="") + "=" + urllib.parse.quote("apache=yes&dns=no", safe="")
out = []
for line in path.read_text().splitlines():
    if line.startswith("linked_ips="):
        out.append("linked_ips=" + enc)
    else:
        out.append(line)
if not any(l.startswith("linked_ips=") for l in out):
    out.append("linked_ips=" + enc)
path.write_text("\n".join(out) + "\n")
raw = urllib.parse.unquote(enc)
assert keep in raw, raw
print(raw)
PY
  chown diradmin:diradmin "$f" 2>/dev/null || true
  chmod 600 "$f" 2>/dev/null || true
}

# Drop a leftover secondary from the NIC (best-effort; AWS may not own it).
remove_ip_from_device() {
  local ip="$1"
  local eth
  eth="$(ip -4 -o addr show to "${ip}/32" 2>/dev/null | awk '{print $2; exit}')"
  [[ -n "$eth" ]] || return 0
  if [[ -x /usr/local/directadmin/scripts/removeip ]]; then
    /usr/local/directadmin/scripts/removeip "$ip" >/dev/null 2>&1 || true
  fi
  if ip -4 addr show dev "$eth" 2>/dev/null | grep -q "inet ${ip}/"; then
    ip addr del "${ip}/24" dev "$eth" 2>/dev/null \
      || ip addr del "${ip}/32" dev "$eth" 2>/dev/null \
      || true
  fi
}

# Count generated listen lines for an address (must be 0 before ip addr del).
nginx_listen_count_for_ip() {
  local ip="$1"
  local nginx_bin tmp count
  nginx_bin="$(command -v nginx || true)"
  [[ -x "$nginx_bin" ]] || nginx_bin=/usr/sbin/nginx
  tmp="$(mktemp)"
  "$nginx_bin" -T >"$tmp" 2>/dev/null || "$nginx_bin" -T >"$tmp" 2>&1 || true
  count="$(grep -cE "listen[[:space:]]+${ip}([:[:space:]]|$)" "$tmp" 2>/dev/null || true)"
  rm -f "$tmp"
  printf '%s\n' "${count:-0}"
}

sync_rewrite() {
  "$DA_BIN" taskq --run 'action=rewrite&value=httpd'
}

nginx_test() {
  nginx -t
}

nginx_reload() {
  systemctl reload nginx
}

acquire_lock() {
  local nonblock="${1:-0}"
  mkdir -p "$LOCK_ROOT"
  exec 200>"$LOCK"
  if command -v flock >/dev/null 2>&1; then
    if [[ "$nonblock" == "1" ]]; then
      if ! flock -n 200; then
        log "SKIP lock busy ($LOCK)"
        exit 0
      fi
    else
      if ! flock -w 60 200; then
        log "ERROR could not lock $LOCK"
        exit 1
      fi
    fi
  else
    log "WARN flock unavailable; continuing without lock"
  fi
}

release_lock() {
  # Drop the flock so DA hooks can run --check during rewrite without deadlocking.
  if command -v flock >/dev/null 2>&1; then
    flock -u 200 2>/dev/null || true
  fi
  exec 200>&- 2>/dev/null || true
}

main() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --check) MODE=check; shift ;;
      --dry-run) MODE=dry-run; shift ;;
      --enforce) MODE=enforce; shift ;;
      -h|--help) usage; exit 0 ;;
      *) echo "Unknown arg: $1" >&2; usage; exit 2 ;;
    esac
  done

  load_config
  # Hooks run --check during httpd rewrite; never block them on the enforce lock.
  if [[ "$MODE" == "check" || "$MODE" == "dry-run" ]]; then
    acquire_lock 1
  else
    acquire_lock 0
  fi

  local arrival public_ip lan drift=0
  arrival="$(detect_arrival_ip)" || {
    log "ERROR could not detect arrival IP"
    exit 1
  }
  public_ip="$(detect_public_ip)" || public_ip=""
  lan="$(current_lan_ip)"

  log "OK mode=${MODE} arrival=${arrival} public=${public_ip:-unknown} lan_ip=${lan:-unset}"

  if [[ -n "$public_ip" && -n "${ENFORCE_REQUIRE_PUBLIC_IP}" && "$MODE" == "enforce" ]]; then
    if [[ "$public_ip" != "$ENFORCE_REQUIRE_PUBLIC_IP" ]]; then
      log "ERROR enforce refused: public ${public_ip} != required ${ENFORCE_REQUIRE_PUBLIC_IP}"
      exit 1
    fi
  fi

  if [[ "$lan" != "$arrival" ]]; then
    log "ERROR lan_ip drift: have=${lan:-unset} want=${arrival}"
    drift=1
  fi

  if [[ -n "$public_ip" ]]; then
    if ! arrival_linked "$public_ip" "$arrival"; then
      log "ERROR linked_ip missing: ${arrival} not linked to ${public_ip}"
      drift=1
    else
      log "OK linked_ip present: ${arrival} -> ${public_ip}"
    fi
    local stale
    while IFS= read -r stale; do
      [[ -z "$stale" ]] && continue
      log "ERROR stale linked_ip: ${stale} still linked to ${public_ip} (want only ${arrival})"
      drift=1
    done < <(stale_linked_ips "$public_ip" "$arrival")
  fi

  local invariant_failed=0
  if ! invariant_check "$arrival"; then
    log "ERROR nginx invariant: one or more server_names lack listen on ${arrival}"
    drift=1
    invariant_failed=1
  else
    # Scoped wording on purpose: the invariant only requires the arrival IP on the
    # ports each server block actually declares. Domains with no HTTPS block (parked
    # domains, ~40 here) are checked on :80 only, so claiming ":80 and :443" would
    # overstate TLS coverage and contradict check-vhost-listeners.sh NO-TLS warnings.
    log "OK nginx invariant: every server_name listens on ${arrival} for the ports it declares"
  fi

  if [[ "$drift" -eq 0 ]]; then
    log "OK no drift"
    exit 0
  fi

  if [[ "$MODE" == "check" ]]; then
    rate_limited_alert "da-vhost-listen drift on $(hostname -f)" \
      "arrival=${arrival} public=${public_ip:-unknown} lan_ip=${lan:-unset} mode=check"
    exit 1
  fi

  if [[ "$MODE" == "dry-run" ]]; then
    log "DRY-RUN would: register ${arrival} if needed, link to ${public_ip}, drop stale Linked IPs, set lan_ip, rewrite, remove stale secondaries from NIC, nginx -t, reload"
    exit 1
  fi

  # --enforce
  local stamp backup mask
  local -a stales_to_drop=()
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup="$(backup_state "$stamp")"
  log "OK backup at $backup"
  mask="$(netmask_for_arrival "$arrival")"

  if [[ -n "$public_ip" ]]; then
    while IFS= read -r stale; do
      [[ -z "$stale" ]] && continue
      stales_to_drop+=("$stale")
    done < <(stale_linked_ips "$public_ip" "$arrival")
  fi

  if [[ -n "$public_ip" ]] && ! ip_registered "$arrival"; then
    log "FIXED queue register IP ${arrival} netmask=${mask} add_to_device=no"
    queue_register_ip "$arrival" "$mask"
  else
    log "SKIP register IP (already in ip.list or no public IP)"
  fi

  local need_link_queue=0
  if [[ -n "$public_ip" ]] && ! arrival_linked "$public_ip" "$arrival"; then
    log "FIXED queue linked_ips add ${arrival} -> ${public_ip} apply=yes"
    queue_linked_ip "$public_ip" "$arrival"
    need_link_queue=1
  elif [[ -n "$public_ip" && "$invariant_failed" -eq 1 ]]; then
    log "FIXED queue linked_ips re-apply ${arrival} -> ${public_ip}"
    queue_linked_ip "$public_ip" "$arrival"
    need_link_queue=1
  fi

  set_lan_ip "$arrival"
  log "FIXED lan_ip=${arrival}"

  # Release flock before rewrite so user_httpd_write_post --check hooks do not deadlock.
  release_lock

  # Drain queued ipmanager / linked_ips *add* actions, then normalize linked_ips.
  if [[ -x "$DA_BIN" ]]; then
    timeout 120 "$DA_BIN" taskq --run 'action=nothing' >/dev/null 2>&1 || true
    if [[ -s "$TASK_QUEUE" ]]; then
      log "OK waiting briefly for task.queue drain"
      sleep 15
    fi
  fi

  if [[ -n "$public_ip" ]]; then
    # Keep-only strips stales (task.queue delete is a no-op on this DA build).
    if [[ "$need_link_queue" -eq 1 || "${#stales_to_drop[@]}" -gt 0 ]]; then
      log "FIXED set linked_ips keep-only ${arrival} on ${public_ip}"
      set_linked_ips_keep_only "$public_ip" "$arrival" || {
        log "ERROR failed to rewrite linked_ips on ${public_ip}"
        restore_state "$backup"
        rate_limited_alert "da-vhost-listen enforce FAILED on $(hostname -f)" "linked_ips file update failed"
        exit 1
      }
    fi
  fi

  if [[ -x "$DA_BIN" ]]; then
    timeout 300 "$DA_BIN" taskq --run 'action=rewrite&value=httpd' \
      || sync_rewrite
    log "OK rewrite httpd"
  else
    log "ERROR directadmin binary missing"
    restore_state "$backup"
    rate_limited_alert "da-vhost-listen enforce FAILED on $(hostname -f)" "missing directadmin binary"
    exit 1
  fi

  if ! nginx_test; then
    log "ERROR nginx -t failed after rewrite; reverting"
    restore_state "$backup"
    sync_rewrite || true
    rate_limited_alert "da-vhost-listen enforce REVERTED on $(hostname -f)" \
      "nginx -t failed; restored ${backup}"
    exit 1
  fi

  # Gate before NIC delete: configs must not still listen on stales (nginx -t
  # succeeds while the address remains assigned). Same order as the change-window.
  if ((${#stales_to_drop[@]} > 0)); then
    local stale count
    for stale in "${stales_to_drop[@]}"; do
      count="$(nginx_listen_count_for_ip "$stale")"
      if [[ "$count" -ne 0 ]]; then
        log "ERROR still ${count} listen line(s) for stale ${stale} after rewrite; reverting"
        restore_state "$backup"
        sync_rewrite || true
        nginx_test && nginx_reload || true
        rate_limited_alert "da-vhost-listen enforce REVERTED (stale listen) on $(hostname -f)" \
          "nginx -T still has listen ${stale}; restored ${backup}"
        exit 1
      fi
      log "OK no listen lines for stale ${stale}"
    done
  fi

  if ! invariant_check "$arrival"; then
    log "ERROR invariant still failing after rewrite (before NIC change); reverting"
    restore_state "$backup"
    sync_rewrite || true
    nginx_test && nginx_reload || true
    rate_limited_alert "da-vhost-listen enforce REVERTED (invariant) on $(hostname -f)" \
      "invariant failed after rewrite; restored ${backup}"
    exit 1
  fi

  if [[ -n "$public_ip" ]]; then
    local leftover
    leftover="$(stale_linked_ips "$public_ip" "$arrival" | tr '\n' ' ')"
    if [[ -n "${leftover// }" ]]; then
      log "ERROR stale linked_ip still present after rewrite: ${leftover}"
      restore_state "$backup"
      sync_rewrite || true
      nginx_test && nginx_reload || true
      rate_limited_alert "da-vhost-listen enforce REVERTED (stale linked_ip) on $(hostname -f)" \
        "stale still linked: ${leftover}; restored ${backup}"
      exit 1
    fi
  fi

  # Safe now: no listen on stales, arrival invariant holds, Linked IP file clean.
  if ((${#stales_to_drop[@]} > 0)); then
    local stale
    for stale in "${stales_to_drop[@]}"; do
      log "FIXED remove stale ${stale} from device (best-effort)"
      remove_ip_from_device "$stale"
    done
  fi

  if ! nginx_test; then
    log "ERROR nginx -t failed after removing stale addresses; reverting"
    restore_state "$backup"
    # Best-effort: re-add may need startips / manual; restore DA state + rewrite first.
    sync_rewrite || true
    nginx_test && nginx_reload || true
    rate_limited_alert "da-vhost-listen enforce REVERTED (post-del nginx -t) on $(hostname -f)" \
      "nginx -t failed after ip addr del; restored ${backup}"
    exit 1
  fi

  nginx_reload
  log "FIXED nginx reloaded"

  if ! invariant_check "$arrival"; then
    log "ERROR invariant still failing after reload; reverting"
    restore_state "$backup"
    sync_rewrite || true
    nginx_test && nginx_reload || true
    rate_limited_alert "da-vhost-listen enforce REVERTED (invariant post-reload) on $(hostname -f)" \
      "invariant failed after reload; restored ${backup}"
    exit 1
  fi

  log "OK enforce complete"
  exit 0
}

main "$@"
