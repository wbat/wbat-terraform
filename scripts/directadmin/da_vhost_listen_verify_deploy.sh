#!/bin/bash
# Weekly deploy-drift check for the da-vhost-listen tooling.
#
# install_da_vhost_listen.sh --verify answers "does the installed copy match this
# checkout?", but only when a human remembers to run it, and only relative to whatever
# that checkout happens to contain. This wrapper is what cron calls, and it covers every
# link in the chain from main to the running file:
#
#   1. checkout vs origin    -- the box is on an old commit, so --verify passes while
#                               still being wrong relative to main. Only counts as drift
#                               when the pending commits touch scripts/directadmin/;
#                               main advances constantly for Terraform and docs, and
#                               alerting on that would be a guaranteed weekly false
#                               alarm that teaches everyone to ignore the mail.
#   2. checkout tree vs its own commits -- a hand-edited file makes 1 and 3 agree while
#                               what runs matches no commit at all.
#   3. installed vs checkout -- someone pulled but never re-ran --install.
#
# Any of these means a merged reconciler change is not what the host executes. On drift
# this mails HEALTH_ALERT_TO from the same config the reconciler uses and exits non-zero;
# on a clean run it logs and exits 0. Findings that are informational rather than drift
# are logged as NOTE and do not affect the exit status.
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

  # Branch on the submission status rather than swallowing it with `|| true`. A local MTA
  # that rejects the message would otherwise be logged as "OK alert mailed", and since
  # cron discards stdout and mail is the only notification path, that false OK would hide
  # real deploy drift. stderr is captured because that is where an MTA explains itself.
  local mail_out mail_rc=0
  mail_out="$(printf '%s\n' "$body" | mail -s "$subject" "$dest" 2>&1)" || mail_rc=$?
  if (( mail_rc == 0 )); then
    log "OK alert mailed to ${dest}"
  else
    log "ERROR alert submission FAILED (mail rc=${mail_rc}) to ${dest}: ${mail_out:-no output}"
  fi
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
        # Being behind only counts as deploy drift when the pending commits actually
        # change the tooling. main advances constantly for Terraform and docs, and
        # alerting on that would mean a guaranteed weekly false alarm -- which trains
        # everyone to ignore the one mail that matters. So: tooling commits pending is a
        # failure, an unrelated lag is a logged note.
        tooling_log="$(git -C "$REPO" log --oneline "HEAD..${REMOTE_REF}" -- scripts/directadmin/ 2>/dev/null | sed 's/^/    /' || true)"
        if [[ -n "$tooling_log" ]]; then
          add "STALE TOOLING: ${REPO} is at ${local_head}, ${behind} commit(s) behind ${REMOTE_REF} (${remote_head}), including changes to scripts/directadmin/:"
          add "$tooling_log"
          drift=1
        else
          add "NOTE checkout is ${behind} commit(s) behind ${REMOTE_REF} (${local_head} vs ${remote_head}), but none of them touch scripts/directadmin/, so the installed tooling is still current. Not treated as drift."
        fi
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
# 2. checkout working tree vs its own commits
######################################################
# Step 3 compares installed files against the checkout's *working tree*, so a hand-edited
# file in the checkout makes both halves agree while what runs matches no commit at all.
# That is the quiet version of the same problem: "installed == checkout" stops being
# evidence about main. Untracked files are reported separately and are not drift, since
# the installer only ever copies the explicit MANAGED list.
dirty="$(git -C "$REPO" status --porcelain -- scripts/directadmin/ 2>/dev/null | grep -v '^??' || true)"
untracked="$(git -C "$REPO" status --porcelain -- scripts/directadmin/ 2>/dev/null | grep '^??' || true)"
if [[ -n "$dirty" ]]; then
  add "UNCOMMITTED TOOLING EDITS in ${REPO} -- installed files may match this checkout while matching no commit:"
  add "$(printf '%s\n' "$dirty" | sed 's/^/    /')"
  drift=1
fi
if [[ -n "$untracked" ]]; then
  add "NOTE untracked files under ${REPO}/scripts/directadmin/ (not installed, not drift):"
  add "$(printf '%s\n' "$untracked" | sed 's/^/    /')"
fi

######################################################
# 3. installed vs checkout
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

log_report() {
  while IFS= read -r line; do
    if [[ -n "$line" ]]; then
      log "  $line"
    fi
  done <<<"$report"
}

if [[ "$drift" -eq 0 ]]; then
  log "OK no deploy drift"
  # Still surface NOTE/WARN lines -- an unrelated lag, or a fetch that failed -- so a
  # partial or qualified pass is not mistaken for a full clean bill of health.
  if [[ -n "$report" ]]; then
    log_report
  fi
  exit 0
fi

log "ERROR deploy drift detected"
# Log the detail as well as mailing it. Alerting can itself be broken (unset or
# placeholder HEALTH_ALERT_TO, no MTA, an MTA that rejects the message), and in that case
# the log is the only place an operator can find out *what* drifted.
log_report

alert "da-vhost-listen: deploy drift on ${host}" \
  "The vhost-listen tooling running on ${host} is not what the repo says it should be.

${report}
Fix:
  cd ${REPO} && git pull
  sudo ./scripts/directadmin/install_da_vhost_listen.sh --install

Until then, any merged reconciler fix is not in effect on this host."
exit 1
