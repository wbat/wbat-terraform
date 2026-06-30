#!/usr/bin/env bash
# WBAT primary EBS shrink migration — validation helper
# Install: /usr/local/sbin/shrink-migration-validate.sh on OLD and NEW
# Usage: shrink-migration-validate.sh <mode> [args]
set -euo pipefail

MODE="${1:-help}"
NEW_IP="${2:-}"
OLD_IP="${OLD_IP:-172.30.0.87}"
RSYNC_USER="${RSYNC_USER:-ec2-user}"
RSYNC_SSH_OPTS="${RSYNC_SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=10}"
RSYNC_PATH="${RSYNC_PATH:---rsync-path=sudo rsync}"
EXPECTED_EIP="${EXPECTED_EIP:-44.214.133.234}"
EXPECTED_HOSTNAME="${EXPECTED_HOSTNAME:-server.wbat.net}"
RSYNC_EXCLUDES=(
  --exclude=/proc/*
  --exclude=/sys/*
  --exclude=/dev/*
  --exclude=/run/*
  --exclude=/tmp/*
  --exclude=/mnt/*
  --exclude=/media/*
  --exclude=/lost+found
  --exclude=/swapfile
  --exclude=/home/ec2-user/.ssh/authorized_keys
)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $*"; }
fail() { echo -e "${RED}FAIL${NC}: $*"; ERRORS=$((ERRORS + 1)); }
warn() { echo -e "${YELLOW}WARN${NC}: $*"; }
info() { echo "INFO: $*"; }

ERRORS=0
SERVICES=(directadmin httpd nginx mysqld mariadb exim dovecot named)

service_unit() {
  local s="$1"
  if systemctl list-unit-files "${s}.service" &>/dev/null; then
    echo "${s}.service"
  elif systemctl list-unit-files "mariadb.service" &>/dev/null && [[ "$s" == "mysqld" ]]; then
    echo "mariadb.service"
  else
    echo "${s}.service"
  fi
}

is_active() {
  local unit
  unit="$(service_unit "$1")"
  systemctl is-active --quiet "$unit" 2>/dev/null
}

is_inactive() {
  local unit
  unit="$(service_unit "$1")"
  ! systemctl is-active --quiet "$unit" 2>/dev/null
}

stop_production_services() {
  info "Stopping production services (OLD server cutover prep)..."
  systemctl stop crond 2>/dev/null || true
  for s in directadmin httpd nginx mysqld mariadb exim dovecot named; do
    unit="$(service_unit "$s")"
    if systemctl list-unit-files "$unit" &>/dev/null; then
      systemctl stop "$unit" 2>/dev/null || true
      info "stopped $unit"
    fi
  done
  sync
  sleep 2
  pass "stop_production_services completed"
}

verify_services_stopped() {
  info "Verifying production services are stopped..."
  local ok=1
  for s in "${SERVICES[@]}"; do
    unit="$(service_unit "$s")"
    if systemctl list-unit-files "$unit" &>/dev/null; then
      if is_active "$s"; then
        fail "Service still active: $unit"
        ok=0
      else
        pass "inactive: $unit"
      fi
    fi
  done
  if systemctl is-active --quiet crond 2>/dev/null; then
    warn "crond still active (optional to stop)"
  else
    pass "crond inactive"
  fi
  [[ "$ok" -eq 1 ]] || return 1
}

verify_rsync_diff() {
  local target_ip="${1:-$NEW_IP}"
  [[ -n "$target_ip" ]] || { fail "verify_rsync_diff requires NEW_IP"; return 1; }
  info "Dry-run rsync diff OLD -> ${target_ip} (must be empty)..."
  local diff
  diff="$(rsync -ani --delete "${RSYNC_EXCLUDES[@]}" $RSYNC_PATH -e "ssh $RSYNC_SSH_OPTS" \
    / "${RSYNC_USER}@${target_ip}:/" 2>/dev/null | grep -E '^[<>ch.*]' || true)"
  if [[ -z "$diff" ]]; then
    pass "rsync dry-run: zero file differences"
  else
    fail "rsync dry-run shows differences:"
    echo "$diff" | head -50
    local count
    count="$(echo "$diff" | wc -l)"
    [[ "$count" -gt 50 ]] && info "... and $((count - 50)) more lines"
    return 1
  fi
}

compare_dir_counts() {
  local target_ip="${1:-$NEW_IP}"
  [[ -n "$target_ip" ]] || { fail "compare_dir_counts requires NEW_IP"; return 1; }
  local dirs=(/home /usr/local/directadmin /var/lib/mysql /etc/httpd /etc/exim /root/.config/rclone)
  info "Comparing file counts on key directories..."
  for d in "${dirs[@]}"; do
    [[ -d "$d" ]] || continue
    local local_count remote_count remote_err
    local_count="$(find "$d" -xdev -type f 2>/dev/null | wc -l)"
    remote_err="$(ssh ${RSYNC_SSH_OPTS} "${RSYNC_USER}@${target_ip}" \
      "sudo /usr/bin/find '$d' -xdev -type f 2>/dev/null | wc -l" 2>&1 >/dev/null || true)"
    remote_count="$(ssh ${RSYNC_SSH_OPTS} "${RSYNC_USER}@${target_ip}" \
      "sudo /usr/bin/find '$d' -xdev -type f 2>/dev/null | wc -l" 2>/dev/null || echo "ERR")"
    if [[ "$remote_count" == "ERR" ]] || ! [[ "$remote_count" =~ ^[0-9]+$ ]]; then
      fail "cannot read remote $d (${remote_err:-ssh/sudo failed})"
    elif [[ "$local_count" == "$remote_count" ]]; then
      pass "$d file count: $local_count"
    else
      fail "$d file count mismatch local=$local_count remote=$remote_count"
    fi
  done
}

sample_xattrs() {
  local target_ip="${1:-}"
  local samples=(/home /usr/local/directadmin/conf)
  info "Sampling extended attributes (xattr) on critical paths..."
  for base in "${samples[@]}"; do
    [[ -d "$base" ]] || continue
    local f
    f="$(find "$base" -xdev -type f 2>/dev/null | head -1)"
    [[ -n "$f" ]] || continue
    if getfattr -d "$f" &>/dev/null; then
      pass "local xattr readable: $f"
    else
      warn "no xattrs or getfattr unavailable on $f"
    fi
    if [[ -n "$target_ip" ]]; then
      local remote_ok
      remote_ok="$(ssh $RSYNC_SSH_OPTS "${RSYNC_USER}@${target_ip}" \
        "sudo getfattr -d '$f' &>/dev/null && echo yes || echo no" 2>/dev/null || echo no)"
      if [[ "$remote_ok" == "yes" ]]; then
        pass "remote xattr readable: $f"
      else
        warn "remote xattr check failed for $f (path may differ pre-final-rsync)"
      fi
    fi
  done
}

verify_fstab() {
  info "Verifying /etc/fstab UUIDs exist on this system..."
  local uuid line dev
  while IFS= read -r line; do
    [[ "$line" =~ ^# ]] && continue
    [[ -z "${line// }" ]] && continue
    if [[ "$line" =~ UUID=([0-9a-fA-F-]+) ]]; then
      uuid="${BASH_REMATCH[1]}"
      if blkid | grep -q "$uuid"; then
        pass "fstab UUID present: $uuid"
      else
        fail "fstab UUID NOT found on disk: $uuid — line: $line"
      fi
    fi
  done < /etc/fstab
  if grep -q 'uquota,gquota' /etc/fstab; then
    pass "fstab has xfs quota options"
  else
    warn "fstab missing uquota,gquota (check if quotas expected)"
  fi
}

verify_boot_stack() {
  info "Boot stack checks..."
  if [[ -d /boot/efi ]]; then
    pass "/boot/efi exists"
  else
    warn "/boot/efi missing"
  fi
  if [[ -f /boot/grub2/grub.cfg ]] || [[ -f /boot/grub/grub.cfg ]]; then
    pass "grub.cfg present"
  else
    fail "grub.cfg not found"
  fi
  if ls /boot/initramfs-*.img &>/dev/null; then
    pass "initramfs images present"
  else
    fail "no initramfs images in /boot"
  fi
}

verify_disk_size() {
  local min_avail_gb="${1:-50}"
  info "Disk usage check..."
  df -h /
  local used_pct avail_kb
  used_pct="$(df / | tail -1 | awk '{print $5}' | tr -d '%')"
  avail_kb="$(df / | tail -1 | awk '{print $4}')"
  local avail_gb=$((avail_kb / 1024 / 1024))
  if [[ "$used_pct" -lt 85 ]]; then
    pass "root filesystem ${used_pct}% used"
  else
    fail "root filesystem ${used_pct}% used (>85%)"
  fi
  if [[ "$avail_gb" -ge "$min_avail_gb" ]]; then
    pass "available space ${avail_gb}GB (>= ${min_avail_gb}GB)"
  else
    fail "only ${avail_gb}GB free (need >= ${min_avail_gb}GB)"
  fi
}

verify_config_paths() {
  info "Critical config path checks..."
  local paths=(
    /usr/local/directadmin/directadmin
    /usr/local/directadmin/scripts/custom/all_backups_post.sh
    /root/.config/rclone/rclone.conf
    /usr/local/sbin/verify-backups-s3.sh
    /etc/named.conf
  )
  for p in "${paths[@]}"; do
    if [[ -e "$p" ]]; then
      pass "exists: $p"
    else
      fail "missing: $p"
    fi
  done
}

verify_da_license() {
  info "DirectAdmin license check..."
  if /usr/local/directadmin/directadmin license 2>/dev/null | grep -qiE 'valid|licensed|expires'; then
    pass "DirectAdmin license command OK"
  else
    warn "DirectAdmin license output unclear — verify manually after EIP attach"
  fi
}

verify_public_ip() {
  info "Public IP check (post-cutover)..."
  local ip
  ip="$(curl -sf --max-time 5 ifconfig.me 2>/dev/null || curl -sf --max-time 5 icanhazip.com 2>/dev/null || true)"
  if [[ "$ip" == "$EXPECTED_EIP" ]]; then
    pass "public IP is $EXPECTED_EIP"
  else
    fail "public IP is '${ip:-unknown}' expected $EXPECTED_EIP"
  fi
}

verify_hostname() {
  local hn
  hn="$(hostname -f 2>/dev/null || hostname)"
  if [[ "$hn" == "$EXPECTED_HOSTNAME" ]]; then
    pass "hostname: $hn"
  else
    fail "hostname '$hn' expected '$EXPECTED_HOSTNAME'"
  fi
}

verify_stack_configs() {
  info "Syntax checks for web/mail/DNS..."
  if command -v httpd &>/dev/null; then
    httpd -t &>/dev/null && pass "httpd -t" || fail "httpd -t"
  fi
  if command -v nginx &>/dev/null; then
    nginx -t &>/dev/null && pass "nginx -t" || fail "nginx -t"
  fi
  if command -v named-checkconf &>/dev/null && [[ -f /etc/named.conf ]]; then
    named-checkconf &>/dev/null && pass "named-checkconf" || fail "named-checkconf"
  fi
  if command -v mysql &>/dev/null && is_inactive mysqld; then
    info "mysql skipped (mysqld stopped)"
  elif command -v mysql &>/dev/null; then
    mysql -e "SELECT 1" &>/dev/null && pass "mysql SELECT 1" || fail "mysql SELECT 1"
  fi
}

start_production_services() {
  info "Starting production services (NEW server post-cutover)..."
  systemctl start crond 2>/dev/null || true
  for s in mysqld mariadb named exim dovecot httpd nginx directadmin; do
    unit="$(service_unit "$s")"
    if systemctl list-unit-files "$unit" &>/dev/null; then
      systemctl start "$unit" 2>/dev/null || warn "could not start $unit"
    fi
  done
  pass "start_production_services completed"
}

run_pre_cutover() {
  [[ -n "$NEW_IP" ]] || { fail "usage: $0 pre-cutover <NEW_IP>"; exit 1; }
  verify_services_stopped
  verify_rsync_diff "$NEW_IP"
  compare_dir_counts "$NEW_IP"
  sample_xattrs "$NEW_IP"
}

run_post_rsync_new() {
  info "=== POST-RSYNC validation (run on NEW instance) ==="
  verify_hostname
  verify_fstab
  verify_boot_stack
  verify_disk_size 50
  verify_config_paths
  sample_xattrs
}

run_post_cutover() {
  info "=== POST-CUTOVER validation (run on NEW instance after EIP) ==="
  verify_hostname
  verify_public_ip
  verify_disk_size 50
  verify_config_paths
  verify_da_license
  verify_stack_configs
  if [[ -x /usr/local/sbin/verify-backups-s3.sh ]]; then
    /usr/local/sbin/verify-backups-s3.sh && pass "S3 backup verify script" || warn "S3 verify script reported issues"
  fi
  for s in directadmin httpd nginx mysqld exim dovecot named; do
    unit="$(service_unit "$s")"
    if systemctl list-unit-files "$unit" &>/dev/null; then
      is_active "$s" && pass "active: $unit" || fail "not active: $unit"
    fi
  done
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <mode> [NEW_IP]

Modes:
  stop-services       Stop crond + DA/mail/web/mysql/DNS (OLD, before final rsync)
  verify-stopped      Confirm production services are inactive (OLD)
  rsync-diff <IP>     Dry-run rsync must show zero differences (OLD)
  compare-counts <IP> Compare file counts on key dirs (OLD)
  xattrs [IP]         Sample extended attributes local [and remote]
  pre-cutover <IP>    stop check + rsync-diff + counts + xattrs (OLD)
  post-rsync-new      fstab/boot/disk/config checks (NEW, before EIP)
  post-cutover        Full validation after EIP + services started (NEW)
  start-services      Start production stack (NEW)

Environment: OLD_IP, EXPECTED_EIP, EXPECTED_HOSTNAME
EOF
}

case "$MODE" in
  stop-services)      stop_production_services ;;
  verify-stopped)     verify_services_stopped ;;
  rsync-diff)         verify_rsync_diff "${2:-$NEW_IP}" ;;
  compare-counts)     compare_dir_counts "${2:-$NEW_IP}" ;;
  xattrs)             sample_xattrs "${2:-}" ;;
  pre-cutover)        run_pre_cutover ;;
  post-rsync-new)     run_post_rsync_new ;;
  post-cutover)       run_post_cutover ;;
  start-services)     start_production_services ;;
  help|-h|--help)     usage ;;
  *)
    fail "unknown mode: $MODE"
    usage
    exit 1
    ;;
esac

echo ""
if [[ "$ERRORS" -eq 0 ]]; then
  echo -e "${GREEN}All checks passed.${NC}"
  exit 0
else
  echo -e "${RED}${ERRORS} check(s) failed.${NC}"
  exit 1
fi
