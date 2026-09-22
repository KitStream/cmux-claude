// Workspace sidebar for cmux: compact cards with a rule between them, pinned cards on top.
//
// Each card: title, and a second line with the last two path segments of the working
// directory. The git branch is appended to that line ONLY for ordinary shells. A workspace
// `cw` created carries the description "claude" and shows no branch: cmux derives it from
// the shell's directory, and a `cw` shell sits at the repo root while claude works in a
// worktree.
//
// Agent state colours the whole card: blue wash while the agent is busy, orange wash and
// orange title when it wants attention (an unread notification: a question, or a finished
// turn), no wash when idle. The selected card gets an orange frame, no wash and no bold, so
// it never hides the state colour. A small dot at the left repeats the colour. The state comes from claude's terminal title, see statusOf.
// A red badge shows unread notifications. Click selects; right-click pins or closes; drag
// reorders. Pinned workspaces stay in a block at the top, above the ones cmux reorders when
// they notify (app.reorderOnNotification), so a pinned launcher never moves.
//
// Interpreter notes (cmux 0.64): optional fields must be read with `if let`, a `!= nil`
// test in a `let` line does not evaluate; `.padding(n)` only, the edge form falls back to
// default padding on all sides; fixed-width Spacers give horizontal inset.
//
// Select it: right-click the sidebar toggle button and pick "workspaces", or
//   cmux sidebar select workspaces
// Back to the built-in sidebar from the same menu. Edits hot-reload.

func sub(_ text: String) -> some View {
    return Text(text)
        .font(.system(size: 10))
        .lineLimit(1)
        .truncationMode(.middle)
        .foregroundColor(.secondary)
}

// Agent state, read from the terminal title. cmux 0.64 does not expose `agents` to custom
// sidebars (it arrives as nil), but claude writes its state into the title: a spinner glyph
// (◐ ◓ ◑ ◒) while it works, ✳ while it waits at the prompt. An unread notification means
// claude asked for something or finished a turn, so it wins as "needs_input".
// Returns "working", "needs_input", "idle" or "" when no tab looks like a claude session.
// `contains` rather than `hasPrefix`, and `filter` rather than a loop with early returns:
// the first version, built on the latter two, evaluated to "" in this interpreter.
func isWorking(_ title: String) -> Bool {
    return title.contains("◐") || title.contains("◓") || title.contains("◑") || title.contains("◒")
}

func isIdle(_ title: String) -> Bool {
    return title.contains("✳")
}

// Sources, most trustworthy first. The title spinner says "working" and is live even for
// sessions without hooks, so it is the authority for that. The description, stamped by
// ~/.config/cmux/cw-state-hook.sh from Claude Code hooks, is only consulted for
// "claude:question" (a question or permission is open) because nothing else can tell a
// question from a finished turn; a stale stamp therefore cannot keep a card blue. An unread
// badge on anything else means the turn finished and has not been looked at: "done".
// Only the LEAD pane counts: a cw session is named after its workspace, so its tab title
// contains the workspace title ("✳ control-plan-loop"), while teammate panes are titled by
// role ("◑ tester"). Teammate titles go stale (a spinner stays after the teammate is back at
// its prompt), which kept cards blue for ever (2026-09-14). Workspaces without such a tab
// (Root Workspace, plain shells) fall back to all tabs.
func statusOf(_ w: Any) -> String {
    let lead = w.tabs.filter { $0.title.contains(w.title) }
    if lead.count > 0 && lead.filter { isWorking($0.title) }.count > 0 { return "working" }
    if lead.count == 0 && w.tabs.filter { isWorking($0.title) }.count > 0 { return "working" }
    if let d = w.description {
        if d.contains(":question") { return "needs_input" }
        // Stamped by UserPromptSubmit and cleared by Stop/SessionEnd; covers sessions whose
        // title never shows a spinner (started without cmux's wrapper).
        if d.contains(":working") { return "working" }
    }
    if w.unread > 0 { return "done" }
    if lead.count > 0 && lead.filter { isIdle($0.title) }.count > 0 { return "idle" }
    if lead.count == 0 && w.tabs.filter { isIdle($0.title) }.count > 0 { return "idle" }
    return ""
}

// needs_input = orange (a question waits), done = yellow (finished, not looked at yet),
// working = blue, idle = green dot only.
func dotColor(_ status: String) -> String {
    if status == "needs_input" { return "#F2A33C" }
    if status == "done" { return "#E6C84A" }
    if status == "working" { return "#4C9EEB" }
    if status == "idle" { return "#3CB371" }
    return "#00000000"
}

func cardColor(_ status: String) -> String {
    if status == "needs_input" { return "#F2A33C40" }
    if status == "done" { return "#E6C84A2E" }
    if status == "working" { return "#4C9EEB33" }
    return "#00000000"
}

func card(_ w: Any) -> some View {
    let parts = w.directory.split(separator: "/")
    let dir = parts.count >= 2 ? "\(parts[parts.count - 2])/\(parts[parts.count - 1])" : w.directory
    let status = statusOf(w)
    return VStack(alignment: .leading, spacing: 0) {
        HStack(alignment: .center, spacing: 6) {
            Spacer().frame(width: 12)
            Circle().fill(dotColor(status)).frame(width: 6, height: 6)
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .center, spacing: 4) {
                    Text(w.title)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundColor(status == "needs_input" ? "#F2A33C" : (w.selected ? .primary : .secondary))
                    if w.pinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundColor(.secondary)
                    }
                }
                if let d = w.description {
                    if d.contains("claude") {
                        sub(dir)
                    } else {
                        if let b = w.branch {
                            sub("\(dir) · \(b)\(w.dirty ? "*" : "")")
                        } else {
                            sub(dir)
                        }
                    }
                } else {
                    if let b = w.branch {
                        sub("\(dir) · \(b)\(w.dirty ? "*" : "")")
                    } else {
                        sub(dir)
                    }
                }
            }
            Spacer()
            if w.unread > 0 {
                Text("\(w.unread)")
                    .font(.caption2)
                    .bold()
                    .foregroundColor(.white)
                    .padding(3)
                    .background("#E4573D")
                    .cornerRadius(8)
            }
            Spacer().frame(width: 12)
        }
        .padding(4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardColor(status))
        .border(w.selected ? "#F2A33C" : "#00000000", width: 2)
        .onTapGesture { cmux("workspace.select", workspace_id: w.id) }
        .contextMenu {
            Button(w.pinned ? "Unpin" : "Pin") {
                cmux("workspace.action", action: w.pinned ? "unpin" : "pin", workspace_id: w.id)
            }
            Button("Close") { cmux("workspace.close", workspace_id: w.id) }
        }
        Rectangle()
            .fill("#7f7f7f66")
            .frame(height: 1)
    }
}

VStack(alignment: .leading, spacing: 0) {
    // Pinned block first, in cmux's order; it does not take part in drag-reorder.
    ForEach(workspaces.filter { $0.pinned }) { w in
        card(w)
    }
    Reorderable(workspaces.filter { !$0.pinned }, move: "workspace.reorder") { w in
        card(w)
    }
}
