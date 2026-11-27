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

@test "scripts only reference fleet-* commands that are shipped in bin/" {
  refs=$(grep -ohE 'fleet-[a-z]+' "$BIN"/* "$BIN"/../lib/* | sort -u)
  [ -n "$refs" ]
  for name in $refs; do
    [ -x "$BIN/$name" ] || { echo "$name is referenced but not in bin/"; return 1; }
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
