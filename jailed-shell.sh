#!/bin/bash
# dockeruser's login shell (see Dockerfile: useradd -s). Every terminal opened inside
# the XFCE desktop session resolves to this via /etc/passwd, and wraps the real
# interactive shell in a bubblewrap sandbox pinned to whichever project is currently
# exposed at $EXPOSE_PATH. Anything XFCE launches directly via a .desktop Exec= line
# (Firefox) does not go through this and is unaffected.
#
# $EXPOSE_PATH is bound at its own absolute path inside a throwaway synthetic bwrap
# root (not made the sandbox's literal /), so bwrap's automatic mountpoint creation
# for the other binds (/usr, /etc, /proc, ...) lands in the synthetic root, never in
# the user's real project folder. Normal navigation inside the project (subfolders,
# cd .., cd -) is unaffected; only cd .. from the project's own top lands in an empty
# synthetic stub instead of /home/dockeruser, sibling projects, or anywhere else.
set -euo pipefail

EXPOSE_PATH="${EXPOSE_PATH:-/home/dockeruser/workspace}"

# Inside the jail the project appears at <EXPOSE_PATH>/<user>/<project>, e.g.
# /home/dockeruser/workspace/rajdeep/project2, and that is where the shell starts.
# Only that path exists in the jail; its parents are empty synthetic directories.
JAIL_PROJECT="$(cat /run/workspace-agent/active 2>/dev/null || echo "${ACTIVE_PROJECT:-project}")"
VIEW_PATH="$EXPOSE_PATH/${WORKSPACE_USER:-user}/$JAIL_PROJECT"

exec bwrap \
  --unshare-all --share-net \
  --die-with-parent \
  --new-session \
  --cap-drop ALL \
  --ro-bind /usr /usr \
  --ro-bind-try /bin /bin \
  --ro-bind-try /sbin /sbin \
  --ro-bind-try /lib /lib \
  --ro-bind-try /lib64 /lib64 \
  --ro-bind /etc/passwd /etc/passwd \
  --ro-bind /etc/group /etc/group \
  --ro-bind-try /etc/nsswitch.conf /etc/nsswitch.conf \
  --ro-bind-try /etc/resolv.conf /etc/resolv.conf \
  --ro-bind-try /etc/hosts /etc/hosts \
  --ro-bind-data 3 /etc/machine-id \
  --ro-bind-try /etc/alternatives /etc/alternatives \
  --ro-bind-try /etc/ssl /etc/ssl \
  --ro-bind-try /etc/ca-certificates /etc/ca-certificates \
  --ro-bind-try /etc/bash.bashrc /etc/bash.bashrc \
  --ro-bind-try /etc/profile /etc/profile \
  --ro-bind-try /etc/profile.d /etc/profile.d \
  --tmpfs /tmp \
  --proc /proc \
  --dev /dev \
  --dev-bind-try /dev/video0 /dev/video0 \
  --ro-bind-try /tmp/.X11-unix /tmp/.X11-unix \
  --ro-bind-try "${HOME:-/nonexistent}/.Xauthority" /tmp/.Xauthority \
  --setenv XAUTHORITY /tmp/.Xauthority \
  --bind "$EXPOSE_PATH" "$VIEW_PATH" \
  --chdir "$VIEW_PATH" \
  --setenv HOME "$VIEW_PATH" \
  --setenv JAIL_ROOT "$VIEW_PATH" \
  --setenv PATH "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
  /bin/bash --rcfile /usr/local/lib/jail-guard.sh -i \
  3<<< "0123456789abcdef0123456789abcdef"
