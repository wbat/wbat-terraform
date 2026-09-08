#!/bin/bash
# Install or verify the DirectAdmin ops tooling from a repo checkout: the vhost-listen
# reconciler, the S3 backup hooks, and the disk guard.
#
# This repo has no deploy pipeline: merging a fix does NOT update the copy running on the
# host. That is a real failure mode -- PRs #103 and #104 both changed reconciler
# behaviour while the host kept executing the previous version. Run --install after any
# merge touching these files, and --verify to detect an installed copy that has drifted
# from the repo.
#
# The backup hooks are covered here for the same reason. They were installed by hand from
# a README table, so nothing could answer "is the cleanup fix from 2026-09-06 the code
# that actually runs after tonight's backup?" -- and a stale hook there fills the root
# volume rather than merely failing to self-heal.
#
# Usage:
#   ./install_da_vhost_listen.sh --verify        # report drift; exit 1 if stale/missing
#   sudo ./install_da_vhost_listen.sh --install  # idempotent install/update
#
# --install never overwrites an existing /etc/da-vhost-listen/vhost-listen.conf, since
# that file holds host-specific values (EXPECTED_PUBLIC_IP, HEALTH_ALERT_TO).
#
# Paths are overridable by environment variable so this can be exercised without root.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SRC_DIR="${REPO_DIR}/scripts/directadmin"

SBIN_DIR="${DA_VHOST_SBIN_DIR:-/usr/local/sbin}"
ETC_DIR="${DA_VHOST_ETC_DIR:-/etc/da-vhost-listen}"
CRON_DIR="${DA_VHOST_CRON_DIR:-/etc/cron.d}"
UNIT_DIR="${DA_VHOST_UNIT_DIR:-/etc/systemd/system}"
LOGROTATE_DIR="${DA_VHOST_LOGROTATE_DIR:-/etc/logrotate.d}"
DA_CUSTOM_DIR="${DA_VHOST_DA_CUSTOM_DIR:-/usr/local/directadmin/scripts/custom}"
HOOK_OWNER="${DA_VHOST_HOOK_OWNER:-diradmin:diradmin}"

MODE=""

usage() {
  sed -n '2,23p' "$0"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --install) MODE=install; shift ;;
    --verify) MODE=verify; shift ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown arg: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$MODE" ]]; then
  echo "ERROR: pass --install or --verify" >&2
  usage >&2
  exit 2
fi

# src|dst|mode  -- content-compared files only. The runtime conf is handled separately
# because it is meant to diverge from the committed example.
MANAGED=(
  "da_vhost_listen_reconcile.sh|${SBIN_DIR}/da-vhost-listen-reconcile.sh|755"
  "nginx_vhost_listen_invariant.sh|${SBIN_DIR}/nginx-vhost-listen-invariant.sh|755"
  "da_vhost_listen_verify_deploy.sh|${SBIN_DIR}/da-vhost-listen-verify-deploy.sh|755"
  "cron.d-da-vhost-listen|${CRON_DIR}/da-vhost-listen|644"
  "da-vhost-listen-boot.service|${UNIT_DIR}/da-vhost-listen-boot.service|644"
  "user_httpd_write_post-da-vhost-listen-check.sh|${DA_CUSTOM_DIR}/user_httpd_write_post/da-vhost-listen-check.sh|700"
  # Backup hooks and disk guard. DirectAdmin runs the hooks below as root, so they keep
  # the default ownership rather than the diradmin ownership the vhost hook needs.
  "all_backups_post.sh|${DA_CUSTOM_DIR}/all_backups_post.sh|700"
  "system_backup_post.sh|${DA_CUSTOM_DIR}/system_backup_post.sh|700"
  "da_disk_guard.sh|${SBIN_DIR}/da-disk-guard.sh|755"
  "cron.d-da-disk-guard|${CRON_DIR}/da-disk-guard|644"
  "da_backup_batch.sh|${SBIN_DIR}/da-backup-batch.sh|755"
  "cron.d-da-backup-batch|${CRON_DIR}/da-backup-batch|644"
  "logrotate.d-da-ops|${LOGROTATE_DIR}/da-ops|644"
)

hash_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# GNU and BSD stat disagree on how to print a permission mode. Always exits 0 so a
# missing or unreadable file degrades to a visible "unknown" rather than aborting under
# set -e in the middle of a drift report.
mode_of() {
  stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1" 2>/dev/null || echo "unknown"
}

verify() {
  local drift=0 entry src dst mode src_h dst_h dst_mode state
  printf '%-46s %s\n' "INSTALLED PATH" "STATE"
  printf '%-46s %s\n' "--------------" "-----"
  for entry in "${MANAGED[@]}"; do
    IFS='|' read -r src dst mode <<<"$entry"
    src="${SRC_DIR}/${src}"
    if [[ ! -f "$src" ]]; then
      printf '%-46s %s\n' "$dst" "ERROR missing in repo: $src"
      drift=1
      continue
    fi
    if [[ ! -e "$dst" ]]; then
      printf '%-46s %s\n' "$dst" "MISSING (never installed)"
      drift=1
      continue
    fi
    src_h="$(hash_of "$src")"
    dst_h="$(hash_of "$dst")"
    dst_mode="$(mode_of "$dst")"
    state=""

    if [[ "$src_h" != "$dst_h" ]]; then
      state="STALE (differs from repo)"
      drift=1
    fi
    # Content-only comparison called this "ok". It matters most for the 700 hooks:
    # DirectAdmin cannot execute a hook that has lost its executable bit, so backups
    # accumulate on local disk while the drift check that exists to catch exactly that
    # reports the host as clean.
    if [[ "$dst_mode" != "$mode" ]]; then
      state="${state:+${state}; }MODE ${dst_mode} (expected ${mode})"
      drift=1
    fi

    printf '%-46s %s\n' "$dst" "${state:-ok}"
  done

  # Presence-only: contents are host-specific by design.
  if [[ -e "${ETC_DIR}/vhost-listen.conf" ]]; then
    printf '%-46s %s\n' "${ETC_DIR}/vhost-listen.conf" "present (host-specific; not compared)"
  else
    printf '%-46s %s\n' "${ETC_DIR}/vhost-listen.conf" "MISSING (reconciler has no config)"
    drift=1
  fi

  echo
  if [[ "$drift" -ne 0 ]]; then
    echo "FAIL: installed tooling does not match this checkout."
    echo "      Run: sudo $0 --install   (after 'git pull' on the box)"
    return 1
  fi
  echo "PASS: installed tooling matches this checkout."
  return 0
}

do_install() {
  local entry src dst mode
  mkdir -p "$SBIN_DIR" "$ETC_DIR" "$CRON_DIR" "$UNIT_DIR" "$LOGROTATE_DIR" \
    "${DA_CUSTOM_DIR}/user_httpd_write_post"

  for entry in "${MANAGED[@]}"; do
    IFS='|' read -r src dst mode <<<"$entry"
    src="${SRC_DIR}/${src}"
    if [[ ! -f "$src" ]]; then
      echo "ERROR missing in repo: $src" >&2
      return 1
    fi
    # The DA hook must be owned by diradmin; ownership is best-effort so this stays
    # runnable in a test sandbox where that user does not exist.
    if [[ "$dst" == *"/user_httpd_write_post/"* ]]; then
      install -m "$mode" "$src" "$dst"
      chown "$HOOK_OWNER" "$dst" 2>/dev/null \
        || echo "WARN could not chown $dst to $HOOK_OWNER"
    else
      install -m "$mode" "$src" "$dst"
    fi
    echo "installed $dst (mode $mode)"
  done

  if [[ ! -f "${ETC_DIR}/vhost-listen.conf" ]]; then
    install -m 600 "${SRC_DIR}/vhost-listen.conf.example" \
      "${ETC_DIR}/vhost-listen.conf"
    echo "created ${ETC_DIR}/vhost-listen.conf from example -- EDIT IT:"
    echo "  set EXPECTED_PUBLIC_IP and a real HEALTH_ALERT_TO"
  else
    echo "kept existing ${ETC_DIR}/vhost-listen.conf (host-specific; not overwritten)"
  fi

  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload || true
    systemctl enable da-vhost-listen-boot.service || true
  fi

  echo
  verify
}

case "$MODE" in
  verify) verify ;;
  install) do_install ;;
esac
