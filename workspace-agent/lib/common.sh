#!/bin/bash
# Shared mount logic for the workspace agent. Sourced by both
# workspace-agent-entrypoint.sh (initial mount) and switch-project.sh (live switch) so
# there is exactly one implementation of the mount/bind/switch behavior.
set -euo pipefail

AGENT_MOUNT_ROOT="${AGENT_MOUNT_ROOT:-/mnt/agent}"
WS_MOUNT="$AGENT_MOUNT_ROOT/ws"
PROJECTS_SUBDIR="${WORKSPACE_PROJECTS_SUBDIR:-projects}"

# mount_workspace: mounts the user's full workspace privately under $WS_MOUNT, readable
# only by root (mode 700 on the parent dir). In production this would be
# `mount -t nfs $NFS_SERVER:$NFS_EXPORT_PATH $WS_MOUNT`; locally, with no NFS server on
# this dev machine, NFS_EXPORT_SOURCE bind-mounts the fixture directory instead — same
# end state (a private, root-only view of the user's whole workspace), different source.
mount_workspace() {
  mkdir -p "$AGENT_MOUNT_ROOT"
  chmod 700 "$AGENT_MOUNT_ROOT"
  mkdir -p "$WS_MOUNT"

  if mountpoint -q "$WS_MOUNT"; then
    echo "workspace-agent: $WS_MOUNT already mounted, skipping" >&2
    return 0
  fi

  if [ -n "${NFS_SERVER:-}" ]; then
    mount -t nfs "${NFS_SERVER}:${NFS_EXPORT_PATH:?NFS_EXPORT_PATH must be set when NFS_SERVER is set}" "$WS_MOUNT"
  else
    : "${NFS_EXPORT_SOURCE:?Set NFS_EXPORT_SOURCE (local fixture path) or NFS_SERVER (real NFS)}"
    mount --bind "$NFS_EXPORT_SOURCE" "$WS_MOUNT"
  fi
  echo "workspace-agent: workspace mounted at $WS_MOUNT" >&2
}

# bind_project <project-id>: exposes exactly one project directory at $EXPOSE_PATH.
# Idempotent and switch-safe: if something is already bound there, it is lazily
# unmounted first, so this same function is both "bind the first project" (called from
# the entrypoint) and "switch to a different project" (called from switch-project.sh).
bind_project() {
  local project_id="$1"
  local project_dir="$WS_MOUNT/$PROJECTS_SUBDIR/$project_id"

  if [ ! -d "$project_dir" ]; then
    echo "workspace-agent: ERROR: project directory not found: $project_dir" >&2
    exit 1
  fi

  mkdir -p "$EXPOSE_PATH"

  if mountpoint -q "$EXPOSE_PATH"; then
    # -l (lazy): detach immediately for new lookups; a shell whose cwd is still inside
    # keeps working against the old data until it `cd`s again.
    umount -l "$EXPOSE_PATH"
  fi

  mount --bind "$project_dir" "$EXPOSE_PATH"

  # Record the active project (world-readable) so jailed-shell.sh can present it at
  # workspace/<user>/<project>; this also keeps the path right after switch-project.sh.
  mkdir -p /run/workspace-agent
  chmod 755 /run/workspace-agent
  printf '%s\n' "$project_id" > /run/workspace-agent/active
  chmod 644 /run/workspace-agent/active
  echo "workspace-agent: project '$project_id' now exposed at $EXPOSE_PATH" >&2
}
