#!/usr/bin/env bats
# Tests for the private state directory (issue #2): where state lives, that it
# is mode 700, and that the relay refuses a directory it cannot trust.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  BIN="$ROOT/bin"
  WORK="$(mktemp -d)"
  export XDG_STATE_HOME="$WORK/state"
  BASE="$XDG_STATE_HOME/panefleet"
  unset TMUX

  # A fake tmux that records its arguments. `has-session` succeeds for the
  # first TMUX_STUB_ALIVE calls and fails after that.
  STUB="$WORK/stub"
  mkdir -p "$STUB"
  export TMUX_STUB_LOG="$WORK/tmux.log"
  export TMUX_STUB_COUNT="$WORK/tmux.count"
  cat > "$STUB/tmux" <<'STUBEOF'
#!/bin/bash
printf '%s\n' "$*" >> "$TMUX_STUB_LOG"
if [ "$1" = "has-session" ]; then
  n=$(cat "$TMUX_STUB_COUNT" 2>/dev/null || echo 0)
  echo $((n + 1)) > "$TMUX_STUB_COUNT"
  [ "$n" -lt "${TMUX_STUB_ALIVE:-999999}" ]
  exit
fi
exit 0
STUBEOF
  chmod +x "$STUB/tmux"
}

teardown() {
  if [ -n "${E2E_TMPDIR:-}" ]; then
    TMUX_TMPDIR="$E2E_TMPDIR" tmux kill-server 2>/dev/null || true
    rm -rf "$E2E_TMPDIR"
  fi
  rm -rf "$WORK"
}

mode_of() {
  stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"
}

# Stub every external command the launcher can start. Launcher tests run with
# a PATH limited to the stubs, bin/ and the system dirs, so the launcher can
# never reach a tool on the developer's own PATH. Each stub records its name
# when it is run.
stub_launcher_tools() {
  local tool
  export STUB_CALLS="$WORK/stub-calls.log"
  for tool in fzf bat git claude fleet-telegram fleet-notify; do
    # shellcheck disable=SC2016  # $STUB_CALLS must expand when the stub runs
    printf '#!/bin/bash\necho "%s" >> "$STUB_CALLS"\nexit 0\n' "$tool" > "$STUB/$tool"
    chmod +x "$STUB/$tool"
  done
}

# Fail if the command succeeds. A bare `! cmd` does not fail a bats test
# unless it is the last line, so negative assertions go through this.
refute() {
  if "$@"; then
    echo "expected to fail: $*"
    return 1
  fi
}

load_lib() {
  # shellcheck source=../lib/state.sh
  . "$ROOT/lib/state.sh"
}

# ── static ──

@test "no script or library references /tmp" {
  run grep -n '/tmp' "$BIN"/* "$ROOT"/lib/*
  [ "$status" -eq 1 ] || { echo "$output"; return 1; }
}

# ── lib/state.sh ──

@test "state base honours XDG_STATE_HOME and falls back to ~/.local/state" {
  load_lib
  [ "$(fleet_state_base)" = "$WORK/state/panefleet" ]
  unset XDG_STATE_HOME
  [ "$(HOME=/home/someone fleet_state_base)" = "/home/someone/.local/state/panefleet" ]
}

@test "state base rejects relative paths and paths with a single quote" {
  load_lib
  XDG_STATE_HOME="relative/dir" run fleet_state_base
  [ "$status" -eq 1 ]
  XDG_STATE_HOME="/tmp/it's" run fleet_state_base
  [ "$status" -eq 1 ]
}

@test "state init creates base, session, names and relay dirs with mode 700" {
  load_lib
  # A permissive umask must not leak into the state directories.
  umask 022
  run fleet_state_init fleet-123
  [ "$status" -eq 0 ]
  [ "$output" = "$BASE/fleet-123" ]
  for d in "$BASE" "$BASE/fleet-123" "$BASE/fleet-123/names" "$BASE/fleet-123/relay"; do
    [ "$(mode_of "$d")" = "700" ] || { echo "$d is $(mode_of "$d")"; return 1; }
  done
}

@test "state init rejects session names that could escape the base dir" {
  load_lib
  # shellcheck disable=SC2016  # the literal string is the test input
  for bad in "" ".." "../x" "a/b" ".hidden" "a b" '$(id)'; do
    run fleet_state_init "$bad"
    [ "$status" -eq 1 ] || { echo "accepted: '$bad'"; return 1; }
  done
  [ ! -e "$WORK/x" ]
}

@test "state init refuses an existing group or world accessible directory" {
  load_lib
  mkdir -p "$BASE/fleet-123"
  chmod 700 "$BASE"
  for mode in 777 770 755 750; do
    chmod "$mode" "$BASE/fleet-123"
    run fleet_state_init fleet-123
    [ "$status" -eq 1 ] || { echo "accepted mode $mode"; return 1; }
    [[ "$output" == *"refusing to use"* ]]
    # Refused, not silently repaired.
    [ "$(mode_of "$BASE/fleet-123")" = "$mode" ]
  done
}

@test "state init refuses a symlinked session directory" {
  load_lib
  mkdir -p "$BASE" "$WORK/elsewhere"
  chmod 700 "$BASE" "$WORK/elsewhere"
  ln -s "$WORK/elsewhere" "$BASE/fleet-123"
  run fleet_state_init fleet-123
  [ "$status" -eq 1 ]
  [ -z "$(ls -A "$WORK/elsewhere")" ]
}

@test "state init refuses a base directory that is not private" {
  load_lib
  mkdir -p "$BASE"
  chmod 755 "$BASE"
  run fleet_state_init fleet-123
  [ "$status" -eq 1 ]
  [ ! -e "$BASE/fleet-123" ]
}

@test "prune removes state of dead fleet sessions and nothing else" {
  load_lib
  fleet_state_init fleet-111 >/dev/null
  fleet_state_init fleet-222 >/dev/null
  fleet_state_init my-own-session >/dev/null
  echo keep > "$BASE/unrelated.txt"
  # First has-session call (fleet-111) succeeds, the second (fleet-222) fails.
  TMUX_STUB_ALIVE=1 PATH="$STUB:$PATH" fleet_state_prune
  [ -d "$BASE/fleet-111" ]
  [ ! -e "$BASE/fleet-222" ]
  [ -d "$BASE/my-own-session" ]
  [ -f "$BASE/unrelated.txt" ]
}

# ── fleet-relay ──

@test "relay refuses to run when its state directory is group or world writable" {
  mkdir -p "$BASE/s1/relay"
  chmod 700 "$BASE" "$BASE/s1"
  chmod 777 "$BASE/s1/relay"
  printf '1\nrm -rf ~\n' > "$BASE/s1/relay/send-evil"
  PATH="$STUB:$PATH" run "$BIN/fleet-relay" s1
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to use"* ]]
  refute grep -q '^send-keys' "$TMUX_STUB_LOG"
  # The untrusted directory is left alone.
  [ -f "$BASE/s1/relay/send-evil" ]
}

@test "relay refuses a session name that is not a plain name" {
  PATH="$STUB:$PATH" run "$BIN/fleet-relay" "../../etc"
  [ "$status" -eq 1 ]
  [[ "$output" == *"invalid session name"* ]]
}

@test "relay sends a request to the pane, ignores bad ones, and cleans up when the session ends" {
  load_lib
  DIR=$(fleet_state_init s1)
  printf '2\ny\n' > "$DIR/relay/send-ok"
  printf 'not-a-pane\ny\n' > "$DIR/relay/send-badpane"
  ln -s "$DIR/relay/send-ok" "$DIR/relay/send-link"
  # Session is alive for the first loop pass, gone on the second.
  TMUX_STUB_ALIVE=1 PATH="$STUB:$PATH" run "$BIN/fleet-relay" s1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^send-keys' "$TMUX_STUB_LOG")" -eq 1 ]
  grep -qx 'send-keys -t s1:0.2 y Enter' "$TMUX_STUB_LOG"
  [ ! -e "$BASE/s1" ]
}

@test "relay types into a real tmux pane and removes state when the session is killed" {
  command -v tmux >/dev/null || skip "tmux not installed"
  load_lib
  # Isolated tmux server: its socket lives under a throwaway TMUX_TMPDIR.
  E2E_TMPDIR="$(mktemp -d)"
  export TMUX_TMPDIR="$E2E_TMPDIR"
  tmux -f /dev/null new-session -d -s fleet-e2e -x 80 -y 24 'cat'
  tmux split-window -t fleet-e2e:0 'cat'

  DIR=$(fleet_state_init fleet-e2e)
  "$BIN/fleet-relay" fleet-e2e 3>&- &
  RELAY_PID=$!
  printf '1\nhello-from-relay\n' > "$DIR/relay/send-1"

  for _ in $(seq 1 50); do
    tmux capture-pane -p -t fleet-e2e:0.1 | grep -q 'hello-from-relay' && break
    sleep 0.2
  done
  tmux capture-pane -p -t fleet-e2e:0.1 | grep -q 'hello-from-relay'
  tmux capture-pane -p -t fleet-e2e:0.0 > "$WORK/pane0.txt"
  refute grep -q 'hello-from-relay' "$WORK/pane0.txt"
  [ ! -e "$DIR/relay/send-1" ]

  tmux kill-session -t fleet-e2e
  for _ in $(seq 1 50); do
    kill -0 "$RELAY_PID" 2>/dev/null || break
    sleep 0.2
  done
  refute kill -0 "$RELAY_PID"
  [ ! -e "$BASE/fleet-e2e" ]
}

# ── fleet (launcher) ──

@test "launcher keeps names, prompts and logs in the private state dir" {
  stub_launcher_tools
  mkdir "$WORK/project"
  cd "$WORK/project"
  # Answers: mode 4, repo 1 (.), default fleet name, no worktree, 2 agents.
  PATH="$STUB:$BIN:/usr/bin:/bin" run bash -c "printf '4\n1\n\nn\n2\n' | '$BIN/fleet'"
  [ "$status" -eq 0 ]

  SESSION_DIR=$(echo "$BASE"/fleet-*)
  [ -d "$SESSION_DIR" ]
  [ "$(mode_of "$SESSION_DIR")" = "700" ]
  [ "$(cat "$SESSION_DIR/name")" = "project" ]
  [ "$(cat "$SESSION_DIR/names/0")" = "Control Center" ]
  [ "$(cat "$SESSION_DIR/names/1")" = "Agent-1" ]
  [ "$(cat "$SESSION_DIR/names/2")" = "Agent-2" ]
  grep -q 'General development session' "$SESSION_DIR/prompt-1.txt"
  [ -f "$SESSION_DIR/agent-2.log" ]

  # Every path handed to tmux points into the state dir.
  grep -q "pipe-pane .*$SESSION_DIR/agent-1.log" "$TMUX_STUB_LOG"
  grep -q "pane-border-format .*$SESSION_DIR/names/" "$TMUX_STUB_LOG"
  grep -q "claude < '$SESSION_DIR/prompt-1.txt'" "$TMUX_STUB_LOG"
}

@test "launcher does not start any background helper" {
  stub_launcher_tools
  mkdir "$WORK/project"
  cd "$WORK/project"
  PATH="$STUB:$BIN:/usr/bin:/bin" run bash -c "printf '4\n1\n\nn\n2\n' | '$BIN/fleet'"
  [ "$status" -eq 0 ]
  [[ "$output" != *"command not found"* ]]
  # The stub is on PATH, so any attempt to start it would be recorded.
  refute grep -qxE 'fleet-(telegram|notify)' "$STUB_CALLS"
  # The only things in the base dir are session directories.
  [ -z "$(find "$BASE" -maxdepth 1 -type f)" ]
}

@test "launcher stops and kills its session when the state dir cannot be trusted" {
  stub_launcher_tools
  mkdir -p "$BASE"
  chmod 777 "$BASE"
  mkdir "$WORK/project"
  cd "$WORK/project"
  PATH="$STUB:$BIN:/usr/bin:/bin" run bash -c "printf '4\n1\n\nn\n2\n' | '$BIN/fleet'"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to use"* ]]
  grep -q '^kill-session' "$TMUX_STUB_LOG"
  refute grep -q '^send-keys' "$TMUX_STUB_LOG"
}
