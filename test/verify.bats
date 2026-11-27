#!/usr/bin/env bats
# Tests for the fleet-verify PostToolUse hook: when it stays silent, and that
# what it prints is always valid JSON in the shape Claude Code documents.

setup() {
  BIN="$BATS_TEST_DIRNAME/../bin"
  WORK="$(mktemp -d)"
  STUB="$WORK/stub"
  mkdir -p "$STUB"
}

teardown() {
  rm -rf "$WORK"
}

# Run the hook the way Claude Code does: hook input as JSON on stdin.
# jq builds the input so odd characters in the path are encoded correctly.
run_hook() {
  local file="$1" input
  input=$(jq -cn --arg f "$file" '{hook_event_name: "PostToolUse", tool_name: "Edit", tool_input: {file_path: $f}}')
  run bash -c 'printf "%s" "$1" | "$2"' _ "$input" "$BIN/fleet-verify"
}

need_python() {
  command -v python3 >/dev/null || command -v python >/dev/null || skip "python not installed"
}

# Put a fake tool on PATH that prints $2 and exits with $3.
stub_tool() {
  printf '#!/bin/bash\ncat <<"STUBEOF"\n%s\nSTUBEOF\nexit %s\n' "$2" "$3" > "$STUB/$1"
  chmod +x "$STUB/$1"
}

# ── silent cases ──

@test "verify is silent when the hook input has no file" {
  run bash -c "echo '{}' | '$BIN/fleet-verify'"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify is silent for a file outside any project" {
  echo "x = (" > "$WORK/orphan.py"
  run_hook "$WORK/orphan.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify is silent for valid Python" {
  need_python
  touch "$WORK/pyproject.toml"
  echo "x = 1" > "$WORK/good.py"
  # Keep a real pyright on the developer's machine out of this test.
  CLEAN_PATH="/usr/bin:/bin:$(dirname "$(command -v jq)"):$(dirname "$(command -v python3 || command -v python)")"
  PATH="$CLEAN_PATH" run_hook "$WORK/good.py"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "verify is silent for file types it does not check" {
  touch "$WORK/pyproject.toml"
  echo "{" > "$WORK/notes.md"
  run_hook "$WORK/notes.md"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ── blocking feedback ──

@test "verify blocks a Python syntax error with valid JSON" {
  need_python
  touch "$WORK/pyproject.toml"
  echo "def broken(:" > "$WORK/bad.py"
  run_hook "$WORK/bad.py"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<< "$output")" = "block" ]
  [[ "$(jq -r '.reason' <<< "$output")" == "Python syntax error in $WORK/bad.py:"* ]]
  # Python's own message has quotes and newlines; they must survive encoding.
  [[ "$(jq -r '.reason' <<< "$output")" == *"SyntaxError"* ]]
}

@test "verify output stays valid JSON when the path has quotes, backslashes and spaces" {
  need_python
  touch "$WORK/pyproject.toml"
  FILE="$WORK/we\"ird \\ name's.py"
  echo "def broken(:" > "$FILE"
  run_hook "$FILE"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<< "$output")" = "block" ]
  [[ "$(jq -r '.reason' <<< "$output")" == *"$FILE"* ]]
}

@test "verify blocks a JavaScript syntax error with valid JSON" {
  command -v node >/dev/null || skip "node not installed"
  echo '{}' > "$WORK/package.json"
  echo 'const s = "unterminated' > "$WORK/bad.js"
  run_hook "$WORK/bad.js"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<< "$output")" = "block" ]
  [[ "$(jq -r '.reason' <<< "$output")" == "JS syntax error in $WORK/bad.js:"* ]]
}

@test "verify caps the size of a report" {
  need_python
  touch "$WORK/pyproject.toml"
  echo "def broken(:" > "$WORK/bad.py"
  # A fake python that fails with 5000 characters of output.
  stub_tool python3 "$(printf 'x%.0s' $(seq 1 5000))" 1
  PATH="$STUB:$PATH" run_hook "$WORK/bad.py"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.decision' <<< "$output")" = "block" ]
  [ "$(jq -r '.reason | length' <<< "$output")" -eq 2000 ]
}

# ── non-blocking feedback ──

@test "verify reports type errors as additional context, never as a decision" {
  need_python
  touch "$WORK/pyproject.toml"
  echo "x: int = 'a'" > "$WORK/typed.py"
  stub_tool pyright '/x/typed.py:1:10 - error: Type "str" is not assignable to "int"
1 error, 0 warnings, 0 informations' 1
  PATH="$STUB:$PATH" run_hook "$WORK/typed.py"
  [ "$status" -eq 0 ]
  [ "$(jq -r '.hookSpecificOutput.hookEventName' <<< "$output")" = "PostToolUse" ]
  [[ "$(jq -r '.hookSpecificOutput.additionalContext' <<< "$output")" == "Type errors in $WORK/typed.py: 1 error, 0 warnings"* ]]
  [ "$(jq -r 'has("decision")' <<< "$output")" = "false" ]
}

@test "verify never prints a decision other than block" {
  run grep -nE 'decision: *"[a-z]+"|"decision"' "$BIN/fleet-verify"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ "$line" == *block* ]] || { echo "unexpected decision: $line"; return 1; }
  done <<< "$output"
}

# ── degraded environment ──

@test "verify exits 0 and prints nothing when jq is missing" {
  echo "def broken(:" > "$WORK/bad.py"
  touch "$WORK/pyproject.toml"
  PATH="$STUB" run /bin/bash "$BIN/fleet-verify" <<< '{"tool_input":{"file_path":"x.py"}}'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
