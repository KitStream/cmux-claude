# cmux-claude

One Claude Code session per git worktree, each in its own [cmux](https://github.com/manaflow-ai/cmux)
workspace, with a sidebar that shows what every session is doing.

```
~/projects/wz $ cw perf                 # workspace "perf", worktree .claude/worktrees/perf, session "perf"
~/projects/wz $ cw perf --resume        # resume that session
~/projects/wz $ c docs                  # same, but on the main checkout (no worktree)
~/projects/wz $ cw perf --teams         # agent-teams mode: named teammates open as split panes
```

The cmux workspace, the git worktree and the Claude session all carry the same name, so a
name is enough to find any of the three. The repository is the one the shell is in, or
`$CW_REPO` (default `~/projects/wz`) outside any repository, or `--repo <dir>`. The name of
a worktree never picks the repository: a worktree of the same name in another repo is only
mentioned in the refusal of a `--resume` that has nothing to resume.

## What is in here

| Path | Installed to | Purpose |
|---|---|---|
| `cmux/cw.bash` | `~/.config/cmux/` | the `cw` and `c` shell functions, repo resolution, tab completion |
| `cmux/cw-launch.sh` | `~/.config/cmux/` | starts claude *through* cmux's claude wrapper so the session is tracked |
| `cmux/cw-state-hook.sh` | `~/.config/cmux/` | Claude Code hook: stamps working / question / done / idle into the workspace description |
| `cmux/cw-colors-hook.sh`, `cmux/homebrew-colors.sh` | `~/.config/cmux/` | paint the pane in Terminal.app's Homebrew colours, also after a cmux relaunch |
| `cmux/sidebars/workspaces.swift` | `~/.config/cmux/sidebars/` | custom sidebar: compact cards coloured by agent state, pinned block on top |
| `cmux/teams-bin/claude`, `cmux/teams-bin/tmux` | `~/.config/cmux/teams-bin/` | agent-teams mode only: give claude the tmux environment cmux's compat layer expects |
| `patches/claude-settings.hooks.json` | merged into `~/.claude/settings.json` | the hook registrations for `cw-state-hook.sh` and `cw-colors-hook.sh` |
| `patches/bash_profile.snippet` | block in `~/.bash_profile` | sources `cw.bash`; puts `teams-bin` on PATH in `--teams` workspaces |
| `patches/cmux.patch.jsonc` | block in `~/.config/cmux/cmux.json` | pins the two cmux settings the tooling assumes |
| `install.sh`, `uninstall.sh` | | copy and patch; remove and unpatch. Both take `--dry-run` |

## Install

Requirements: macOS, cmux 0.64, Claude Code, bash, `jq` (for the settings.json merge).

```
git clone https://github.com/KitStream/cmux-claude.git
cd cmux-claude
./install.sh --dry-run      # shows every file it would copy or patch
./install.sh
source ~/.bash_profile      # in every terminal that is already open
```

Files are **copied**, not symlinked; re-run `install.sh` after a pull. Existing files that
differ are backed up beside themselves as `<name>.bak-<timestamp>`. The three files that
already exist on a working machine are patched, not replaced, and every patch is idempotent:

- `~/.config/cmux/cmux.json` is JSONC, so `jq` cannot touch it. The installer inserts the
  contents of `patches/cmux.patch.jsonc` between two marker comments before `"schemaVersion"`
  and replaces the block on later runs. If one of the patched keys is already uncommented
  elsewhere in the file it refuses and asks you to merge by hand, because cmux would otherwise
  see a duplicate key.
- `~/.claude/settings.json` gets the hook groups from `patches/claude-settings.hooks.json`
  appended per event, skipping any group whose command is already registered. Everything else
  in the file is left alone.
- `~/.bash_profile` gets the snippet between two marker lines, appended at the end.

The sidebar is chosen in cmux's Settings store, not in `cmux.json`: the installer runs
`cmux sidebar select workspaces` when it runs inside cmux, otherwise it tells you to.

`cw` is a shell **function**. A terminal opened before an install or an edit keeps the old
function until it runs `source ~/.bash_profile`. This has bitten twice; the installer says so.

## How it works, and why it is shaped like this

**Claude goes through cmux's wrapper.** cmux 0.64 injects a per-surface `claude` shim that
adds `--session-id` and its status hooks. That is what gives the sidebar a working / idle /
needs-input state and restores sessions after a relaunch. `cmux claude-teams` execs the real
binary and loses all of it, so `cw-launch.sh` calls plain `claude` and lets PATH resolve it to
the shim.

**Claude is started from the repo root with `-w <name>`,** never from inside the worktree.
The root project directory is where Claude files, and looks for, the worktree's sessions. A
bare `cw perf --resume` gets `perf` as the search term because the worktree-scoped picker
lists only the worktree's own project directory and comes up empty for every session `cw`
started.

**State comes from two places.** The terminal title carries a spinner while Claude works and
`✳` while it waits; that is live even without hooks. Only a question cannot be told from a
finished turn that way, so `cw-state-hook.sh` stamps `claude:question` into the workspace
description from the `AskUserQuestion`, `ExitPlanMode` and permission-prompt hooks, and the
sidebar consults the description for that alone. A stale stamp therefore cannot keep a card
blue. Teammate sessions are recognised by `--agent-id` in their argv and do not stamp.

**The sidebar reads titles, not `agents`.** cmux 0.64 hands `agents` to custom sidebars as
nil. The interpreter is also narrow: optional fields only through `if let`, `contains` rather
than `hasPrefix`, `filter` rather than loops with early return, `.padding(n)` only. The file's
header lists what was found not to evaluate.

**Agent-teams mode is opt-in (`--teams`).** With `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1` on the
workspace, `cw-launch.sh` adds `--teammate-mode auto` and a system prompt that makes teams spawn
as *named* teammates, and `teams-bin/claude` sets `TMUX`/`TMUX_PANE` for the claude process
only, asking cmux's tmux-compat layer for the ids it assigned to the surface (a made-up pane id
makes Claude refuse with "Could not determine current tmux pane/window"). `teams-bin/tmux`
forwards every tmux call to `cmux __tmux-compat` and splices the parent's PATH into the pane
command, because compat-layer panes start from a bare `/bin/sh` without node, homebrew or
`~/bin`. `TMUX` must **not** be in the shell's own environment: it flips cmux's shell
integration into a tmux mode that swallows Claude's title updates and made the wrapper skip
its hooks.

It is opt-in because the pane path is where the open bugs are. In day-to-day use the teammate
panes came up blank, took most of the window width, and never showed idle. Upstream:

- blank or dead teammate panes: cmux [#8129](https://github.com/manaflow-ai/cmux/issues/8129),
  [#4310](https://github.com/manaflow-ai/cmux/issues/4310),
  [#12381](https://github.com/manaflow-ai/cmux/issues/12381),
  [#12830](https://github.com/manaflow-ai/cmux/issues/12830); cmux 0.64.23 adds a rate limiter
  that breaks spawning outright, [#12757](https://github.com/manaflow-ai/cmux/issues/12757),
  [#12682](https://github.com/manaflow-ai/cmux/issues/12682). Stay on 0.64.22 for `--teams`.
- pane size not configurable: claude-code [#23950](https://github.com/anthropics/claude-code/issues/23950)
  (closed, not planned), [#23615](https://github.com/anthropics/claude-code/issues/23615),
  [#25396](https://github.com/anthropics/claude-code/issues/25396); cmux [#2618](https://github.com/manaflow-ai/cmux/issues/2618).
- idle state unreliable in pane mode: claude-code [#29271](https://github.com/anthropics/claude-code/issues/29271),
  [#74638](https://github.com/anthropics/claude-code/issues/74638),
  [#76500](https://github.com/anthropics/claude-code/issues/76500),
  [#85047](https://github.com/anthropics/claude-code/issues/85047).

Plain `cw` sessions run subagents in-process, which is the fallback those issues converge on.

## Uninstall

```
./uninstall.sh --dry-run
./uninstall.sh
```

Removes the copied files, the marked blocks in `cmux.json` and `~/.bash_profile` (plus any
hand-installed `cw` lines), and the hook entries in `~/.claude/settings.json` whose command
runs a file under `~/.config/cmux/`. Groups and events left empty go with them; nothing else
is touched. Backups are written beside each edited file. The sidebar choice is not in any
file: pick the built-in sidebar again from the sidebar toggle's right-click menu.
