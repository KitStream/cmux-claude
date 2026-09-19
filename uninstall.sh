#!/usr/bin/env bash
# Undo install.sh: remove the copied files and take the managed blocks and hook entries back
# out of the three patched config files.
#
#   ./uninstall.sh            remove
#   ./uninstall.sh --dry-run  say what would change, touch nothing
#
# Removed: every file under cmux/ in this checkout at its place under ~/.config/cmux, plus the
# then-empty sidebars/ and teams-bin/ directories. Patched files are edited in place, with a
# backup beside them as <name>.bak-<timestamp>:
#   ~/.config/cmux/cmux.json      the marked block goes; nothing else in the file is touched.
#                                 That puts the socket back in its default mode (cmuxOnly).
#                                 ~/.config/cmux/socket-password is kept: cmux keeps its copy.
#   ~/.claude/settings.json       hook entries whose command runs a file under
#                                 ~/.config/cmux/ go; groups and events left empty go with
#                                 them; everything else stays.
#   ~/.bash_profile               the marked block goes, and so do the hand-installed lines
#                                 install.sh would have absorbed (source cw.bash, teams-bin
#                                 PATH, their two comment lines).
# Backups install.sh made (*.bak-*) are left alone. The sidebar choice lives in cmux's Settings
# store: pick the built-in sidebar again from the sidebar toggle's right-click menu.
# Running it twice is safe: the second run finds nothing to do.
set -euo pipefail

here=$(cd -P -- "$(dirname -- "$0")" && pwd)
dry=0
for a in "$@"; do
    case $a in
        --dry-run|-n) dry=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "uninstall.sh: unknown argument $a" >&2; exit 2 ;;
    esac
done

dest="$HOME/.config/cmux"
cmux_json="$dest/cmux.json"
claude_settings="$HOME/.claude/settings.json"
profile="$HOME/.bash_profile"
stamp=$(date +%Y%m%d-%H%M%S)
changed=0

say()  { printf '%s\n' "$*"; }
plan() { if (( dry )); then say "would: $*"; else say "$*"; fi; }
backup() { [[ -e $1 ]] || return 0; (( dry )) && return 0; cp -p "$1" "$1.bak-$stamp"; }

# ---- 1. remove the copied files ---------------------------------------------------------
while IFS= read -r -d '' f; do
    rel=${f#"$here/cmux/"}
    dst="$dest/$rel"
    [[ -e $dst ]] || continue
    changed=1
    plan "remove     $dst"
    (( dry )) || rm -f "$dst"
done < <(find "$here/cmux" -type f -print0 | sort -z)
for d in "$dest/sidebars" "$dest/teams-bin"; do
    if [[ -d $d ]] && [[ -z $(ls -A "$d") ]]; then
        plan "rmdir      $d"
        (( dry )) || rmdir "$d"
    fi
done

# ---- 2. cmux.json: drop the managed block -----------------------------------------------
begin_mark='  // >>> cmux-claude: managed by install.sh, do not edit between the markers'
end_mark='  // <<< cmux-claude'
if [[ -e $cmux_json ]] && grep -qF -- "$begin_mark" "$cmux_json"; then
    tmp=$(mktemp)
    awk -v b="$begin_mark" -v e="$end_mark" '$0 == b { skip = 1; next } $0 == e { skip = 0; next } !skip { print }' "$cmux_json" > "$tmp"
    changed=1
    plan "patch      $cmux_json  (managed block removed, backup $cmux_json.bak-$stamp)"
    if (( dry )); then rm -f "$tmp"; else backup "$cmux_json"; cat "$tmp" > "$cmux_json"; rm -f "$tmp"; fi
elif [[ -e $cmux_json && -e $dest/socket-password ]] && command -v jq >/dev/null 2>&1 \
        && jq -e '.automation.socketControlMode == "password"' "$cmux_json" >/dev/null 2>&1; then
    # cmux rewrote the file as plain JSON when it took the socket password (see install.sh):
    # no markers left, so the keys the block set are taken out with jq.
    tmp=$(mktemp)
    jq 'del(.app.reorderOnNotification, .automation.claudeCodeIntegration,
            .automation.socketControlMode, .automation.socketPassword)
        | if .app == {} then del(.app) else . end
        | if .automation == {} then del(.automation) else . end' "$cmux_json" > "$tmp"
    changed=1
    plan "patch      $cmux_json  (keys of the managed block removed, backup $cmux_json.bak-$stamp)"
    if (( dry )); then rm -f "$tmp"; else backup "$cmux_json"; cat "$tmp" > "$cmux_json"; rm -f "$tmp"; fi
elif [[ -e $cmux_json ]]; then
    say "unchanged  $cmux_json (no managed block)"
fi
# The socket password itself STAYS. cmux keeps its copy in a private store, and does not take
# a different one from cmux.json while it has that (seen 2026-09-19: uninstall, install, and
# the freshly generated password was refused as invalid). With the socket back in its default
# mode (cmuxOnly) the password opens nothing; a later install.sh picks it up again, and with
# socket-password.imported also kept it knows not to offer cmux the password a second time.
for f in "$dest/sidebar-select.pending"; do
    [[ -e $f ]] || continue
    changed=1
    plan "remove     $f"
    (( dry )) || rm -f "$f"
done
if [[ -e $dest/socket-password ]]; then
    say "kept       $dest/socket-password  (cmux still holds this password; to be rid of it, clear it in"
    say "           cmux Settings > Automation and delete the file and socket-password.imported)"
fi

# ---- 3. settings.json: drop our hook entries --------------------------------------------
if [[ -e $claude_settings ]]; then
    if ! command -v jq >/dev/null 2>&1; then
        say "skipped    $claude_settings: jq is not installed; remove the hooks that run ~/.config/cmux/cw-*.sh by hand"
    else
        tmp=$(mktemp)
        jq '
            if .hooks == null then . else
            .hooks |= (
                map_values(
                    map( .hooks |= map(select((.command // "") | test("\\.config/cmux/") | not)) )
                    | map(select((.hooks | length) > 0))
                )
                | with_entries(select((.value | length) > 0))
            )
            | if (.hooks | length) == 0 then del(.hooks) else . end
            end
        ' "$claude_settings" > "$tmp"
        if cmp -s "$tmp" "$claude_settings"; then
            say "unchanged  $claude_settings (no cmux hooks)"
            rm -f "$tmp"
        else
            changed=1
            plan "patch      $claude_settings  (cmux hook entries removed, backup $claude_settings.bak-$stamp)"
            if (( dry )); then rm -f "$tmp"; else backup "$claude_settings"; cat "$tmp" > "$claude_settings"; rm -f "$tmp"; fi
        fi
    fi
fi

# ---- 4. bash_profile: drop the managed block and any hand-installed lines ----------------
pbegin='# >>> cmux-claude: managed by install.sh, do not edit between the markers'
pend='# <<< cmux-claude'
if [[ -e $profile ]]; then
    tmp=$(mktemp)
    # Lines dropped are counted; a profile that had none is left byte-for-byte alone.
    removed=$(awk -v b="$pbegin" -v e="$pend" -v out="$tmp" '
        $0 == b { skip = 1; n++; next }
        $0 == e { skip = 0; n++; next }
        skip { n++; next }
        /\.config\/cmux\/(cw\.bash|teams-bin)/ { n++; next }
        /^# cw: one Claude/ || /^# Claude Code agent teams inside cmux/ { n++; next }
        { print > out }
        END { close(out); print n + 0 }' "$profile")
    if (( removed == 0 )); then
        say "unchanged  $profile (no cw lines)"
        rm -f "$tmp"
    else
        # trailing blank lines left behind by the removed block collapse to one newline
        rest=$(cat "$tmp")
        if [[ -n $rest ]]; then printf '%s\n' "$rest" > "$tmp"; else : > "$tmp"; fi
        changed=1
        plan "patch      $profile  (cw lines removed, backup $profile.bak-$stamp)"
        if (( dry )); then rm -f "$tmp"; else backup "$profile"; cat "$tmp" > "$profile"; rm -f "$tmp"; fi
    fi
fi

# ---- done ----------------------------------------------------------------------------------
say ""
if (( dry )); then
    say "dry run: nothing changed."
elif (( changed )); then
    say "removed. In every open terminal:  unset -f cw c _cw_reach_cmux _cw_resolve_repo _cw_complete   (or open a new one)"
    say "Pick the built-in sidebar again: right-click the sidebar toggle button."
    say "cmux re-reads cmux.json on relaunch or with reloadConfiguration (cmd+shift+,)."
else
    say "nothing installed."
fi
