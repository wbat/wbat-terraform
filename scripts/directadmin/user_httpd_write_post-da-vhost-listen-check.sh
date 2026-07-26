#!/bin/bash
# DirectAdmin directory-form hook: user_httpd_write_post
# Install as:
#   /usr/local/directadmin/scripts/custom/user_httpd_write_post/da-vhost-listen-check.sh
#   chmod 700; chown diradmin:diradmin
#
# CHECK ONLY — never mutate. Post-write hooks cannot abort, and rewriting
# during a rewrite risks a loop.

set -euo pipefail
RECONCILE="${DA_VHOST_RECONCILE:-/usr/local/sbin/da-vhost-listen-reconcile.sh}"
if [[ -x "$RECONCILE" ]]; then
  "$RECONCILE" --check || true
fi
exit 0
