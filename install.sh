#!/usr/bin/env bash
# Install the cmux + Claude Code tooling from this checkout into the current user's home.
#
#   ./install.sh            install (copies files, patches the three existing config files)
#   ./install.sh --dry-run  say what would change, touch nothing
#
# Files are COPIED, not symlinked: the checkout can move or go away and the setup keeps
# working; re-run install.sh after a pull to pick up changes. Existing files that differ are
# backed up beside themselves as <name>.bak-<timestamp> before they are replaced.
#
# Three files that already exist on a working machine are PATCHED, not replaced:
#   ~/.config/cmux/cmux.json      a marked block from patches/cmux.patch.jsonc is inserted
#                                 before "schemaVersion" (JSONC: comments survive, jq cannot
#                                 be used); an existing block is replaced. The block switches
#                                 the socket to password mode; the generated password is kept
#                                 in ~/.config/cmux/socket-password (mode 600) and handed to
#                                 cmux through the block once (see patch_cmux_json).
#   ~/.claude/settings.json       the hook groups in patches/claude-settings.hooks.json are
#                                 merged with jq; a group whose command is already present
#                                 is left alone, everything else in the file is untouched.
#   ~/.bash_profile               a marked block from patches/bash_profile.snippet is
#                                 appended; an existing block is replaced.
# Every patch is idempotent: running the installer twice changes nothing the second time.
set -euo pipefail

here=$(cd -P -- "$(dirname -- "$0")" && pwd)
dry=0
for a in "$@"; do
    case $a in
        --dry-run|-n) dry=1 ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "install.sh: unknown argument $a" >&2; exit 2 ;;
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

backup() {                                   # backup <file>: copy aside, once per run
    local f=$1
    [[ -e $f ]] || return 0
    (( dry )) && return 0
    cp -p "$f" "$f.bak-$stamp"
}

# ---- 1. copy the tooling files ----------------------------------------------------------
copy_file() {                                # copy_file <relative path under cmux/>
    local rel=$1 src="$here/cmux/$1" dst="$dest/$1"
    if [[ -e $dst ]] && cmp -s "$src" "$dst"; then
        say "unchanged  $dst"
        return 0
    fi
    changed=1
    if [[ -e $dst ]]; then
        plan "replace    $dst  (backup $dst.bak-$stamp)"
        backup "$dst"
    else
        plan "install    $dst"
    fi
    (( dry )) && return 0
    mkdir -p "$(dirname -- "$dst")"
    cp -p "$src" "$dst"
    case $rel in *.sh|teams-bin/*) chmod 755 "$dst" ;; esac
}

while IFS= read -r -d '' f; do
    copy_file "${f#"$here/cmux/"}"
done < <(find "$here/cmux" -type f -print0 | sort -z)

# ---- 2. patch cmux.json (JSONC) ----------------------------------------------------------
# The block lives between two marker comments. It goes BEFORE "schemaVersion" so that the
# file stays valid whatever follows: every entry in the patch ends with a comma. If a key the
# patch sets is already file-managed (uncommented) elsewhere in the file, the block is not
# inserted and the user is told to merge by hand: cmux would see a duplicate key otherwise.
begin_mark='  // >>> cmux-claude: managed by install.sh, do not edit between the markers'
end_mark='  // <<< cmux-claude'
password_file="$dest/socket-password"
imported_flag="$dest/socket-password.imported"
# What cmux does with "socketPassword" shapes all of this: on launch or config reload it moves
# the value into its own private store, deletes the key from cmux.json and rewrites the whole
# file as plain JSON, so the comments and the markers are gone (it keeps a cmux.<time>.bak).
# A file without the key it leaves alone. So:
#   - the password lives in $password_file (mode 600), which is where cw reads it;
#   - the block carries "socketPassword" only until cmux has taken it ($imported_flag), and
#     only "socketControlMode" after that, which keeps the file stable;
#   - a file cmux has rewritten is recognised (no markers, plain JSON, password mode, no
#     password key), has the keys this patch owns taken out with jq, and gets the block back.
patch_cmux_json() {
    local template="$here/patches/cmux.patch.jsonc" patch tmp src key clash=0 password=""
    if [[ ! -e $cmux_json ]]; then
        changed=1
        plan "create     $cmux_json  (cmux normally writes its template on first launch)"
        (( dry )) && return 0
        mkdir -p "$dest"
        printf '{\n  "$schema": "https://raw.githubusercontent.com/manaflow-ai/cmux/main/web/data/cmux.schema.json",\n  "schemaVersion": 1\n}\n' > "$cmux_json"
    fi

    # The password: generated once, then kept, so running terminals stay valid.
    if [[ -s $password_file ]]; then
        password=$(<"$password_file")
    else
        password=$(openssl rand -hex 24)
        changed=1
        plan "create     $password_file  (socket password, mode 600)"
        if (( ! dry )); then
            rm -f "$imported_flag"
            ( umask 077; printf '%s\n' "$password" > "$password_file" )
        fi
    fi

    # Has cmux taken the password yet? Either it answers to it, or it has rewritten the file.
    src=$cmux_json
    local rewritten=0
    if ! grep -qF -- "$begin_mark" "$cmux_json" && command -v jq >/dev/null 2>&1 \
            && jq -e '.automation.socketControlMode == "password" and (.automation | has("socketPassword") | not)' \
                "$cmux_json" >/dev/null 2>&1; then
        rewritten=1
    fi
    if [[ ! -e $imported_flag ]]; then
        if (( rewritten )) || { command -v cmux >/dev/null 2>&1 \
                && CMUX_QUIET=1 CMUX_SOCKET_PASSWORD=$password cmux ping >/dev/null 2>&1 \
                && ! env -u CMUX_SOCKET_PASSWORD -u CMUX_WORKSPACE_ID -u CMUX_SURFACE_ID cmux ping >/dev/null 2>&1; }; then
            (( dry )) || : > "$imported_flag"
            local imported=1
        else
            local imported=0
        fi
    else
        local imported=1
    fi
    if (( rewritten )); then
        say "note       $cmux_json was rewritten by cmux (it took the socket password); restoring the managed block"
        src=$(mktemp)
        jq 'del(.app.reorderOnNotification, .automation.claudeCodeIntegration,
                .automation.socketControlMode, .automation.socketPassword)
            | if .app == {} then del(.app) else . end
            | if .automation == {} then del(.automation) else . end' "$cmux_json" > "$src"
    fi

    # keys the patch sets at top level: lines like  "app": {
    while IFS= read -r key; do
        if awk -v b="$begin_mark" -v e="$end_mark" -v k="\"$key\"" '
                $0 == b { skip = 1 } $0 == e { skip = 0; next }
                !skip && $1 == k":" { found = 1 }
                END { exit found ? 0 : 1 }' "$src"; then
            say "conflict   $cmux_json already file-manages \"$key\"; merge patches/cmux.patch.jsonc by hand"
            clash=1
        fi
    done < <(sed -n 's/^  "\([^"]*\)": .*/\1/p' "$template")
    if (( clash )); then
        [[ $src == "$cmux_json" ]] || rm -f "$src"
        return 0
    fi

    patch=$(mktemp)
    if (( imported )); then
        sed '/"socketPassword"/d' "$template" > "$patch"
    else
        sed "s/\"@SOCKET_PASSWORD@\"/\"$password\"/" "$template" > "$patch"
    fi
    tmp=$(mktemp)
    awk -v b="$begin_mark" -v e="$end_mark" -v patch="$patch" '
        BEGIN { while ((getline line < patch) > 0) block = block line "\n"; close(patch) }
        $0 == b { skip = 1; next }
        $0 == e { skip = 0; next }
        skip { next }
        !done && $0 ~ /^[[:space:]]*"schemaVersion"[[:space:]]*:/ { printf "%s\n%s%s\n", b, block, e; done = 1 }
        { print }
        END { if (!done) exit 3 }' "$src" > "$tmp" || {
            rm -f "$tmp" "$patch"
            [[ $src == "$cmux_json" ]] || rm -f "$src"
            say "skipped    $cmux_json has no \"schemaVersion\" line; insert patches/cmux.patch.jsonc by hand"
            return 0
        }
    rm -f "$patch"
    [[ $src == "$cmux_json" ]] || rm -f "$src"
    if cmp -s "$tmp" "$cmux_json"; then
        say "unchanged  $cmux_json"
        rm -f "$tmp"
        (( dry )) || chmod 600 "$cmux_json"
        return 0
    fi
    changed=1
    plan "patch      $cmux_json  (managed block, socket password mode, backup $cmux_json.bak-$stamp)"
    if (( ! imported )); then
        say "note       cmux takes the socket password out of cmux.json at its next launch or config reload and"
        say "           rewrites the file without comments; run install.sh once more after that to restore the block"
    fi
    if (( dry )); then rm -f "$tmp"; return 0; fi
    backup "$cmux_json"
    chmod 600 "$cmux_json"                   # before the password goes in
    cat "$tmp" > "$cmux_json"
    rm -f "$tmp"
}
patch_cmux_json

# ---- 3. patch ~/.claude/settings.json (JSON, via jq) --------------------------------------
# For every event in the fragment, append each hook group unless a group with one of the
# same commands is already registered for that event. Nothing else in the file is touched.
patch_claude_settings() {
    local patch="$here/patches/claude-settings.hooks.json" tmp
    if ! command -v jq >/dev/null 2>&1; then
        say "skipped    $claude_settings: jq is not installed (brew install jq), merge $patch by hand"
        return 0
    fi
    if [[ ! -e $claude_settings ]]; then
        changed=1
        plan "create     $claude_settings"
        (( dry )) && return 0
        mkdir -p "$(dirname -- "$claude_settings")"
        printf '{}\n' > "$claude_settings"
    fi
    tmp=$(mktemp)
    jq --slurpfile p "$patch" '
        def merge_event($existing; $new):
            ([$existing[].hooks[].command]) as $have
            | $existing + [ $new[] | select( any(.hooks[].command; IN($have[])) | not ) ];
        reduce ($p[0].hooks | to_entries[]) as $e
            (.; .hooks[$e.key] = merge_event((.hooks[$e.key] // []); $e.value))
    ' "$claude_settings" > "$tmp"
    if cmp -s "$tmp" "$claude_settings"; then
        say "unchanged  $claude_settings"
        rm -f "$tmp"
        return 0
    fi
    changed=1
    plan "patch      $claude_settings  (hook groups, backup $claude_settings.bak-$stamp)"
    if (( dry )); then rm -f "$tmp"; return 0; fi
    backup "$claude_settings"
    cat "$tmp" > "$claude_settings"
    rm -f "$tmp"
}
patch_claude_settings

# ---- 4. patch ~/.bash_profile -------------------------------------------------------------
pbegin='# >>> cmux-claude: managed by install.sh, do not edit between the markers'
pend='# <<< cmux-claude'
# Besides an earlier managed block, the lines a hand-installed setup put there are removed:
# the `source cw.bash` and teams-bin PATH lines and the two comment lines that introduced
# them (matched exactly), so the block does not duplicate them. Trailing blank lines are
# normalised to one, which keeps a re-run byte-identical.
patch_profile() {
    local snippet="$here/patches/bash_profile.snippet" tmp rest=""
    tmp=$(mktemp)
    if [[ -e $profile ]]; then
        rest=$(awk -v b="$pbegin" -v e="$pend" '
            $0 == b { skip = 1; next }
            $0 == e { skip = 0; next }
            skip { next }
            /\.config\/cmux\/(cw\.bash|teams-bin)/ { legacy++; next }
            /^# cw: one Claude/ || /^# Claude Code agent teams inside cmux/ { legacy++; next }
            { print }
            END { if (legacy) print "legacy-lines-removed " legacy > "/dev/stderr" }' "$profile" 2> "$tmp.legacy")
        if [[ -s $tmp.legacy ]]; then say "note       $profile: $(cat "$tmp.legacy" | tr '\n' ' ')(pre-existing unmanaged cw lines)"; fi
        rm -f "$tmp.legacy"
    fi
    {
        if [[ -n $rest ]]; then printf '%s\n\n' "$rest"; fi
        printf '%s\n' "$pbegin"; cat "$snippet"; printf '%s\n' "$pend"
    } > "$tmp"
    if [[ -e $profile ]] && cmp -s "$tmp" "$profile"; then
        say "unchanged  $profile"
        rm -f "$tmp"
        return 0
    fi
    changed=1
    if [[ -e $profile ]]; then
        plan "patch      $profile  (managed block, backup $profile.bak-$stamp)"
    else
        plan "create     $profile"
    fi
    if (( dry )); then rm -f "$tmp"; return 0; fi
    backup "$profile"
    cat "$tmp" > "$profile"
    rm -f "$tmp"
}
patch_profile

# ---- 5. select the sidebar ---------------------------------------------------------------
# The choice of sidebar lives in cmux's Settings store, not in cmux.json, so it takes a call to
# a running cmux: from a cmux terminal as it is, from any other terminal with the socket
# password. When cmux does not answer, a marker is left and the first cw selects the sidebar.
sidebar_pending="$dest/sidebar-select.pending"
select_sidebar() {
    local -x CMUX_QUIET=1
    if [[ -z ${CMUX_WORKSPACE_ID:-} && -s $password_file ]]; then
        local -x CMUX_SOCKET_PASSWORD
        CMUX_SOCKET_PASSWORD=$(<"$password_file")
    fi
    if ! command -v cmux >/dev/null 2>&1 || ! cmux ping >/dev/null 2>&1; then
        plan "sidebar    cmux does not answer; the first cw will select the workspaces sidebar"
        (( dry )) || : > "$sidebar_pending"
        return 0
    fi
    if (( dry )); then
        say "would: cmux sidebar select workspaces"
    elif cmux sidebar select workspaces >/dev/null 2>&1; then
        say "sidebar    workspaces selected"
        rm -f "$sidebar_pending"
    else
        say "sidebar    could not select; run:  cmux sidebar select workspaces"
    fi
}
select_sidebar

# ---- done ----------------------------------------------------------------------------------
say ""
if (( dry )); then
    say "dry run: nothing changed."
elif (( changed )); then
    say "installed. Now, in every open terminal:  source ~/.bash_profile"
    say "cw is a shell function: a terminal opened before this run still has the old one until it re-sources."
    say "cmux re-reads cmux.json on relaunch or with reloadConfiguration (cmd+shift+,)."
else
    say "already up to date."
fi
