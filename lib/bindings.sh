#!/bin/bash
# tmux key bindings for fleet sessions. Sourced by bin/fleet-monitor.
#
# Key tables belong to the tmux server, not to a session, so a binding made
# here is seen by every session on the machine. To keep the fleet behaviour
# out of other sessions, every binding is wrapped as:
#
#   if-shell -F "#{@panefleet}" { fleet behaviour } { what the key did before }
#
# Invariants:
#   - `@panefleet` is a session option set only on fleet sessions, so the
#     first branch runs there and nowhere else.
#   - The second branch is the command that was bound before, copied from
#     `tmux list-keys`. A binding the user made is never discarded.
#   - A key that is already wrapped is left alone, so starting several
#     monitors does not nest the wrappers.
#
# Needs tmux 3.0 or newer for the { } command syntax.

# Print the command currently bound to a key, or nothing if it is unbound.
fleet_existing_binding() {
  local table="$1" key="$2" line
  line=$(tmux list-keys -T "$table" "$key" 2>/dev/null | head -1)
  case "$line" in
    bind-key*) ;;
    *) return 0 ;;
  esac
  # Drop the leading "bind-key [-r] -T <table> <key>".
  printf '%s\n' "$line" | sed -E 's/^bind-key +(-r +)?-T +[^ ]+ +[^ ]+ +//'
}

# Print a tmux config stanza that scopes a binding to fleet sessions.
#   $1 table  $2 key  $3 command for fleet sessions
#   $4 command for other sessions when the key was not bound before
# Prints nothing if the key is already scoped.
fleet_scoped_binding() {
  local table="$1" key="$2" fleet_cmd="$3" fallback="$4" existing
  existing=$(fleet_existing_binding "$table" "$key")
  case "$existing" in
    *@panefleet*) return 0 ;;
  esac
  if [ -n "$existing" ]; then
    fallback="$existing"
  fi
  printf 'bind-key -T %s %s if-shell -F "#{@panefleet}" {\n  %s\n} {\n  %s\n}\n' \
    "$table" "$key" "$fleet_cmd" "$fallback"
}

# Print a command that copies stdin to the system clipboard, or nothing if no
# known tool is installed.
fleet_clipboard_cmd() {
  if command -v pbcopy >/dev/null 2>&1; then
    echo "pbcopy"
  elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
    echo "wl-copy"
  elif command -v xclip >/dev/null 2>&1; then
    echo "xclip -selection clipboard -in"
  elif command -v xsel >/dev/null 2>&1; then
    echo "xsel --clipboard --input"
  fi
}

# Print the full set of scoped bindings as a tmux config file.
#   $1 absolute path of the fleet-home script, run by F2
fleet_bindings_config() {
  local home_cmd="$1" clip copy_cmd
  local wants_mouse='#{||:#{pane_in_mode},#{mouse_any_flag}}'

  # Wheel: if the app in the pane handles the mouse itself (Claude Code does,
  # and scrolls its own transcript), pass the event through. Otherwise enter
  # copy-mode and scroll the pane's history like a terminal scrollback.
  fleet_scoped_binding root WheelUpPane \
    "if-shell -F -t = \"$wants_mouse\" { send-keys -M } { select-pane -t = ; copy-mode -e ; send-keys -M }" \
    "send-keys -M"
  fleet_scoped_binding root WheelDownPane \
    "if-shell -F -t = \"$wants_mouse\" { send-keys -M }" \
    "send-keys -M"

  # Drag-select: releasing the mouse copies the selection to the system
  # clipboard and leaves copy-mode. With no clipboard tool, tmux's own
  # copy-pipe-and-cancel default applies.
  clip=$(fleet_clipboard_cmd)
  copy_cmd="send-keys -X copy-pipe-and-cancel"
  if [ -n "$clip" ]; then
    copy_cmd="send-keys -X copy-pipe-and-cancel \"$clip\""
  fi
  fleet_scoped_binding copy-mode MouseDragEnd1Pane "$copy_cmd" "send-keys -X copy-pipe-and-cancel"
  fleet_scoped_binding copy-mode-vi MouseDragEnd1Pane "$copy_cmd" "send-keys -X copy-pipe-and-cancel"

  # F2: return to the monitor from any agent. Bound in the root table so it
  # works even when the app in the pane captures the prefix key. In other
  # sessions F2 is passed to the program in the pane.
  fleet_scoped_binding root F2 \
    "run-shell \"'$home_cmd' '#{session_name}'\"" \
    "send-keys F2"
}
