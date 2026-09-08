#!/bin/bash
# Report the brute-force posture of every password-accepting login path on this
# host: SSH, DirectAdmin on 2222, mail, and FTP.
#
# Why this exists: this repository is public and its git history contains a
# verbatim capture of the box, so the DirectAdmin account names are permanently
# disclosed. Account names cannot be un-published, which means the control that
# matters is making them useless -- key-only SSH, a working fail2ban, and a
# restricted 2222. This script measures whether that is true today.
#
# Usage:
#   host_access_audit.sh [--json]
#
# Read-only by design. It never edits a config, never restarts a service, and
# never touches a firewall -- locking yourself out of a box serving ~91 sites is
# a worse outcome than any finding it could report. Remediation is the runbook:
# aws/docs/host-access-hardening.md
#
# Run it with sudo. Most of the interesting state (sshd -T, fail2ban-client,
# socket owners) is root-only, and unprivileged runs degrade to SKIP rather than
# guessing.
#
# Exit status: 0 = no findings, 1 = at least one finding, 2 = usage error.

set -uo pipefail

JSON=0
while [ $# -gt 0 ]; do
  case "$1" in
    --json) JSON=1; shift ;;
    -h | --help) sed -n '2,23p' "$0"; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

IS_ROOT=0
[ "$(id -u)" -eq 0 ] && IS_ROOT=1

findings=0
json_items=()

# verdict: OK (as intended) | WARN (weak, not necessarily wrong) | FAIL (an
# exposed password path) | SKIP (could not determine -- never counted as OK,
# because "I could not look" and "it is fine" must not read the same).
report() {
  local verdict="$1" area="$2" detail="$3"
  case "$verdict" in
    FAIL | WARN) findings=$((findings + 1)) ;;
  esac
  if [ "$JSON" -eq 1 ]; then
    json_items+=("$(printf '{"area":"%s","verdict":"%s","detail":"%s"}' \
      "$area" "$verdict" "$(printf '%s' "$detail" | sed 's/\\/\\\\/g; s/"/\\"/g')")")
  else
    printf '%-5s %-22s %s\n' "$verdict" "$area" "$detail"
  fi
}

have() { command -v "$1" >/dev/null 2>&1; }

# --- SSH ---------------------------------------------------------------------
# `sshd -T` is the only honest source: it resolves defaults and Match blocks,
# which grepping sshd_config does not. An option absent from the file is still
# in effect via its compiled-in default, and that default is "yes" for password
# auth on most builds -- exactly the case a grep would miss.
audit_ssh() {
  local dump=""
  if [ -n "${HOST_AUDIT_SSHD_T_FILE:-}" ]; then
    # Test hook: read a captured `sshd -T` instead of running sshd, so the
    # classification below can be proved offline against known-bad configs.
    dump="$(cat "$HOST_AUDIT_SSHD_T_FILE" 2>/dev/null)"
  elif [ "$IS_ROOT" -eq 1 ] && have sshd; then
    dump="$(sshd -T 2>/dev/null)"
  elif [ "$IS_ROOT" -eq 1 ] && [ -x /usr/sbin/sshd ]; then
    dump="$(/usr/sbin/sshd -T 2>/dev/null)"
  fi

  if [ -z "$dump" ]; then
    report SKIP "ssh/config" "need root and sshd to resolve effective config (sshd -T)"
    return
  fi

  local pw kbd pam root_login port allow
  pw="$(printf '%s\n' "$dump" | awk '$1=="passwordauthentication"{print $2}')"
  kbd="$(printf '%s\n' "$dump" | awk '$1=="kbdinteractiveauthentication"{print $2}')"
  pam="$(printf '%s\n' "$dump" | awk '$1=="usepam"{print $2}')"
  root_login="$(printf '%s\n' "$dump" | awk '$1=="permitrootlogin"{print $2}')"
  port="$(printf '%s\n' "$dump" | awk '$1=="port"{print $2}' | paste -sd, -)"
  allow="$(printf '%s\n' "$dump" | awk '$1=="allowusers"||$1=="allowgroups"{print $1"="$2}' | paste -sd' ' -)"

  if [ "$pw" = "no" ]; then
    report OK "ssh/password" "PasswordAuthentication no"
  else
    report FAIL "ssh/password" "PasswordAuthentication ${pw:-unknown} -- disclosed account names are directly guessable here"
  fi

  # The classic hole: passwords are turned off in the obvious place while PAM
  # keyboard-interactive still accepts them, so the box stays brute-forceable
  # and the config reads as hardened.
  if [ "$kbd" = "yes" ] && [ "$pam" = "yes" ]; then
    report FAIL "ssh/kbd-interactive" "KbdInteractiveAuthentication yes with UsePAM yes -- passwords still reachable even if PasswordAuthentication is no"
  else
    report OK "ssh/kbd-interactive" "KbdInteractiveAuthentication ${kbd:-no}, UsePAM ${pam:-unknown}"
  fi

  case "$root_login" in
    no | forced-commands-only) report OK "ssh/root" "PermitRootLogin $root_login" ;;
    prohibit-password | without-password) report WARN "ssh/root" "PermitRootLogin $root_login -- key-only root; prefer no" ;;
    *) report FAIL "ssh/root" "PermitRootLogin ${root_login:-unknown}" ;;
  esac

  report OK "ssh/port" "listening port(s): ${port:-unknown}"

  if [ -n "$allow" ]; then
    report OK "ssh/allowlist" "$allow"
  else
    report WARN "ssh/allowlist" "no AllowUsers/AllowGroups -- every account with a shell can attempt SSH"
  fi
}

# --- fail2ban ----------------------------------------------------------------
# Running is not the same as working. A jail watching a logpath that does not
# exist on this distro reports "active" forever and bans nothing, which is worse
# than no fail2ban because the dashboard looks green. Total bans is the cheapest
# evidence that a jail is actually reading real logs.
audit_fail2ban() {
  if ! have fail2ban-client; then
    report FAIL "fail2ban/installed" "not installed -- nothing rate-limits password guessing"
    return
  fi
  if ! systemctl is-active --quiet fail2ban 2>/dev/null; then
    report FAIL "fail2ban/running" "installed but not active"
    return
  fi
  report OK "fail2ban/running" "active"

  if [ "$IS_ROOT" -ne 1 ]; then
    report SKIP "fail2ban/jails" "need root to query fail2ban-client"
    return
  fi

  local jails
  jails="$(fail2ban-client status 2>/dev/null | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' ')"
  if [ -z "$jails" ]; then
    report FAIL "fail2ban/jails" "no jails configured"
    return
  fi
  report OK "fail2ban/jails" "$(printf '%s' "$jails" | tr ',' ' ')"

  # Name the paths that the disclosed account names actually expose. DA builds
  # vary in jail naming, so match loosely rather than demanding exact names.
  local want missing=""
  for want in ssh directadmin exim dovecot proftpd pure-ftpd; do
    case ",$jails," in
      *"$want"*) ;;
      *) missing="$missing $want" ;;
    esac
  done
  if [ -n "$missing" ]; then
    report WARN "fail2ban/coverage" "no jail matching:${missing} (some may not apply to this build)"
  else
    report OK "fail2ban/coverage" "ssh, directadmin, mail and ftp all covered"
  fi

  local total=0 jail n
  for jail in $(printf '%s' "$jails" | tr ',' ' '); do
    n="$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Total banned:[[:space:]]*//p' | head -1)"
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    total=$((total + n))
  done
  if [ "$total" -gt 0 ]; then
    report OK "fail2ban/effective" "$total total bans across all jails -- jails are reading real logs"
  else
    report WARN "fail2ban/effective" "zero bans ever recorded; on an internet-facing host that usually means a jail is watching a logpath that does not exist"
  fi
}

# --- DirectAdmin -------------------------------------------------------------
audit_directadmin() {
  local conf=/usr/local/directadmin/conf/directadmin.conf
  if [ ! -r "$conf" ]; then
    report SKIP "da/brute-force" "cannot read $conf (need root, or DA not installed)"
    return
  fi
  # Report what the build actually defines rather than asserting option names:
  # they differ across DA versions, and a check that asserts a key this build
  # does not have would report a problem that cannot exist.
  local keys
  keys="$(grep -E '^(brute|blacklist|max_.*brute)' "$conf" 2>/dev/null | paste -sd' ' -)"
  if [ -z "$keys" ]; then
    report WARN "da/brute-force" "no brute_force*/blacklist* keys set -- DA's own log scanner is at its defaults"
  else
    report OK "da/brute-force" "$keys"
  fi
}

# --- What is actually reachable ----------------------------------------------
# Ground truth. Config files describe intent; the listening socket and the
# firewall decide what an attacker can reach.
audit_exposure() {
  if ! have ss; then
    report SKIP "exposure/listeners" "ss not available"
    return
  fi
  local open
  open="$(ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -E '^(0\.0\.0\.0|\[::\]|\*):' | sed 's/.*://' | sort -un | paste -sd, -)"
  if [ -n "$open" ]; then
    report OK "exposure/listeners" "world-bound ports: $open"
  else
    report SKIP "exposure/listeners" "could not enumerate listeners"
  fi

  case ",$open," in
    *,2222,*) report WARN "exposure/da-panel" "DirectAdmin 2222 is bound to all interfaces; restrict it to known source addresses at the security group or host firewall" ;;
    *) report OK "exposure/da-panel" "2222 not world-bound" ;;
  esac

  local fw="none"
  have csf && fw="csf"
  systemctl is-active --quiet firewalld 2>/dev/null && fw="firewalld"
  if [ "$fw" = "none" ] && have nft && [ "$IS_ROOT" -eq 1 ] && [ -n "$(nft list ruleset 2>/dev/null)" ]; then
    fw="nftables"
  fi
  if [ "$fw" = "none" ]; then
    report WARN "exposure/firewall" "no host firewall detected -- the EC2 security group is the only filter"
  else
    report OK "exposure/firewall" "$fw"
  fi
}

# --- Account surface ---------------------------------------------------------
# Count only. The names are already public in this repo's history; reprinting
# them here would add exposure without adding information.
audit_accounts() {
  if [ ! -r /etc/passwd ]; then
    report SKIP "accounts/shells" "cannot read /etc/passwd"
    return
  fi
  local n
  n="$(awk -F: '$7 !~ /(nologin|false|sync|shutdown|halt)$/ && $3 >= 500 {c++} END {print c+0}' /etc/passwd)"
  report OK "accounts/shells" "$n non-system accounts with a login shell (these are the names in public git history)"
}

# --- SSM out-of-band path ----------------------------------------------------
# This is the reason SSH lockdown is safe to attempt here: Session Manager does
# not depend on sshd, port 22, 2222, or any security-group ingress. Confirm it
# is healthy BEFORE changing anything, because it is the rollback path.
audit_ssm() {
  if ! systemctl list-unit-files 2>/dev/null | grep -q amazon-ssm-agent; then
    report WARN "ssm/agent" "amazon-ssm-agent not installed -- no out-of-band path; do NOT tighten SSH without another way in"
    return
  fi
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    report OK "ssm/agent" "active -- out-of-band recovery path available if an SSH change locks you out"
  else
    report FAIL "ssm/agent" "installed but not running -- restore it before tightening SSH"
  fi
}

[ "$JSON" -eq 1 ] || {
  echo "Host access audit -- $(hostname 2>/dev/null || echo unknown) -- $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ "$IS_ROOT" -eq 1 ] || echo "(running unprivileged: root-only checks report SKIP)"
  echo
}

audit_ssm
audit_ssh
audit_fail2ban
audit_directadmin
audit_exposure
audit_accounts

if [ "$JSON" -eq 1 ]; then
  printf '{"findings":%d,"items":[%s]}\n' "$findings" "$(IFS=,; printf '%s' "${json_items[*]}")"
else
  echo
  if [ "$findings" -eq 0 ]; then
    echo "PASS: no findings."
  else
    echo "$findings finding(s). Remediation: aws/docs/host-access-hardening.md"
    echo "Apply in the order given there; it keeps an SSM session as the rollback path."
  fi
fi

[ "$findings" -eq 0 ] || exit 1
exit 0
