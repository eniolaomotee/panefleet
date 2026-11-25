#!/bin/bash
# Shared state-directory helpers. Sourced by the scripts in bin/.
#
# All runtime state lives in a private per-user directory:
#
#   ${XDG_STATE_HOME:-$HOME/.local/state}/panefleet/            base
#   ${XDG_STATE_HOME:-$HOME/.local/state}/panefleet/<session>/  one per tmux session
#
# Invariants, enforced by fleet_state_init on every call:
#   - the base, session and relay directories are real directories (not
#     symlinks), owned by the current user, with mode 700
#   - a session name can never escape the base directory
#
# This file is the only place that knows where state lives. Nothing in bin/
# should build a state path by hand.

# Print the base directory. Fails if no usable location can be derived.
fleet_state_base() {
  local root="${XDG_STATE_HOME:-}"
  if [ -z "$root" ]; then
    if [ -z "${HOME:-}" ]; then
      echo "panefleet: neither XDG_STATE_HOME nor HOME is set" >&2
      return 1
    fi
    root="$HOME/.local/state"
  fi
  case "$root" in
    /*) ;;
    *)
      echo "panefleet: state root must be an absolute path: $root" >&2
      return 1
      ;;
  esac
  # The path is embedded in single-quoted tmux commands, so it cannot
  # contain a single quote or a newline.
  case "$root" in
    *"'"* | *$'\n'*)
      echo "panefleet: state root contains an unsupported character: $root" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$root/panefleet"
}

# Succeed if the name is safe to use as a path component.
fleet_valid_session() {
  [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]
}

# Succeed if the directory is a real directory, owned by us, with mode 700.
fleet_dir_is_private() {
  local dir="$1" mode
  [ -d "$dir" ] && [ ! -L "$dir" ] && [ -O "$dir" ] || return 1
  # GNU stat first: on Linux `stat -f` means something else and would succeed.
  mode=$(stat -c %a "$dir" 2>/dev/null || stat -f %Lp "$dir" 2>/dev/null) || return 1
  [ "$mode" = "700" ]
}

# Create a directory with mode 700 if it is missing, then verify it.
# An existing directory with the wrong owner or mode is refused, not repaired:
# if someone else got there first, its contents cannot be trusted.
_fleet_private_dir() {
  local dir="$1"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    (umask 077 && mkdir -p "$dir") || {
      echo "panefleet: cannot create $dir" >&2
      return 1
    }
  fi
  if ! fleet_dir_is_private "$dir"; then
    echo "panefleet: refusing to use $dir: it must be a directory owned by you with mode 700" >&2
    return 1
  fi
}

# Create and verify the base directory, then print it.
fleet_state_base_init() {
  local base
  base=$(fleet_state_base) || return 1
  _fleet_private_dir "$base" || return 1
  printf '%s\n' "$base"
}

# Create and verify the state directory for a session, then print it.
# Layout:
#   name            fleet display name
#   names/<pane>    pane labels
#   prompt-<pane>.txt, agent-<pane>.log
#   relay/send-*    keystroke requests picked up by fleet-relay
#   mouse-pref      mouse state restored by F2
fleet_state_init() {
  local session="$1" base dir
  if ! fleet_valid_session "$session"; then
    echo "panefleet: invalid session name: $session" >&2
    return 1
  fi
  base=$(fleet_state_base_init) || return 1
  dir="$base/$session"
  _fleet_private_dir "$dir" || return 1
  _fleet_private_dir "$dir/names" || return 1
  _fleet_private_dir "$dir/relay" || return 1
  printf '%s\n' "$dir"
}

# Remove the state directory for one session.
fleet_state_remove() {
  local session="$1" base
  fleet_valid_session "$session" || return 1
  base=$(fleet_state_base) || return 1
  fleet_dir_is_private "$base" || return 1
  rm -rf -- "${base:?}/$session"
}

# Remove state left behind by fleet sessions that no longer exist.
# Only touches directories named like launcher sessions (fleet-<pid>).
fleet_state_prune() {
  local base dir name
  base=$(fleet_state_base 2>/dev/null) || return 0
  fleet_dir_is_private "$base" || return 0
  for dir in "$base"/fleet-*; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    name="${dir##*/}"
    [[ "$name" =~ ^fleet-[0-9]+$ ]] || continue
    tmux has-session -t "=$name" 2>/dev/null || rm -rf -- "$dir"
  done
  return 0
}
