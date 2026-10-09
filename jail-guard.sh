# Sourced as the rcfile of the interactive shell started by jailed-shell.sh.
# Makes `cd` refuse any destination outside the project folder ($JAIL_ROOT), so
# `cd ..` at the project's top level fails instead of landing in a parent directory.
# (The bwrap sandbox additionally ensures nothing but the project exists in the jail.)
[ -f /etc/profile ] && . /etc/profile
[ -f /etc/bash.bashrc ] && . /etc/bash.bashrc

cd() {
  local target resolved
  case "${1:-}" in
    "")  target="$JAIL_ROOT" ;;
    -)   target="${OLDPWD:-$JAIL_ROOT}" ;;
    -P|-L) shift; target="${1:-$JAIL_ROOT}" ;;
    *)   target="$1" ;;
  esac
  resolved="$(realpath -m -- "$target" 2>/dev/null)" || resolved=""
  case "$resolved" in
    "$JAIL_ROOT"|"$JAIL_ROOT"/*) builtin cd -- "$target" ;;
    *) echo "cd: $target: cannot leave the project folder" >&2; return 1 ;;
  esac
}

# pushd/popd would be a way around the guard.
pushd() { echo "pushd: disabled in the project shell" >&2; return 1; }
popd()  { echo "popd: disabled in the project shell" >&2; return 1; }
