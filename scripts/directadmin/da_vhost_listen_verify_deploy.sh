#!/bin/bash
# Weekly deploy-drift check for the da-vhost-listen tooling.
#
# install_da_vhost_listen.sh --verify answers "does the installed copy match this
# checkout?", but only when a human remembers to run it. This wrapper is what cron
# calls, and it widens the question to both halves of the drift that can hide a merged
# fix from production:
#
#   1. checkout vs origin  -- the box is sitting on an old commit, so --verify passes
#                             while still being wrong relative to main.
#   2. installed vs checkout -- someone pulled but never re-ran --install.
#
# Either one means a merged reconciler change is not what the host executes. Both have
# happened here. On drift this mails HEALTH_ALERT_TO from the same config the reconciler
# uses and exits non-zero; on a clean run it logs and exits 0.
#
# Install:
#   install -m 755 da_vhost_listen_verify_deploy.sh \
#     /usr/local/sbin/da-vhost-listen-verify-deploy.sh
#   # driven by the weekly entry in /etc/cron.d/da-vhost-listen
#
# Deliberately has no alert cooldown: it runs weekly, and drift that persists is worth
# one mail per week until someone runs --install.

set -euo pipefail

CONFIG="${DA_VHOST_LISTEN_CONF:-/etc/da-vhost-listen/vhost-listen.conf}"
LOG="${DA_VHOST_LISTEN_LOG:-/var/log/da-vhost-listen.log}"
REPO="${DA_VHOST_LISTEN_REPO:-/root/wbat-terraform}"
REMOTE_REF="${DA_VHOST_LISTEN_REMOTE_REF:-origin/main}"

HEALTH_ALERT_TO=""

log() {
  local msg
  msg="$(date -Iseconds) verify-deploy: $*"
  if [[ -w "$(dirname "$LOG")" ]] 2>/dev/null || [[ -w "$LOG" ]] 2>/dev/null; then
    echo "$msg" >>"$LOG" 2>/dev/null || true
  fi
  echo "$msg" >&2
}

if [[ -f "$CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$CONFIG"
fi

# Same guard as the reconciler: RFC 2606 names can never receive mail, so a copy-pasted
# placeholder must be reported as broken alerting rather than logged as a successful send.
alert() {
  local subject="$1" body="$2"
  local dest="${HEALTH_ALERT_TO}"
  local dest_lc="${dest,,}"

  if [[ -z "$dest" ]]; then
    log "ERROR alert not sent (HEALTH_ALERT_TO unset in ${CONFIG}): $subject"
    return 0
  fi
  if [[ "$dest_lc" =~ @([a-z0-9-]+\.)*(example\.(com|net|org)|example|invalid|test|localhost)$ ]]; then
    log "ERROR alert not sent (HEALTH_ALERT_TO=${dest} is a reserved placeholder; set a real address in ${CONFIG}): $subject"
    return 0
  fi
  if ! command -v mail >/dev/null 2>&1; then
    log "ERROR alert not sent (no mail binary; install s-nail or mailx): $subject"
    return 0
  fi

  printf '%s\n' "$body" | mail -s "$subject" "$dest" || true
  log "OK alert mailed to ${dest}"
}

host="$(hostname -f 2>/dev/null || hostname)"
drift=0
report=""

add() { report+="$1"$'\n'; }

if [[ ! -d "${REPO}/.git" ]]; then
  log "ERROR no git checkout at ${REPO} (set DA_VHOST_LISTEN_REPO)"
  alert "da-vhost-listen: no repo checkout on ${host}" \
    "Expected a wbat-terraform checkout at ${REPO} so deploy drift could be checked, but found none. Installed tooling cannot be compared against the repo until that exists."
  exit 1
fi

######################################################
# 1. checkout vs origin
######################################################
# A fetch failure is reported, not fatal: the installed-vs-checkout comparison below is
# still worth doing offline, and losing it would make a network blip look like success.
if git -C "$REPO" fetch --quiet origin 2>/dev/null; then
  local_head="$(git -C "$REPO" rev-parse --short HEAD)"
  if remote_head="$(git -C "$REPO" rev-parse --short "$REMOTE_REF" 2>/dev/null)"; then
    if [[ "$local_head" != "$remote_head" ]]; then
      behind="$(git -C "$REPO" rev-list --count "HEAD..${REMOTE_REF}" 2>/dev/null || echo '?')"
      if [[ "$behind" != "0" ]]; then
        add "STALE CHECKOUT: ${REPO} is at ${local_head}, ${behind} commit(s) behind ${REMOTE_REF} (${remote_head})."
        # Distinguish "behind, and the tooling changed" from "behind, but not in a way
        # that affects this host". An empty list here is the reassuring case, so say so
        # rather than printing a blank section the reader has to interpret.
        tooling_log="$(git -C "$REPO" log --oneline "HEAD..${REMOTE_REF}" -- scripts/directadmin/ 2>/dev/null | sed 's/^/    /' || true)"
        if [[ -n "$tooling_log" ]]; then
          add "  Unmerged-here commits touching scripts/directadmin/:"
          add "$tooling_log"
        else
          add "  None of those commits touch scripts/directadmin/, so the tooling itself is unchanged."
        fi
        drift=1
      else
        log "OK checkout at ${local_head} is not behind ${REMOTE_REF}"
      fi
    else
      log "OK checkout matches ${REMOTE_REF} (${local_head})"
    fi
  else
    add "WARN could not resolve ${REMOTE_REF}; skipped the checkout-vs-origin comparison."
  fi
else
  add "WARN git fetch failed in ${REPO}; could not tell whether this checkout is behind ${REMOTE_REF}."
fi

######################################################
# 2. installed vs checkout
######################################################
installer="${REPO}/scripts/directadmin/install_da_vhost_listen.sh"
if [[ ! -x "$installer" ]]; then
  add "ERROR ${installer} missing or not executable; cannot compare installed files to the repo."
  drift=1
else
  if verify_out="$("$installer" --verify 2>&1)"; then
    log "OK installed tooling matches ${REPO}"
  else
    add "INSTALLED TOOLING DRIFT (installed files differ from ${REPO}):"
    add "$(printf '%s\n' "$verify_out" | sed 's/^/    /')"
    drift=1
  fi
fi

if [[ "$drift" -eq 0 ]]; then
  log "OK no deploy drift"
  # Still surface any WARN lines (e.g. a failed fetch) so a partial check is not
  # mistaken for a full clean bill of health. Written as an if, not `[[ ... ]] &&`,
  # because under `set -e` the latter would abort the script on the empty-report path.
  if [[ -n "$report" ]]; then
    log "$(printf '%s' "$report" | tr '\n' ' ')"
  fi
  exit 0
fi

log "ERROR deploy drift detected"
# Log the detail as well as mailing it. Alerting can itself be broken (unset or
# placeholder HEALTH_ALERT_TO, no MTA), and in that case the log is the only place an
# operator can find out *what* drifted.
while IFS= read -r line; do
  [[ -n "$line" ]] && log "  $line"
done <<<"$report"

alert "da-vhost-listen: deploy drift on ${host}" \
  "The vhost-listen tooling running on ${host} is not what the repo says it should be.

${report}
Fix:
  cd ${REPO} && git pull
  sudo ./scripts/directadmin/install_da_vhost_listen.sh --install

Until then, any merged reconciler fix is not in effect on this host."
exit 1
