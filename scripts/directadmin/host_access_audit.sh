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
# Exit status: 0 = complete audit, no findings
#              1 = at least one finding
#              2 = usage error
#              3 = no findings, but the audit was incomplete (something was
#                  skipped, so "no findings" does not mean "no exposure")

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
skips=0
skipped_areas=""
json_items=()

# verdict: OK (as intended) | WARN (weak, not necessarily wrong) | FAIL (an
# exposed password path) | SKIP (could not determine).
#
# SKIP is counted separately and makes the whole audit incomplete, because an
# unprivileged run can otherwise reach the end having never inspected SSH,
# fail2ban or DirectAdmin and still print "no findings" with exit 0. Automation
# that trusted that would be accepting a posture nothing ever looked at.
report() {
  local verdict="$1" area="$2" detail="$3"
  case "$verdict" in
    FAIL | WARN) findings=$((findings + 1)) ;;
    SKIP)
      skips=$((skips + 1))
      skipped_areas="$skipped_areas $area"
      ;;
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
# `sshd -T` beats grepping sshd_config: an option absent from the file is still
# in effect via its compiled-in default, and that default is "yes" for password
# auth on most builds -- exactly the case a grep would miss.
#
# But bare `sshd -T` prints the *base* configuration only. Match blocks are
# evaluated against connection parameters, which sshd(8) takes from -C, so a
# `Match User someuser` that re-enables passwords is invisible to `sshd -T` and
# the host reads as hardened while an exposed account can still be brute-forced.
# audit_ssh_match below probes those contexts; this function must not be read as
# covering them.
sshd_bin() {
  if have sshd; then echo sshd
  elif [ -x /usr/sbin/sshd ]; then echo /usr/sbin/sshd
  else return 1
  fi
}

# Effective config for one connection context, or empty if it cannot be taken.
sshd_dump_for() {
  local ctx="$1" bin who
  if [ -n "${HOST_AUDIT_SSHD_T_CTX_DIR:-}" ]; then
    # Test hook: <ctx-dir>/<user>.txt stands in for `sshd -T -C user=<user>,...`
    who="${ctx%%,*}"
    cat "${HOST_AUDIT_SSHD_T_CTX_DIR}/${who#user=}.txt" 2>/dev/null
    return 0
  fi
  [ "$IS_ROOT" -eq 1 ] || return 1
  bin="$(sshd_bin)" || return 1
  "$bin" -T -C "$ctx" 2>/dev/null
}

audit_ssh() {
  local dump="" bin
  if [ -n "${HOST_AUDIT_SSHD_T_FILE:-}" ]; then
    # Test hook: read a captured `sshd -T` instead of running sshd, so the
    # classification below can be proved offline against known-bad configs.
    dump="$(cat "$HOST_AUDIT_SSHD_T_FILE" 2>/dev/null)"
  elif [ "$IS_ROOT" -eq 1 ] && bin="$(sshd_bin)"; then
    dump="$("$bin" -T 2>/dev/null)"
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
    report OK "ssh/password" "PasswordAuthentication no (base config; see ssh/match)"
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

# Match blocks, which bare `sshd -T` does not evaluate. Re-resolve the config
# per connection context and look for any context that re-enables a password
# path, then say plainly which contexts were not exhausted.
audit_ssh_match() {
  local cfg="${HOST_AUDIT_SSHD_CONFIG:-/etc/ssh/sshd_config}"
  local -a cfgs=()
  [ -r "$cfg" ] && cfgs+=("$cfg")
  # Include'd fragments are where distro packages hide their Match blocks.
  if [ -r "$cfg" ]; then
    local inc dir
    while read -r inc; do
      for dir in $inc; do
        # shellcheck disable=SC2206 # word-splitting the glob is the point
        for f in $dir; do [ -r "$f" ] && cfgs+=("$f"); done
      done
    done < <(awk 'tolower($1)=="include"{$1="";print}' "$cfg" 2>/dev/null)
  fi

  if [ "${#cfgs[@]}" -eq 0 ]; then
    report SKIP "ssh/match" "cannot read $cfg -- conditional blocks unexamined"
    return
  fi

  local criteria
  criteria="$(awk 'tolower($1)=="match"{$1=""; print}' "${cfgs[@]}" 2>/dev/null \
    | tr ' ' '\n' | grep -v '^$' | grep -viE '^(all)$' | sort -u | paste -sd' ' -)"
  if [ -z "$criteria" ]; then
    report OK "ssh/match" "no Match blocks -- the base config above is the whole config"
    return
  fi

  # Probe the accounts named in public git history, since those are the ones an
  # attacker would target, plus root. A documentation address stands in for "the
  # internet", which is the most exposed context.
  local users probe_addr=203.0.113.1 bad="" probed=0 u ctx d pw kbd pam
  users="${HOST_AUDIT_USERS:-$(awk -F: '$3 >= 500 && $7 !~ /(nologin|false)$/ {print $1}' /etc/passwd 2>/dev/null | head -40) root}"
  for u in $users; do
    ctx="user=$u,host=$(hostname 2>/dev/null || echo localhost),addr=$probe_addr"
    d="$(sshd_dump_for "$ctx")" || continue
    [ -n "$d" ] || continue
    probed=$((probed + 1))
    pw="$(printf '%s\n' "$d" | awk '$1=="passwordauthentication"{print $2}')"
    kbd="$(printf '%s\n' "$d" | awk '$1=="kbdinteractiveauthentication"{print $2}')"
    pam="$(printf '%s\n' "$d" | awk '$1=="usepam"{print $2}')"
    if [ "$pw" = "yes" ]; then
      bad="$bad $u(password)"
    elif [ "$kbd" = "yes" ] && [ "$pam" = "yes" ]; then
      bad="$bad $u(kbd-interactive)"
    fi
  done

  if [ -n "$bad" ]; then
    report FAIL "ssh/match" "a Match block re-enables a password path for:${bad}"
  elif [ "$probed" -eq 0 ]; then
    report SKIP "ssh/match" "Match blocks present ($criteria) but no context could be resolved -- need root and sshd -T -C"
    return
  else
    report OK "ssh/match" "$probed context(s) probed, none re-enable passwords"
  fi

  # Only User/Group contexts are enumerable. Address- and Host-keyed blocks
  # cannot be exhausted by probing, so say so rather than implying they were.
  case "$criteria" in
    *[Aa]ddress* | *[Hh]ost* | *[Ll]ocal*)
      report WARN "ssh/match-coverage" "Match criteria include address/host conditions ($criteria); probing cannot exhaust these -- read the blocks by hand"
      ;;
  esac
}

# --- Rate limiting -----------------------------------------------------------
# Two engines do this job and a host should run exactly one. fail2ban is the
# general answer; CSF's lfd is the one this stack actually ships, and on a
# DirectAdmin box lfd is usually what is there.
#
# They must not both be installed -- each writes its own iptables rules, and two
# daemons unblocking each other's bans is worse than either alone. So the check
# is "is something rate-limiting password guessing", not "is fail2ban present".
# Demanding fail2ban on a CSF host would push an operator into installing the
# conflicting one.
audit_rate_limit() {
  local has_f2b=0 has_lfd=0
  have fail2ban-client && has_f2b=1
  { have csf || [ -r "${HOST_AUDIT_CSF_CONF:-/etc/csf/csf.conf}" ]; } && has_lfd=1

  if [ "$has_f2b" -eq 1 ] && [ "$has_lfd" -eq 1 ]; then
    report WARN "ratelimit/engine" "both fail2ban and CSF/lfd are installed -- they manage iptables independently and will undo each other's bans; run one"
  fi

  if [ "$has_f2b" -eq 1 ]; then
    audit_fail2ban
    return
  fi
  if [ "$has_lfd" -eq 1 ]; then
    audit_lfd
    return
  fi
  report FAIL "ratelimit/engine" "neither fail2ban nor CSF/lfd is installed -- nothing rate-limits password guessing"
}

# CSF's login failure daemon. Each LF_* setting is a failure threshold for one
# service, and 0 means that service is not watched at all -- so, as with
# DirectAdmin's own keys, presence of the setting says nothing. The services
# that matter here are the password paths the disclosed account names reach:
# SSH, DirectAdmin on 2222, mail and FTP.
audit_lfd() {
  local conf="${HOST_AUDIT_CSF_CONF:-/etc/csf/csf.conf}"

  if [ -n "${HOST_AUDIT_LFD_ACTIVE:-}" ]; then
    if [ "$HOST_AUDIT_LFD_ACTIVE" = "1" ]; then
      report OK "ratelimit/lfd" "CSF lfd active"
    else
      report FAIL "ratelimit/lfd" "CSF is installed but lfd is not running -- nothing acts on login failures"
      return
    fi
  elif systemctl is-active --quiet lfd 2>/dev/null; then
    report OK "ratelimit/lfd" "CSF lfd active"
  else
    report FAIL "ratelimit/lfd" "CSF is installed but lfd is not running -- nothing acts on login failures"
    return
  fi

  if [ ! -r "$conf" ]; then
    report SKIP "ratelimit/lfd-config" "cannot read $conf (need root)"
    return
  fi

  local svc key val off="" on="" missing=""
  for svc in SSHD DIRECTADMIN SMTPAUTH POP3D IMAPD FTPD; do
    key="LF_${svc}"
    val="$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\{0,1\}\([0-9]*\)\"\{0,1\}.*/\1/p" "$conf" | head -1)"
    if [ -z "$val" ]; then
      missing="$missing ${key}"
    elif [ "$val" = "0" ]; then
      off="$off ${key}"
    else
      on="$on ${key}=${val}"
    fi
  done

  if [ -n "$off" ]; then
    report FAIL "ratelimit/lfd-coverage" "lfd is not watching:${off} -- those password paths are unmetered"
  elif [ -n "$missing" ]; then
    report WARN "ratelimit/lfd-coverage" "not set, so CSF defaults apply:${missing}${on:+ (set:$on)}"
  else
    report OK "ratelimit/lfd-coverage" "thresholds set for every password path:${on}"
  fi
}

# Running is not the same as working. A jail watching a logpath that does not
# exist on this distro reports "active" forever and bans nothing, which is worse
# than no fail2ban because the dashboard looks green.
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

  # Ask, rather than inferring from uid. Root is the usual requirement for the
  # fail2ban socket but not the actual one, and "I could not query it" and "it
  # has no jails" are different findings that must not collapse into each other.
  local status jails
  status="$(fail2ban-client status 2>&1)"
  jails="$(printf '%s\n' "$status" | sed -n 's/.*Jail list:[[:space:]]*//p' | tr -d ' ')"
  if [ -z "$jails" ]; then
    case "$status" in
      *"Jail list"*) report FAIL "fail2ban/jails" "no jails configured" ;;
      *) report SKIP "fail2ban/jails" "cannot query fail2ban-client (usually needs root): $(printf '%s' "$status" | head -1)" ;;
    esac
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

  # Per jail, not in aggregate. A busy sshd jail racks up bans and would carry
  # a total well clear of zero on its own, hiding a DirectAdmin or mail jail
  # whose logpath does not exist on this build -- and those are exactly the
  # password endpoints the disclosed account names expose.
  local jail n paths p quiet="" broken="" working=0
  for jail in $(printf '%s' "$jails" | tr ',' ' '); do
    # A missing logpath is the direct evidence, not an inference from ban counts:
    # such a jail reports "active" forever and bans nothing.
    paths="$(fail2ban-client get "$jail" logpath 2>/dev/null | grep -oE '(^|[[:space:]])/[^[:space:],]+' | tr -d ' ')"
    for p in $paths; do
      [ -e "$p" ] || broken="$broken ${jail}:${p}"
    done

    n="$(fail2ban-client status "$jail" 2>/dev/null | sed -n 's/.*Total banned:[[:space:]]*//p' | head -1)"
    case "$n" in '' | *[!0-9]*) n=0 ;; esac
    if [ "$n" -gt 0 ]; then
      working=$((working + 1))
    else
      quiet="$quiet ${jail}"
    fi
  done

  if [ -n "$broken" ]; then
    report FAIL "fail2ban/logpath" "jail watching a path that does not exist:${broken} -- bans nothing while reporting active"
  else
    report OK "fail2ban/logpath" "every jail's logpath exists"
  fi

  if [ -z "$quiet" ]; then
    report OK "fail2ban/effective" "every jail has recorded at least one ban"
  else
    report WARN "fail2ban/effective" "zero bans ever recorded for:${quiet} (${working} jail(s) do have bans) -- on an internet-facing host a permanently quiet jail usually means it is not reading the log it thinks it is"
  fi
}

# True unless this host is demonstrably nginx-only, which is a stronger claim
# than "the nginx binary exists". DirectAdmin's nginx_apache mode runs nginx as
# a reverse proxy with Apache still serving, so nginx is installed, Apache
# writes the logs, and suppressing the Apache finding there would drop a real
# unscanned password path.
apache_serves_requests() {
  local opts="${HOST_AUDIT_CB_OPTIONS:-/usr/local/directadmin/custombuild/options.conf}"
  local mode=""
  [ -r "$opts" ] && mode="$(sed -n 's/^webserver=//p' "$opts" | tr -d ' \r' | head -1)"

  case "$mode" in
    nginx) return 1 ;;
    # nginx_apache, apache, litespeed and openlitespeed all serve through
    # something that writes Apache-format access logs.
    ?*) return 0 ;;
  esac

  # No CustomBuild answer. Look for Apache itself: a running httpd, or an
  # installed one. Absence of all of it is real evidence that nothing writes
  # Apache logs, not a guess -- so it is treated as such.
  [ -n "${HOST_AUDIT_APACHE_EVIDENCE:-}" ] && return "$((1 - HOST_AUDIT_APACHE_EVIDENCE))"
  pgrep -x httpd >/dev/null 2>&1 && return 0
  pgrep -x apache2 >/dev/null 2>&1 && return 0
  [ -d /etc/httpd ] && return 0
  [ -d /etc/apache2 ] && return 0
  return 1
}

# --- DirectAdmin -------------------------------------------------------------
audit_directadmin() {
  local conf="${HOST_AUDIT_DA_CONF:-/usr/local/directadmin/conf/directadmin.conf}"
  if [ ! -r "$conf" ]; then
    report SKIP "da/brute-force" "cannot read $conf (need root, or DA not installed)"
    return
  fi
  # Read the values, not just the key names. brute_force_log_scanner=0 is a
  # *matched* key, so treating presence as success would give a clean verdict to
  # a host whose scanner is switched off -- the one state this check exists to
  # catch. Option names still differ across DA builds, so unknown keys are
  # reported rather than asserted.
  local kv scanner="" disabled="" thresholds=""
  kv="$(grep -E '^(brute|blacklist|max_.*brute)' "$conf" 2>/dev/null)"
  if [ -z "$kv" ]; then
    report WARN "da/brute-force" "no brute_force*/blacklist* keys set -- DA's own log scanner is at its build defaults"
    return
  fi

  local line key val
  while IFS= read -r line; do
    key="${line%%=*}"
    val="${line#*=}"
    case "$key" in
      brute_force_log_scanner) scanner="$val" ;;
      *attempts* | *time_limit* | *_after) thresholds="$thresholds ${key}=${val}" ;;
    esac
    # An explicit zero is off, whatever the key is called on this build.
    [ "$val" = "0" ] && disabled="$disabled ${key}"
  done <<< "$kv"

  if [ "$scanner" = "0" ]; then
    report FAIL "da/brute-force" "brute_force_log_scanner=0 -- DA's brute-force scanner is switched off, so 2222, mail and FTP password guessing is unmetered"
    return
  fi

  # The scanner's own state is the verdict. Reporting a disabled key instead
  # lets an irrelevant one mask the answer -- which is what happened on the
  # first real run: brute_force_scan_apache_logs=0 was surfaced as the finding,
  # and whether the scanner itself was on went unsaid.
  if [ "$scanner" = "1" ]; then
    report OK "da/brute-force" "brute_force_log_scanner=1${thresholds:+, thresholds:$thresholds}"
  else
    report WARN "da/brute-force" "brute_force_log_scanner not set (build default applies); keys present:$(printf '%s' "$kv" | cut -d= -f1 | paste -sd' ' -)"
  fi

  # Apache log scanning is only a non-finding where Apache genuinely does not
  # serve requests. `have nginx` does not establish that: DirectAdmin's
  # nginx_apache mode runs nginx as a reverse proxy in front of Apache, so the
  # nginx binary is present, Apache serves, and Apache logs are exactly what
  # this scanner would read. Ask CustomBuild which server is configured, and
  # keep the finding whenever the answer is anything other than nginx alone.
  if [ -n "$disabled" ] && ! apache_serves_requests; then
    disabled="$(printf '%s' "$disabled" | tr ' ' '\n' | grep -v '^brute_force_scan_apache_logs$' | paste -sd' ' -)"
  fi
  [ -z "${disabled// /}" ] \
    || report WARN "da/brute-force-disabled" "set to 0, so present in the config but doing nothing:${disabled}"
}

# --- What is actually reachable ----------------------------------------------
# Ground truth. Config files describe intent; the listening socket and the
# firewall decide what an attacker can reach.
audit_exposure() {
  if ! have ss && [ -z "${HOST_AUDIT_LISTENERS:-}" ]; then
    report SKIP "exposure/listeners" "ss not available"
    return
  fi
  local open
  # Test hook: a comma-separated port list stands in for the live socket table.
  open="${HOST_AUDIT_LISTENERS:-$(ss -lnt 2>/dev/null | awk 'NR>1 {print $4}' | grep -E '^(0\.0\.0\.0|\[::\]|\*):' | sed 's/.*://' | sort -un | paste -sd, -)}"
  if [ -z "$open" ]; then
    report SKIP "exposure/listeners" "could not enumerate listeners"
    return
  fi
  report OK "exposure/listeners" "world-bound ports: $open"

  # Listing the ports is not judging them. A bound port is only reachable if the
  # firewall passes it, so read CSF's ingress allowlist and say which of the two
  # is true -- "bound and allowed through" and "bound but firewalled" need
  # different responses, and collapsing them either cries wolf or misses a live
  # exposure.
  local csf_conf="${HOST_AUDIT_CSF_CONF:-/etc/csf/csf.conf}" tcp_in="" fw_known=0
  if [ -r "$csf_conf" ]; then
    tcp_in="$(sed -n 's/^TCP_IN[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$csf_conf" | head -1 | tr -d ' ')"
    [ -n "$tcp_in" ] && fw_known=1
  fi

  # Nothing outside the box should ever reach these. A password path on a
  # database is not rate-limited by lfd or fail2ban, and a success is the whole
  # dataset rather than one account.
  local port label exposed="" firewalled=""
  for port in 3306:mysql 5432:postgres 6379:redis 11211:memcached 27017:mongodb 9200:elasticsearch; do
    label="${port#*:}"
    port="${port%%:*}"
    case ",$open," in
      *",$port,"*) ;;
      *) continue ;;
    esac
    if [ "$fw_known" -eq 1 ] && ! printf ',%s,' "$tcp_in" | grep -q ",$port,"; then
      firewalled="$firewalled ${label}/${port}"
    else
      exposed="$exposed ${label}/${port}"
    fi
  done

  if [ -n "$exposed" ]; then
    if [ "$fw_known" -eq 1 ]; then
      report FAIL "exposure/datastore" "reachable from the internet (bound to all interfaces and allowed by TCP_IN):${exposed} -- bind to 127.0.0.1 or remove from TCP_IN"
    else
      report FAIL "exposure/datastore" "bound to all interfaces:${exposed} -- could not read a firewall allowlist to rule out internet reachability; bind to 127.0.0.1"
    fi
  fi
  if [ -n "$firewalled" ]; then
    report WARN "exposure/datastore" "bound to all interfaces but not in TCP_IN:${firewalled} -- firewalled today, exposed the moment CSF is stopped or flushed; prefer binding to 127.0.0.1"
  fi
  [ -n "$exposed$firewalled" ] || report OK "exposure/datastore" "no database ports bound to all interfaces"

  # Plaintext credential paths. Their TLS equivalents (465/993/995, or FTP over
  # TLS) exist on this stack, so these are usually legacy compatibility.
  local plain=""
  for port in 21:ftp 110:pop3 143:imap; do
    label="${port#*:}"
    port="${port%%:*}"
    case ",$open," in *",$port,"*) plain="$plain ${label}/${port}" ;; esac
  done
  [ -z "$plain" ] || report WARN "exposure/plaintext-auth" "accepts credentials without implicit TLS:${plain} -- confirm STARTTLS is mandatory, or close in favour of 465/993/995"

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
#
# A running agent process is not a working recovery path. If the agent cannot
# authenticate or reach the SSM endpoints -- expired instance profile, no
# egress, broken VPC endpoint -- `systemctl is-active` still succeeds while the
# instance shows Offline in Systems Manager. An operator who disables SSH on the
# strength of that has no way back in, so local liveness and control-plane
# reachability are reported as two separate facts.
audit_ssm() {
  # Look in several places before concluding it is absent. A false negative here
  # is expensive in both directions: it either sends someone to install an agent
  # that is already there, or -- if the rest of the audit is clean -- it is the
  # one thing standing between them and an SSH change with no way back.
  local installed=0
  systemctl list-unit-files 2>/dev/null | grep -q amazon-ssm-agent && installed=1
  [ -x /usr/bin/amazon-ssm-agent ] && installed=1
  [ -x /snap/bin/amazon-ssm-agent ] && installed=1
  [ -d /var/lib/amazon/ssm ] && installed=1
  if [ "$installed" -eq 0 ]; then
    report FAIL "ssm/agent" "amazon-ssm-agent not installed -- there is no out-of-band path, so an SSH or firewall mistake has no rollback. Install it first: dnf install -y https://s3.amazonaws.com/ec2-downloads-windows/SSMAgent/latest/linux_amd64/amazon-ssm-agent.rpm && systemctl enable --now amazon-ssm-agent"
    return
  fi
  # systemd is not the only way this agent gets supervised, and the unit is not
  # always discoverable under the name you expect. A live process is the fact
  # that matters, so accept either -- reporting "installed but not running" for
  # an agent the control plane can see is the false negative this avoids.
  local running=""
  if systemctl is-active --quiet amazon-ssm-agent 2>/dev/null; then
    running="systemd unit active"
  elif pgrep -f '[a]mazon-ssm-agent' >/dev/null 2>&1; then
    running="process running (no active systemd unit by that name)"
  fi
  if [ -n "$running" ]; then
    report OK "ssm/agent" "local agent is up -- $running (says nothing about control-plane reachability, see ssm/reachable)"
  else
    report FAIL "ssm/agent" "installed but no running agent found -- restore it before tightening SSH"
    return
  fi

  # PingStatus is the only authority on whether a session can actually be
  # opened. Ask for it if this host happens to have credentials that can; the
  # instance profile usually cannot, and that is fine -- it becomes a SKIP,
  # which makes the audit incomplete rather than quietly passing.
  local iid ping=""
  iid="$(sed -n 's/.*"ManagedInstanceID":"\([^"]*\)".*/\1/p' /var/lib/amazon/ssm/registration 2>/dev/null)"
  [ -n "$iid" ] || iid="$(curl -fsS -m 2 -H "X-aws-ec2-metadata-token: $(curl -fsS -m 2 -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' http://169.254.169.254/latest/api/token 2>/dev/null)" http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)"

  if have aws && [ -n "$iid" ]; then
    ping="$(aws ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$iid" \
      --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)"
  fi

  case "$ping" in
    Online)
      report OK "ssm/reachable" "PingStatus Online for $iid -- a session can be opened, so SSH lockout is recoverable"
      ;;
    ConnectionLost | Inactive)
      report FAIL "ssm/reachable" "PingStatus $ping for $iid -- the agent runs but Systems Manager cannot reach it; do NOT tighten SSH"
      ;;
    *)
      report SKIP "ssm/reachable" "cannot confirm PingStatus${iid:+ for $iid} from this host; before tightening SSH run: aws ssm describe-instance-information --filters Key=InstanceIds,Values=${iid:-<instance-id>} --query 'InstanceInformationList[0].PingStatus'"
      ;;
  esac
}

[ "$JSON" -eq 1 ] || {
  echo "Host access audit -- $(hostname 2>/dev/null || echo unknown) -- $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  [ "$IS_ROOT" -eq 1 ] || echo "(running unprivileged: root-only checks report SKIP)"
  echo
}

audit_ssm
audit_ssh
audit_ssh_match
audit_rate_limit
audit_directadmin
audit_exposure
audit_accounts

complete=true
[ "$skips" -eq 0 ] || complete=false

if [ "$JSON" -eq 1 ]; then
  printf '{"findings":%d,"skipped":%d,"complete":%s,"skipped_areas":[%s],"items":[%s]}\n' \
    "$findings" "$skips" "$complete" \
    "$(for a in $skipped_areas; do printf '"%s",' "$a"; done | sed 's/,$//')" \
    "$(IFS=,; printf '%s' "${json_items[*]}")"
else
  echo
  if [ "$skips" -gt 0 ]; then
    echo "INCOMPLETE: $skips check(s) could not run:${skipped_areas}"
    [ "$IS_ROOT" -eq 1 ] || echo "Re-run with sudo: sshd -T, the fail2ban socket and directadmin.conf are root-only."
  fi
  if [ "$findings" -eq 0 ] && [ "$skips" -eq 0 ]; then
    echo "PASS: no findings."
  elif [ "$findings" -eq 0 ]; then
    echo "No findings in the checks that ran -- but see above; this is not a pass."
  else
    echo "$findings finding(s). Remediation: aws/docs/host-access-hardening.md"
    echo "Apply in the order given there; it keeps an SSM session as the rollback path."
  fi
fi

[ "$findings" -eq 0 ] || exit 1
[ "$skips" -eq 0 ] || exit 3
exit 0
