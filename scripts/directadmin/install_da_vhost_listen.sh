#!/bin/bash
# Install or verify the da-vhost-listen tooling from a repo checkout.
#
# This repo has no deploy pipeline: merging a reconciler fix does NOT update the copy
# running on the host. That is a real failure mode -- PRs #103 and #104 both changed
# reconciler behaviour while the host kept executing the previous version. Run
# --install after any merge touching these files, and --verify to detect an installed
# copy that has drifted from the repo.
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
DA_CUSTOM_DIR="${DA_VHOST_DA_CUSTOM_DIR:-/usr/local/directadmin/scripts/custom}"
HOOK_OWNER="${DA_VHOST_HOOK_OWNER:-diradmin:diradmin}"

MODE=""

usage() {
  sed -n '2,18p' "$0"
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
)

hash_of() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

verify() {
  local drift=0 entry src dst mode src_h dst_h
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
    if [[ "$src_h" != "$dst_h" ]]; then
      printf '%-46s %s\n' "$dst" "STALE (differs from repo)"
      drift=1
    else
      printf '%-46s %s\n' "$dst" "ok"
    fi
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
  mkdir -p "$SBIN_DIR" "$ETC_DIR" "$CRON_DIR" "$UNIT_DIR" \
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
