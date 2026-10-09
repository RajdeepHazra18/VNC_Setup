#!/bin/bash
set -euo pipefail
source /usr/local/lib/workspace-agent/common.sh

if [ $# -ne 1 ]; then
  echo "usage: switch-project.sh <project-id>" >&2
  exit 1
fi

bind_project "$1"
