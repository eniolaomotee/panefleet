#!/usr/bin/env bats
# Tests for the monitor's key bindings (issue #16), run against a real tmux
# server on a private socket so the developer's own tmux is never touched.

setup() {
  command -v tmux >/dev/null || skip "tmux not installed"
  ROOT="$BATS_TEST_DIRNAME/.."
  BIN="$ROOT/bin"
  WORK="$(mktemp -d)"
  export XDG_STATE_HOME="$WORK/state"
  export TMUX_TMPDIR="$WORK"
  unset TMUX
  tmux -f /dev/null new-session -d -s plain -x 100 -y 30 'cat'
}

teardown() {
  if [ -n "${WORK:-}" ]; then
    tmux kill-server 2>/dev/null || true
    rm -rf "$WORK"
  fi
}

refute() {
  if "$@"; then
    echo "expected to fail: $*"
    return 1
  fi
}

# Start a fleet session whose pane 0 runs the monitor, with one agent pane,
# and wait until the monitor has set up its bindings.
start_fleet() {
  local session="$1"
  tmux new-session -d -s "$session" -x 100 -y 30 "'$BIN/fleet-monitor' '$session'"
  tmux split-window -t "$session:0" 'cat'
  for _ in $(seq 1 50); do
    [ -f "$XDG_STATE_HOME/panefleet/$session/bindings.conf" ] \
      && [ "$(tmux show-option -t "$session" -qv @panefleet)" = "1" ] && return 0
    sleep 0.1
  done
  echo "monitor did not start for $session"
  return 1
}

binding() {
  tmux list-keys -T "$1" "$2"
}

# Run a binding's command as if the key were pressed in the given session.
press() {
  local session="$1" table="$2" key="$3" cmd
  cmd=$(binding "$table" "$key" | sed -E 's/^bind-key +(-r +)?-T +[^ ]+ +[^ ]+ +//')
  printf '%s\n' "$cmd" > "$WORK/press.conf"
  tmux source-file -t "$session:0" "$WORK/press.conf"
}

@test "the monitor marks only its own session as a fleet session" {
  start_fleet fleet-1
  [ "$(tmux show-option -t fleet-1 -qv @panefleet)" = "1" ]
  [ -z "$(tmux show-option -t plain -qv @panefleet)" ]
}

@test "every binding is wrapped in a fleet-session check" {
  start_fleet fleet-1
  for spec in "root WheelUpPane" "root WheelDownPane" "root F2" \
    "copy-mode MouseDragEnd1Pane" "copy-mode-vi MouseDragEnd1Pane"; do
    # shellcheck disable=SC2086  # split "table key" into two arguments
    run binding $spec
    [ "$status" -eq 0 ]
    [[ "$output" == *'if-shell -F "#{@panefleet}"'* ]] || { echo "$spec: $output"; return 1; }
  done
}

@test "the stock tmux binding is kept as the fallback" {
  STOCK=$(binding root WheelUpPane | sed -E 's/^bind-key +-T +root +WheelUpPane +//')
  [ -n "$STOCK" ]
  start_fleet fleet-1
  [[ "$(binding root WheelUpPane)" == *"$STOCK"* ]]
}

@test "a binding the user already had is kept as the fallback" {
  tmux bind-key -T root F2 set-option -g @user_f2 pressed
  start_fleet fleet-1
  [[ "$(binding root F2)" == *"@user_f2 pressed"* ]]

  # In a non-fleet session F2 still runs the user's command.
  press plain root F2
  [ "$(tmux show-option -gqv @user_f2)" = "pressed" ]
}

@test "F2 in a fleet session returns to the monitor and not to the user's binding" {
  tmux bind-key -T root F2 set-option -g @user_f2 pressed
  start_fleet fleet-1
  echo off > "$XDG_STATE_HOME/panefleet/fleet-1/mouse-pref"
  tmux set-option -t fleet-1 mouse on
  tmux select-pane -t fleet-1:0.1
  tmux resize-pane -Z -t fleet-1:0.1

  press fleet-1 root F2
  for _ in $(seq 1 30); do
    [ "$(tmux display-message -t fleet-1:0 -p '#{window_zoomed_flag}')" = "0" ] && break
    sleep 0.1
  done
  [ "$(tmux display-message -t fleet-1:0 -p '#{window_zoomed_flag}')" = "0" ]
  [ "$(tmux display-message -t fleet-1:0 -p '#{pane_index}')" = "0" ]
  [ "$(tmux show-option -t fleet-1 -v mouse)" = "off" ]
  [ -z "$(tmux show-option -gqv @user_f2)" ]
}

@test "starting a second monitor does not nest the wrappers" {
  start_fleet fleet-1
  FIRST=$(binding root F2)
  start_fleet fleet-2
  [ "$(binding root F2)" = "$FIRST" ]
  [ "$(binding root F2 | grep -o '@panefleet' | wc -l | tr -d ' ')" = "1" ]
  # Nothing left to bind the second time.
  [ ! -s "$XDG_STATE_HOME/panefleet/fleet-2/bindings.conf" ]
}

@test "fleet-home ignores a mouse preference that is not on or off" {
  start_fleet fleet-1
  echo "on; kill-server" > "$XDG_STATE_HOME/panefleet/fleet-1/mouse-pref"
  tmux set-option -t fleet-1 mouse off
  run "$BIN/fleet-home" fleet-1
  [ "$status" -eq 0 ]
  [ "$(tmux show-option -t fleet-1 -v mouse)" = "off" ]
}

@test "fleet-home rejects a missing or unsafe session name" {
  run "$BIN/fleet-home"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: fleet-home"* ]]
  run "$BIN/fleet-home" "../x"
  [ "$status" -eq 1 ]
}

@test "the clipboard command prefers what is installed and is empty when nothing is" {
  # shellcheck source=../lib/bindings.sh
  . "$ROOT/lib/bindings.sh"
  mkdir "$WORK/tools"
  PATH="$WORK/tools" run fleet_clipboard_cmd
  [ -z "$output" ]
  printf '#!/bin/sh\n' > "$WORK/tools/xclip"
  chmod +x "$WORK/tools/xclip"
  PATH="$WORK/tools" run fleet_clipboard_cmd
  [ "$output" = "xclip -selection clipboard -in" ]
  printf '#!/bin/sh\n' > "$WORK/tools/pbcopy"
  chmod +x "$WORK/tools/pbcopy"
  PATH="$WORK/tools" run fleet_clipboard_cmd
  [ "$output" = "pbcopy" ]
}
