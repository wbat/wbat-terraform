#!/bin/bash
# DirectAdmin hook: after a forwarder is created/modified, restore managed pipe aliases.
# Install: /usr/local/directadmin/scripts/custom/forwarder_create_post.sh (mode 700)
# Env from DA: username, file, user, value, domain
# Docs: https://docs.directadmin.com/developer/hooks/email.html

set -u
ENSURE="${ENSURE_SES_GMAIL_ALIASES:-/usr/local/bin/ensure-ses-gmail-aliases.sh}"

if [[ -x "$ENSURE" && -n "${domain:-}" ]]; then
  "$ENSURE" "$domain" >/dev/null 2>&1 || true
fi
exit 0
