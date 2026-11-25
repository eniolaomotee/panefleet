# panefleet

[![CI](https://github.com/eniolaomotee/panefleet/actions/workflows/ci.yml/badge.svg)](https://github.com/eniolaomotee/panefleet/actions/workflows/ci.yml)

A tmux control center for running several Claude Code agents side by side. One pane is a monitor, the rest are agents, and the monitor shows which files each agent has changed and flags any file touched by more than one of them.

> Status: early. The scripts were imported unchanged from private daily use and are being cleaned up in the open. Read [Known limits](#known-limits) before running it on a shared machine.

## What it does

- **File conflict detection.** Press `s` in the monitor to list changed and new files per agent, with a warning for files modified by more than one agent.
- **Launcher.** `fleet` asks how many agents you want and what they should work on, then builds a tmux session with the monitor on the left and agents stacked on the right.
- **Phase mode.** Pick a markdown plan, select its `### Phase` sections, and each agent starts with that phase as its prompt.
- **Zoom and return.** Press `1` to `9` to zoom into an agent, `F2` to come back to the monitor.
- **Per-agent logs.** Pane output is logged so you can page through an agent's history with `l`.
- **Edit verification hook.** `fleet-verify` is a Claude Code `PostToolUse` hook that syntax-checks edited Python and JavaScript files and reports type and lint errors.

## How this compares to Claude Code's built-in features

TODO: an honest comparison with subagents, background agents and worktrees in Claude Code itself, and when this tool is and is not worth using.

## Requirements

- macOS (clipboard copy uses `pbcopy`; Linux is untested)
- bash, tmux, git
- [fzf](https://github.com/junegunn/fzf) and [bat](https://github.com/sharkdp/bat)
- [Claude Code](https://claude.com/claude-code) available as `claude`
- `jq` for the verify hook

## Setup

```bash
git clone https://github.com/eniolaomotee/panefleet.git
export PATH="$PWD/panefleet/bin:$PATH"
```

The scripts call each other by name, so `bin/` must be on your `PATH`. They also load `lib/state.sh` relative to their own location, so keep the checkout intact instead of copying single scripts elsewhere.

## First run

From a directory that is a git repo, or that contains git repos:

```bash
fleet
```

Choose a mode, a repo and the number of agents. You land in the monitor pane.

| Key | Action |
| --- | --- |
| `1` to `9` | Zoom into an agent |
| `F2` | Return to the monitor from any agent |
| `f` | Focus an agent without zooming |
| `s` | File status and conflicts |
| `l` | View an agent's log |
| `m` | Toggle mouse mode |
| `r` | Refresh |

To stop everything: `tmux kill-session -t <session-name>`. The session name is shown at the top of the monitor.

### Verify hook (optional)

TODO: document the `PostToolUse` entry for `~/.claude/settings.json`.

## Where state lives

Each fleet keeps its runtime state in a private directory:

```
${XDG_STATE_HOME:-~/.local/state}/panefleet/<session>/
```

It holds the pane labels, the agent prompts, the per-agent logs, the mouse preference and the relay directory. The directories are created with mode 700. If one already exists with a different owner or looser permissions, the scripts stop with an error instead of using it.

The relay types the contents of `relay/send-*` files into agent panes, which amounts to running commands as you. It only reads regular files you own, from that private directory, and re-checks the directory on every pass.

State is removed when the session ends. Anything left behind by a crash is cleared the next time you run `fleet`. Agent logs go with it, so copy a log out first if you want to keep it.

## Known limits

- **tmux key bindings are server-wide.** The monitor binds `F2`, the mouse wheel and drag-to-copy in the root table, which affects your other tmux sessions until the server restarts.
- **`fleet-notify` is a stub.** It logs one line and exits.
- **The launcher is interactive only.** There are no flags or config file yet.
- **`fleet-verify` covers Python and JavaScript/TypeScript only.**
- **The commands are still named `fleet*`,** not `panefleet`.

## Development

```bash
brew install shellcheck bats-core tmux
shellcheck --severity=error bin/* lib/*.sh
bats test
```

CI runs the same checks plus a gitleaks secret scan on every pull request.

## License

No license has been chosen yet. Until one is added, all rights are reserved.
