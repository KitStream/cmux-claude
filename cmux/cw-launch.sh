#!/usr/bin/env bash
# Start claude inside a cmux workspace, THROUGH cmux's claude wrapper.
#
# The wrapper (the per-surface `claude` shim that injects --session-id and the hook --settings)
# is what lets cmux track the session: working/idle/needs-input state in the sidebar, restore
# after a relaunch. `cmux claude-teams` (cmux 0.64) execs the real binary directly and loses all
# of that, so this script calls plain `claude`, which resolves to the shim.
#
# Two modes, chosen by the WORKSPACE environment that cw sets:
#
#   default                     plain claude. Subagents run in-process; no teammate panes.
#   CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1   (cw --teams) agent-teams mode: --teammate-mode auto
#                               plus a system prompt that makes teams spawn as NAMED teammates,
#                               which cmux's tmux shim (~/.config/cmux/teams-bin) opens as split
#                               panes. Opt-in since 2026-09-19: the panes came up blank, took
#                               most of the window width and never went idle (open cmux and
#                               claude-code issues, see the header of cw.bash).
#
# Verified against the launcher's own process environment (2026-09-10), teams mode:
#   CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1, TERM=screen-256color,
#   TMUX=/tmp/cmux-claude-teams/<workspace>,<window>,<n>, TMUX_PANE=%<n>,
#   CMUX_CLAUDE_TEAMS_CMUX_BIN=<cmux cli>  (makes the shim dir's `tmux` exec `cmux __tmux-compat`)
#   claude --teammate-mode auto --append-system-prompt "<launcher text>"
set -u

if [[ -z ${CMUX_WORKSPACE_ID:-} ]]; then
    exec caffeinate claude --allow-dangerously-skip-permissions "$@"          # not in cmux: plain claude
fi

if [[ -z ${CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS:-} ]]; then
    exec caffeinate claude --allow-dangerously-skip-permissions "$@"          # default: plain claude
fi

# ---- agent-teams mode (cw --teams) ---------------------------------------------------------
# TMUX/TMUX_PANE are NOT set here: ~/.config/cmux/teams-bin/claude, reached through cmux's
# wrapper, asks cmux's tmux layer for the pane and session ids it assigns to this surface. A
# made-up pane id makes claude refuse to open teammate panes ("Could not determine current tmux
# pane/window"). That shim also covers cmux's own restore after a relaunch.

prompt='You are Claude Code running inside cmux, started with `cmux claude-teams`. Agent teams are enabled and every NAMED teammate opens in its own split pane. When the user asks you to start a team, demo teams, or run several subagents/teammates in parallel, spawn them as named teammates: make one Task tool call per teammate, each with a distinct `name` (a short role), all in a single message so they run concurrently in their own split panes. Prefer named teammates over in-process subagents for any team or parallel-agent request. If the user asks for an open-ended demo such as "make a demo team with 5 subagents" without naming a topic, do not ask which feature — pick that many sensible roles and spawn them right away.'

# On a resume the appended prompt is left out: the conversation already carries its recorded
# system prompt (claude replays it as-is on resume), and mixing a fresh prompt with the resume
# picker got in the way of selecting a session.
resume=0
for a in "$@"; do
    case $a in
        --resume|--resume=*|-r|--continue|-c) resume=1 ;;
    esac
done

# `claude` resolves through PATH to cmux's per-surface shim -> cmux-claude-wrapper -> real claude.
if (( resume )); then
    exec caffeinate claude --allow-dangerously-skip-permissions --teammate-mode auto "$@"
fi
exec caffeinate claude --allow-dangerously-skip-permissions --teammate-mode auto --append-system-prompt "$prompt" "$@"
