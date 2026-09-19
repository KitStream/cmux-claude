# cw — one Claude Code session per git worktree, each in its own cmux workspace.
#
#   cw [-w] <worktree> [claude args...]
#   cw perf                     new session on .claude/worktrees/perf (created by claude if missing)
#   cw -w perf                  same; the -w is optional so `claude -w perf` muscle memory works
#   cw perf --resume            pick a session to resume from that worktree
#   cw perf --resume <id>       resume a specific session
#   cw docs --no-worktree       named workspace and session, but on the main checkout (no -w)
#   cw --resume perf            same as `cw perf --resume perf`: the term names the workspace too
#   c --resume wz               resume the main-checkout session "wz" in a workspace "wz"
#   cw --repo ~/projects/other perf     force a repository
#   cw perf --teams             agent-teams mode: named teammates open as cmux split panes
#
# Everything after the worktree name is passed to claude unchanged (--no-worktree and --teams
# are ours and taken out). The cmux workspace, the git worktree and the claude session all
# carry the same name. Claude starts through cw-launch.sh so cmux's wrapper tracks the session.
# Agent-teams mode is OPT-IN (--teams) since 2026-09-19: by default the teammate panes came up
# blank, grabbed most of the window width and never showed idle (open cmux #8129/#12381/#2618,
# claude-code #29271/#76500), so plain claude with in-process subagents is the default.
#
# Which repository: --repo wins; otherwise the repo the shell is in; outside any repository the
# default ($CW_REPO, else ~/projects/wz). The worktree or session NAME never chooses the repo:
# an earlier version looked for a repo that already had a worktree of that name, and `cw auto-test`
# from ~/projects/wzmono silently started in ~/projects/wz because wz had one too (2026-09-15,
# second time). A --resume for a name the chosen repo has no worktree of is refused with the
# repos that do have it, so the fix is a cd or --repo, never a guess. Claude is always started
# from the repo root with -w <name>, never from inside the worktree, because the root is where
# it files, and looks for, the worktree's sessions.
#
# Run it from a terminal inside cmux: the cmux socket refuses processes cmux did not start.
cw() {
    local explicit_repo=""
    if [[ ${1:-} == --repo ]]; then
        explicit_repo=${2:-}
        shift 2
    fi
    if [[ ${1:-} == -w || ${1:-} == --worktree ]]; then
        shift
    fi
    local name=${1:-}
    if [[ ( $name == --resume || $name == -r ) && -n ${2:-} && ${2:-} != -* ]]; then
        # `cw --resume foo` / `c --resume foo`: the resume term names the session, so it can
        # name the workspace and worktree too. Leaves the args as they are.
        name=$2
    else
        if [[ -z $name || $name == -* ]]; then
            echo "usage: cw [--repo <dir>] [-w] <worktree> [claude args...]" >&2
            echo "       cw --resume <name>   (the name doubles as the workspace)" >&2
            return 2
        fi
        shift
    fi
    if [[ -z ${CMUX_WORKSPACE_ID:-} ]]; then
        echo "cw: run this inside a cmux terminal (the cmux socket only accepts processes started by cmux)" >&2
        return 1
    fi

    # --no-worktree: same named workspace and session, but claude runs on the main checkout
    # (no -w). --teams: agent-teams mode with teammate panes (see the header). Both are ours,
    # not claude's, so they are taken out before the pass-through.
    local a worktree=1 teams=0 rest=()
    for a in "$@"; do
        case $a in
            --no-worktree) worktree=0 ;;
            --teams)       teams=1 ;;
            *)             rest+=("$a") ;;
        esac
    done

    # Resolve the repository (see the header and _cw_resolve_repo).
    local wants_resume=0
    for a in "${rest[@]}"; do
        case $a in --resume|--resume=*|-r|--continue|-c) wants_resume=1 ;; esac
    done
    local here="" top
    if top=$(git rev-parse --show-toplevel 2>/dev/null); then
        here=$(git -C "$top" worktree list 2>/dev/null | awk 'NR==1 {print $1}')
    fi
    local root
    root=$(_cw_resolve_repo "$name" "$worktree" "$wants_resume" "$here" \
        "${CW_REPO:-$HOME/projects/wz}" "${CW_PROJECTS:-$HOME/projects}" "$explicit_repo") || return 1
    if [[ ! -d $root/.git && ! -f $root/.git ]]; then
        echo "cw: $root is not a git repository" >&2
        return 1
    fi
    echo "cw: $name in $root"
    if [[ -n $here && $here != "$root" ]]; then
        echo "cw: note: this shell is in $here, not in $root"
    fi
    local cwd=$root

    # Homebrew colours for this pane only (OSC sequences, see the script), then claude via
    # cw-launch.sh, which goes THROUGH cmux's claude wrapper so the session is tracked (status
    # in the sidebar, restore on relaunch). `cmux claude-teams` itself bypasses the wrapper in
    # cmux 0.64. The sidebar's branch row is not fought here: cmux derives it from the shell's
    # directory, so the custom sidebar hides it instead.
    local cmd="$HOME/.config/cmux/homebrew-colors.sh; $HOME/.config/cmux/cw-launch.sh -n $(printf '%q' "$name")"
    if (( worktree )); then
        cmd+=" -w $(printf '%q' "$name")"
    fi
    # A bare --resume gets the name as its search term. Claude files a `-w` session under the
    # ROOT project directory, but its worktree-scoped picker (`-w X --resume`) lists only the
    # worktree's own project directory, so the picker comes up empty (header, no rows) for
    # every session cw has started. A search term is matched across all sessions and, since
    # cw names every session after its worktree, finds them; one match resumes directly.
    local i n=${#rest[@]}
    for (( i = 0; i < n; i++ )); do
        if [[ ${rest[i]} == --resume || ${rest[i]} == -r ]]; then
            if (( i + 1 == n )) || [[ ${rest[i+1]} == -* ]]; then
                rest=("${rest[@]:0:i+1}" "$name" "${rest[@]:i+1}")
                n=${#rest[@]}
            fi
        fi
    done
    for a in "${rest[@]}"; do
        cmd+=" $(printf '%q' "$a")"
    done
    # --description claude marks the workspace for the custom sidebar (no branch row).
    # With --teams, CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1 goes on the WORKSPACE (--env) so it
    # survives cmux's own `claude --resume` after a relaunch: ~/.bash_profile then puts
    # ~/.config/cmux/teams-bin on PATH, whose `claude` adds TMUX/TMUX_PANE for the claude
    # process only and whose `tmux` forwards to cmux's split layer, and cw-launch.sh sees the
    # variable and adds --teammate-mode auto plus the teams system prompt. TMUX must NOT be in
    # the shell's environment: it flips cmux's shell integration into a tmux mode that loses
    # claude's title updates and made the wrapper skip its hooks (2026-09-11). Without --teams
    # the workspace carries no such variable and claude starts plain.
    local env_args=()
    if (( teams )); then
        env_args=(--env CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS=1)
        echo "cw: agent-teams mode (teammate panes)"
    fi
    CMUX_QUIET=1 cmux workspace create --name "$name" --cwd "$cwd" --focus true \
        --description claude \
        "${env_args[@]}" \
        --command "$cmd"
}

# Which repository a session belongs to. Prints the repo root, or explains and fails.
#   _cw_resolve_repo <name> <worktree 0|1> <resume 0|1> <here|""> <default> <projects-dir> <explicit|"">
# Order: --repo, else the shell's repo, else the default. The NAME never picks the repo (see the
# header). The only check: a --resume of a worktree session needs the worktree to exist in the
# chosen repo; if it does not, refuse and list the repos under <projects-dir> that have it, so the
# user cds or passes --repo. (Nothing to resume in the chosen repo; claude would show an empty
# picker, and any other repo would be a guess.)
_cw_resolve_repo() {
    local name=$1 worktree=$2 resume=$3 here=$4 default=$5 projects=$6 explicit=$7
    if [[ -n $explicit ]]; then
        echo "$explicit"
        return 0
    fi
    local root=${here:-$default}
    if (( worktree && resume )) && [[ ! -d $root/.claude/worktrees/$name ]]; then
        echo "cw: no worktree '$name' in $root, so there is nothing to resume there." >&2
        local d found=()
        for d in "$projects"/*/.claude/worktrees/"$name"; do
            [[ -d $d ]] && found+=("${d%/.claude/worktrees/*}")
        done
        if (( ${#found[@]} )); then
            echo "    It exists in these repositories; cd there or pass --repo:" >&2
            for d in "${found[@]}"; do
                printf '      cw --repo %s %s ...\n' "$d" "$name" >&2
            done
        else
            echo "    No repository under $projects has it either; check the name, or start it fresh without --resume." >&2
        fi
        return 1
    fi
    echo "$root"
}

# c <name> [claude args...]  —  shorthand for `cw <name> --no-worktree`.
c() {
    cw "$@" --no-worktree
}

# Tab completion: worktree names from the repo cw would use (the shell's, else the default), then flags.
_cw_complete() {
    local cur=${COMP_WORDS[COMP_CWORD]}
    if [[ $COMP_CWORD -eq 1 ]]; then
        local root=${CW_REPO:-$HOME/projects/wz} top
        if top=$(git rev-parse --show-toplevel 2>/dev/null); then
            root=$(git -C "$top" worktree list 2>/dev/null | awk 'NR==1 {print $1}')
        fi
        local names=""
        [[ -d $root/.claude/worktrees ]] && names=$(ls "$root/.claude/worktrees")
        COMPREPLY=( $(compgen -W "$names" -- "$cur") )
    else
        COMPREPLY=( $(compgen -W "--resume --continue --fork-session --no-worktree --teams --repo" -- "$cur") )
    fi
}
complete -F _cw_complete cw c
