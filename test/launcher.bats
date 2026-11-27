#!/usr/bin/env bats
# Tests for the launcher's flags (issue #18).
#
# The end-to-end tests run the real launcher, monitor and relay against a real
# tmux server on a private socket. Agent panes run a stand-in for `claude`
# that records the prompt and working directory it was given. HOME points at
# an empty directory and SHELL is /bin/sh, so no shell or tmux config from the
# developer's machine is read, and PATH cannot reach a real `claude`.

setup() {
  ROOT="$BATS_TEST_DIRNAME/.."
  BIN="$ROOT/bin"
  WORK="$(mktemp -d)"
  STUB="$WORK/stub"
  OUT="$WORK/out"
  mkdir -p "$STUB" "$OUT" "$WORK/home" "$WORK/project"
  export HOME="$WORK/home"
  export SHELL=/bin/sh
  export TMUX_TMPDIR="$WORK"
  export XDG_STATE_HOME="$WORK/state"
  unset TMUX ENV
  BASE="$XDG_STATE_HOME/panefleet"

  cat > "$STUB/claude" <<STUBEOF
#!/bin/sh
cat > "$OUT/prompt-\$\$.txt"
pwd > "$OUT/cwd-\$\$.txt"
STUBEOF
  chmod +x "$STUB/claude"
  cd "$WORK/project" || return 1
}

teardown() {
  if command -v tmux >/dev/null; then
    tmux kill-server 2>/dev/null || true
  fi
  rm -rf "$WORK"
}

need_tmux() {
  command -v tmux >/dev/null || skip "tmux not installed"
  TMUX_DIR="$(dirname "$(command -v tmux)")"
  GIT_DIR_ON_PATH="$(dirname "$(command -v git)")"
  SAFE_PATH="$STUB:$BIN:$TMUX_DIR:$GIT_DIR_ON_PATH:/usr/bin:/bin"
}

# Launch with flags and wait until every agent's stand-in has run.
launch() {
  local expected="$1"
  shift
  PATH="$SAFE_PATH" run "$BIN/fleet" --no-attach "$@"
  [ "$status" -eq 0 ] || { echo "$output"; return 1; }
  SESSION="${lines[${#lines[@]} - 1]}"
  for _ in $(seq 1 100); do
    [ "$(find "$OUT" -name 'prompt-*.txt' | wc -l | tr -d ' ')" -ge "$expected" ] && return 0
    sleep 0.1
  done
  echo "only $(find "$OUT" -name 'prompt-*.txt' | wc -l) of $expected agents started"
  return 1
}

refute() {
  if "$@"; then
    echo "expected to fail: $*"
    return 1
  fi
}

write_plan() {
  cat > "$WORK/project/plan.md" <<'PLANEOF'
# Plan

### Phase 1: Schema
Create the tables.

### Phase 2: API
Expose the endpoints.

### Phase 3: API docs
Write them up.
PLANEOF
}

# ── help and validation: nothing here may touch tmux ──

@test "--help prints usage and exits 0" {
  run "$BIN/fleet" --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: fleet"* ]]
  [[ "$output" == *"--agents"* ]]
}

@test "invalid options fail with exit 2 before any session is created" {
  # A tmux that records being called: validation must never reach it.
  printf '#!/bin/sh\necho called >> "%s/tmux-called"\n' "$WORK" > "$STUB/tmux"
  chmod +x "$STUB/tmux"
  write_plan
  while IFS='|' read -r args expected; do
    # shellcheck disable=SC2086  # split the argument string into words
    PATH="$STUB:$PATH" run "$BIN/fleet" $args
    [ "$status" -eq 2 ] || { echo "'$args' exited $status: $output"; return 1; }
    [[ "$output" == *"$expected"* ]] || { echo "'$args' printed: $output"; return 1; }
  done <<'CASES'
--bogus|unknown option: --bogus
--agents|option --agents needs a value
--agents 0|--agents must be a positive number
--agents two|--agents must be a positive number
--repo /no/such/dir|--repo is not a directory
--phase x|--phase needs --plan
--plan missing.md|--plan is not a file
--plan plan.md --feature x|cannot be combined
--plan plan.md --phase Nope|matches no heading
--plan plan.md --phase API|matches more than one heading
--worktree -x|not a usable branch name
--worktree wt --feature x|cannot be combined
CASES
  [ ! -e "$WORK/tmux-called" ]
}

@test "a plan without phase headings is rejected" {
  echo "# Just notes" > "$WORK/project/notes.md"
  run "$BIN/fleet" --plan notes.md
  [ "$status" -eq 2 ]
  [[ "$output" == *"no '### Phase' headings"* ]]
}

@test "flag mode does not need fzf or bat" {
  need_tmux
  refute test -e "$STUB/fzf"
  # SAFE_PATH has no fzf or bat unless the system dirs happen to hold them.
  launch 1 --agents 1
  [ -n "$SESSION" ]
}

# ── end to end ──

@test "--agents launches that many agents in the current directory" {
  need_tmux
  launch 2 --agents 2
  [[ "$SESSION" =~ ^fleet-[0-9]+$ ]]

  # Monitor pane plus two agent panes.
  [ "$(tmux list-panes -t "$SESSION:0" | wc -l | tr -d ' ')" = "3" ]
  [ "$(cat "$BASE/$SESSION/names/1")" = "Agent-1" ]
  [ "$(cat "$BASE/$SESSION/names/2")" = "Agent-2" ]
  [ "$(cat "$BASE/$SESSION/name")" = "project" ]

  # Each agent got the general prompt, in the project directory.
  for f in "$OUT"/prompt-*.txt; do
    grep -q 'General development session' "$f"
  done
  for f in "$OUT"/cwd-*.txt; do
    [ "$(cd "$(cat "$f")" && pwd -P)" = "$(pwd -P)" ]
  done

  # The monitor came up in pane 0: it is what writes the mouse preference,
  # and its menu is on screen. (The pane is narrow here, so the banner
  # itself scrolls off.)
  for _ in $(seq 1 50); do
    [ -f "$BASE/$SESSION/mouse-pref" ] && break
    sleep 0.1
  done
  [ -f "$BASE/$SESSION/mouse-pref" ]
  sleep 0.3
  tmux capture-pane -p -t "$SESSION:0.0" > "$WORK/monitor.txt"
  grep -q 'F2 = return here' "$WORK/monitor.txt"
}

@test "--repo and --name set the working directory and the fleet name" {
  need_tmux
  mkdir "$WORK/other repo"
  launch 1 --repo "$WORK/other repo" --name billing
  [ "$(cat "$BASE/$SESSION/name")" = "billing" ]
  [ "$(cd "$(cat "$OUT"/cwd-*.txt)" && pwd -P)" = "$(cd "$WORK/other repo" && pwd -P)" ]
}

@test "--feature briefs every agent on the feature" {
  need_tmux
  launch 2 --feature "CSV export" --agents 2
  for f in "$OUT"/prompt-*.txt; do
    grep -q '^CSV export$' "$f"
  done
}

@test "--plan with --phase briefs agents on that phase only" {
  need_tmux
  write_plan
  launch 2 --plan plan.md --phase "Phase 2" --agents 2
  [ "$(cat "$BASE/$SESSION/names/1")" = "Phase 2: API-A1" ]
  [ "$(cat "$BASE/$SESSION/names/2")" = "Phase 2: API-A2" ]
  for f in "$OUT"/prompt-*.txt; do
    grep -q 'Expose the endpoints.' "$f"
    refute grep -q 'Create the tables.' "$f"
    refute grep -q 'Write them up.' "$f"
  done
}

@test "--plan without --phase launches one group per phase" {
  need_tmux
  write_plan
  launch 3 --plan plan.md
  [ "$(tmux list-panes -t "$SESSION:0" | wc -l | tr -d ' ')" = "4" ]
  [ "$(cat "$BASE/$SESSION/names/1")" = "Phase 1: Schema-A1" ]
  [ "$(cat "$BASE/$SESSION/names/3")" = "Phase 3: API docs-A1" ]
}

@test "--worktree creates the worktree and runs the agent inside it" {
  need_tmux
  git init -q -b main .
  git -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
  launch 1 --worktree feature/login
  [ -d "$WORK/wt-feature-login" ]
  [ "$(git -C "$WORK/wt-feature-login" branch --show-current)" = "feature/login" ]
  [ "$(cd "$(cat "$OUT"/cwd-*.txt)" && pwd -P)" = "$(cd "$WORK/wt-feature-login" && pwd -P)" ]
}

@test "a failed worktree leaves no session and no state behind" {
  need_tmux
  # Not a git repository, so `git worktree add` fails.
  PATH="$SAFE_PATH" run "$BIN/fleet" --no-attach --worktree nope
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not create worktree"* ]]
  refute tmux has-session 2>/dev/null
  [ -z "$(find "$BASE" -mindepth 1 -maxdepth 1 -name 'fleet-*' 2>/dev/null)" ]
}

@test "killing the session removes its state" {
  need_tmux
  launch 1 --agents 1
  [ -d "$BASE/$SESSION" ]
  # Give the relay a moment to start in the monitor pane.
  sleep 1.5
  tmux kill-session -t "$SESSION"
  for _ in $(seq 1 50); do
    [ ! -e "$BASE/$SESSION" ] && break
    sleep 0.1
  done
  [ ! -e "$BASE/$SESSION" ]
}
