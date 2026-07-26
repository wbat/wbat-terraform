#!/bin/bash
# DirectAdmin update_post.sh fragment: run vhost-listen check after DA updates.
# Append or install alongside other update_post consumers.
# Prefer directory-form hooks where DA supports them; this is the update trigger.

set -euo pipefail
RECONCILE="${DA_VHOST_RECONCILE:-/usr/local/sbin/da-vhost-listen-reconcile.sh}"
if [[ -x "$RECONCILE" ]]; then
  "$RECONCILE" --check || true
fi
exit 0
