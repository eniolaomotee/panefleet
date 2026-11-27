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
- [fzf](https://github.com/junegunn/fzf) and [bat](https://github.com/sharkdp/bat), for the interactive menu only
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

With no arguments you get a menu: choose a mode, a repo and the number of agents. You land in the monitor pane.

To skip the menu, pass options. With any option `fleet` never prompts:

```bash
fleet --agents 3                                   # three agents in the current directory
fleet --feature "CSV export" --agents 2 --repo ~/code/api
fleet --plan docs/plan.md --phase "Phase 2"        # brief agents from one section of a plan
fleet --agents 2 --worktree feature/login          # work in a new git worktree
```

| Option | Meaning |
| --- | --- |
| `-n`, `--agents N` | Number of agents, default 1. In phase mode, per phase. |
| `-r`, `--repo PATH` | Directory the agents work in. Default: current directory. |
| `--name NAME` | Fleet name. Default: the directory name. |
| `--feature TEXT` | Every agent is briefed on this feature. |
| `--plan FILE` | Brief agents from a markdown plan. Each `### Phase ...` section becomes one group of agents. |
| `--phase TEXT` | With `--plan`: only the phase whose heading contains TEXT. Repeatable. Default: every phase. |
| `--worktree NAME` | Create git worktree `../wt-NAME` on a new branch `NAME` and run the agents there. |
| `--no-attach` | Create the session and print its name without attaching. |
| `-h`, `--help` | Show the help text. |

A mistake in the options stops the launch before any tmux session is created. The menu also offers a hybrid mode that has no flag yet.

Inside the monitor:

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
- **No config file.** The launcher takes flags, but there is no way yet to save defaults.
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
