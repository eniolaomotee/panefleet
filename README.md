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

- macOS or Linux. It is developed on macOS, and CI runs the tests on Linux.
- bash, git and tmux 3.0 or newer
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

`fleet-verify` checks each file an agent edits and reports problems back to that agent. It is separate from the launcher and works in any Claude Code session.

Add it to `~/.claude/settings.json`, or to `.claude/settings.json` in a project, using the full path to your checkout:

```json
{
  "hooks": {
    "PostToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/panefleet/bin/fleet-verify",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
```

What it reports:

| File type | Check | Result |
| --- | --- | --- |
| `.py` | `python -m py_compile` | Syntax errors are sent to the agent as blocking feedback |
| `.py` | `pyright`, if installed | Type errors are added to the agent's context |
| `.js` | `node --check` | Syntax errors are sent to the agent as blocking feedback |
| `.ts`, `.tsx` | `tsc --noEmit`, if the project has a `tsconfig.json` | Type errors in the edited file are added to the agent's context |
| `.js`, `.jsx`, `.ts`, `.tsx` | `eslint`, if the project has a config and a local install | Lint errors are added to the agent's context |

The edit has already happened by the time the hook runs, so "blocking" means the agent is told to fix the error, not that the edit is undone. The hook stays silent when a file is fine, when it is not inside a Python or Node project, or when `jq` is missing. Each report is capped at 2000 characters. Running `tsc` on a large project can be slow, which is what the `timeout` is for.

## Key bindings and your other tmux sessions

tmux key tables are shared by every session on the server, so the monitor cannot bind a key for one session only. It binds `F2`, the mouse wheel and drag-to-copy with a check instead: the fleet behaviour runs only in sessions the monitor has marked with the `@panefleet` option, and in every other session the key does what it did before. If you already had one of those keys bound, your command is kept as the fallback.

Drag-to-copy uses the first clipboard tool it finds: `pbcopy`, `wl-copy` (on Wayland), `xclip`, then `xsel`. With none of them installed, tmux's own copy behaviour applies.

## Where state lives

Each fleet keeps its runtime state in a private directory:

```
${XDG_STATE_HOME:-~/.local/state}/panefleet/<session>/
```

It holds the pane labels, the agent prompts, the per-agent logs, the mouse preference and the relay directory. The directories are created with mode 700. If one already exists with a different owner or looser permissions, the scripts stop with an error instead of using it.

The relay types the contents of `relay/send-*` files into agent panes, which amounts to running commands as you. It only reads regular files you own, from that private directory, and re-checks the directory on every pass.

State is removed when the session ends. Anything left behind by a crash is cleared the next time you run `fleet`. Agent logs go with it, so copy a log out first if you want to keep it.

## Known limits

- **The key bindings stay registered until the tmux server restarts.** They only act inside fleet sessions (see [Key bindings and your other tmux sessions](#key-bindings-and-your-other-tmux-sessions)), but `tmux list-keys` will still show the wrappers after a fleet ends.
- **The launcher is interactive only.** There are no flags or config file yet.
- **`fleet-verify` covers Python and JavaScript/TypeScript only.**
- **The commands are still named `fleet*`,** not `panefleet`.

## Development

```bash
brew install shellcheck bats-core tmux
shellcheck bin/* lib/*.sh test/*.bats
bats test
```

CI runs the same checks plus a gitleaks secret scan on every pull request.

## License

[MIT](LICENSE)
