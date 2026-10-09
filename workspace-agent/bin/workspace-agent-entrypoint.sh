#!/bin/bash
set -euo pipefail
source /usr/local/lib/workspace-agent/common.sh

mount_workspace
bind_project "${ACTIVE_PROJECT:?ACTIVE_PROJECT must be set}"

# Privilege drop: root did the mounting (needs CAP_SYS_ADMIN); everything from here on
# — vncserver, the user's shells — runs as the unprivileged EXPOSE_OWNER.
exec gosu "${EXPOSE_OWNER:?EXPOSE_OWNER must be set}" "$@"
