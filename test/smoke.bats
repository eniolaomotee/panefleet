#!/usr/bin/env bats
# Smoke tests for the imported scripts. They cover the paths that run without
# a tmux server: parsing, argument checks, dependency checks and the verify hook.

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
}

@test "every script parses" {
  for f in "$BIN"/*; do
    run bash -n "$f"
    [ "$status" -eq 0 ] || { echo "$f: $output"; return 1; }
  done
}

@test "every script is executable" {
  for f in "$BIN"/*; do
    [ -x "$f" ] || { echo "$f is not executable"; return 1; }
  done
}

@test "fleet-monitor without a session prints usage and exits 1" {
  run "$BIN/fleet-monitor"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: fleet-monitor"* ]]
}

@test "fleet-relay without a session prints usage and exits 1" {
  run "$BIN/fleet-relay"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage: fleet-relay"* ]]
}

@test "fleet reports a missing dependency and exits 1" {
  # An empty PATH directory hides tmux, fzf, bat and git.
  PATH="$WORK" run /bin/bash "$BIN/fleet"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing dependency: tmux"* ]]
}

@test "fleet-verify is silent when the hook input has no file" {
  run bash -c "echo '{}' | '$BIN/fleet-verify'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fleet-verify is silent for a file outside any project" {
  echo "x = (" > "$WORK/orphan.py"
  run bash -c "echo '{\"tool_input\":{\"file_path\":\"$WORK/orphan.py\"}}' | '$BIN/fleet-verify'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "fleet-verify blocks a Python syntax error" {
  command -v python >/dev/null || skip "python not on PATH"
  touch "$WORK/pyproject.toml"
  echo "def broken(:" > "$WORK/bad.py"
  run bash -c "echo '{\"tool_input\":{\"file_path\":\"$WORK/bad.py\"}}' | '$BIN/fleet-verify'"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"decision": "block"'* ]]
}

@test "fleet-verify does not block valid Python" {
  command -v python >/dev/null || skip "python not on PATH"
  touch "$WORK/pyproject.toml"
  echo "x = 1" > "$WORK/good.py"
  run bash -c "echo '{\"tool_input\":{\"file_path\":\"$WORK/good.py\"}}' | '$BIN/fleet-verify'"
  [ "$status" -eq 0 ]
  [[ "$output" != *'"decision": "block"'* ]]
}
