#!/usr/bin/env bash
# Claude Code SessionStart hook: paint this session's cmux pane in the Homebrew colours.
#
# `cw` paints a pane once when it creates the workspace, but cmux's own restore after a
# relaunch (and a manual `claude --resume`) never goes through cw, so the colours were lost
# on every restart. Running the paint from the session-start hook covers all three paths.
#
# The hook process may have no controlling terminal (/dev/tty can be "Device not
# configured"), so the pane's tty is found by walking up the process tree to claude.
cat >/dev/null
[[ -n ${CMUX_WORKSPACE_ID:-} ]] || exit 0
pid=$$
for _ in 1 2 3 4 5 6; do
    tty=$(ps -o tty= -p "$pid" 2>/dev/null | tr -d ' ')
    if [[ -n $tty && $tty != '??' && -w /dev/$tty ]]; then
        "$HOME/.config/cmux/homebrew-colors.sh" > "/dev/$tty" 2>/dev/null
        exit 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    [[ -n $pid && $pid != 1 ]] || break
done
exit 0
