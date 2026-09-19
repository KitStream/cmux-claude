#!/usr/bin/env bash
# Claude Code hook: stamp this claude session's state into its cmux workspace description,
# where the custom sidebar (~/.config/cmux/sidebars/workspaces.swift) reads it.
#
#   cw-state-hook.sh working    a prompt was submitted, or a question was answered
#   cw-state-hook.sh question   AskUserQuestion / ExitPlanMode is open, or a permission prompt
#   cw-state-hook.sh done       the turn ended (Stop); the card shows it until you look
#   cw-state-hook.sh idle       session start / end: plain "claude" (hides the branch row)
#
# Wired from ~/.claude/settings.json (UserPromptSubmit, PreToolUse/PostToolUse on
# AskUserQuestion|ExitPlanMode, Notification permission_prompt, Stop, SessionStart, SessionEnd).
# Why hooks: cmux 0.64 tracks all of this in its own store but exposes none of it to custom
# sidebars, and a question looks exactly like idle in the terminal title.
#
# No-op outside cmux, and for teammate sessions (they share the workspace and would flip it).
# A teammate is a claude started with `--agent-id ... --parent-session-id ...`; there is no
# environment variable for it (CLAUDE_CODE_PARENT_SESSION_ID does not exist in 2.1.270, and
# relying on it let four teammates stamp one workspace, 2026-09-14), so look at the argv of
# the claude process this hook runs under.
cat >/dev/null                      # hook input on stdin; not needed, drained to be polite
[[ -n ${CMUX_WORKSPACE_ID:-} ]] || exit 0
pid=$$
for _ in 1 2 3 4 5 6; do
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n $pid && $pid != 1 ]] || break
    cmd=$(ps -o command= -p "$pid" 2>/dev/null)
    [[ $cmd == *" --agent-id "* || $cmd == *" --parent-session-id "* ]] && exit 0
    [[ $cmd == *claude* ]] && break          # reached the (lead) claude process
done
case ${1:-} in
    working|question|done) desc="claude:$1" ;;
    *)                     desc="claude" ;;
esac
CMUX_QUIET=1 "${CMUX_BUNDLED_CLI_PATH:-cmux}" workspace-action --action set_description \
    --description "$desc" --workspace "$CMUX_WORKSPACE_ID" >/dev/null 2>&1
exit 0
