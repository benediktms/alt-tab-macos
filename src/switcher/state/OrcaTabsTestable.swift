import Foundation
import CoreGraphics

/// The pure half of Orca terminal-tab search: what Orca's local runtime answers (`worktree.ps`, `terminal.list`
/// with visual layouts, `session.tabs.list`) turned into one entry per terminal tab. No socket or AppKit access,
/// so `OrcaTabsTests` pins it.
enum OrcaTabsTestable {
    static let bundleId = "com.stablyai.orca"

    struct Runtime: Equatable {
        let id: String
        let socketPath: String
        let token: String
    }

    static func runtime(from data: Data) -> Runtime? {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = json["runtimeId"] as? String, let token = json["authToken"] as? String, !token.isEmpty,
              let transports = json["transports"] as? [[String: Any]],
              let path = transports.first(where: { $0["kind"] as? String == "unix" })?["endpoint"] as? String
        else { return nil }
        return Runtime(id: id, socketPath: path, token: token)
    }

    enum Frame {
        case keepalive
        case reply(Any)
        /// an error reply, a reply to another request or from another runtime, or not a frame at all
        case failed
    }

    static func frame(_ line: Data, requestId: String, runtimeId: String) -> Frame {
        guard let json = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else { return .failed }
        if json["_keepalive"] != nil { return .keepalive }
        guard json["id"] as? String == requestId else { return .failed }
        // Orca restarted while the request was in flight: the answer is not from the runtime that was asked
        if let answered = (json["_meta"] as? [String: Any])?["runtimeId"] as? String, answered != runtimeId { return .failed }
        guard json["ok"] as? Bool == true, let result = json["result"] else { return .failed }
        return .reply(result)
    }

    /// A `terminal.focus` reply that did switch. Orca answers `{focus: {handle, tabId, navigated}}`; a runtime
    /// that did not navigate (no window, request superseded) says `navigated: false`, and a reply of any other
    /// shape proves nothing, so neither counts.
    static func didNavigate(_ result: Any) -> Bool {
        guard let focus = (result as? [String: Any])?["focus"] as? [String: Any] else { return false }
        return focus["navigated"] as? Bool != false
    }

    struct Worktree: Equatable {
        let id: String
        let name: String
        let repo: String
        let branch: String
        let isActive: Bool
    }

    static func worktrees(_ result: Any) -> [Worktree] {
        guard let rows = (result as? [String: Any])?["worktrees"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row -> Worktree? in
            guard let id = row["worktreeId"] as? String, row["isArchived"] as? Bool != true else { return nil }
            let branch = (row["branch"] as? String ?? "").replacingOccurrences(of: "refs/heads/", with: "")
            let folder = (row["path"] as? String).map { ($0 as NSString).lastPathComponent }
            return Worktree(id: id, name: text(row["displayName"]) ?? text(folder) ?? branch,
                repo: row["repo"] as? String ?? "", branch: branch, isActive: row["isActive"] as? Bool == true)
        }
    }

    /// The terminal tab Orca is showing, from a `session.tabs.list` of the active worktree. `activeTabId` names a
    /// pane (`<tab>::<leaf>`); nil when the shown tab is not a terminal (an editor, a browser).
    static func selectedTabId(_ result: Any) -> String? {
        guard let result = result as? [String: Any], result["activeTabType"] as? String == "terminal",
              let active = result["activeTabId"] as? String else { return nil }
        let entry = (result["tabs"] as? [[String: Any]])?.first { $0["id"] as? String == active }
        return entry?["parentTabId"] as? String
    }

    struct Tab: Equatable {
        let worktreeId: String
        let tabId: String
        /// "<worktree> · <tab title>": the worktree is what tells apart tabs of different branches
        let title: String
        let context: String
        /// the tab's active pane: focusing it selects the tab, its worktree and that pane
        let handle: String

        var id: String { "\(worktreeId)|\(tabId)" }

        func key(pid: pid_t, runtimeId: String) -> Key { Key(pid: pid, runtimeId: runtimeId, worktreeId: worktreeId, tabId: tabId) }
    }

    /// The tab Orca is showing (`selectedTabId`, meaningful only in the active worktree) is left out: Orca's own
    /// window tile stands for it.
    static func tabs(worktrees: [Worktree], list: Any, selectedTabId: String?) -> [Tab] {
        guard let layouts = (list as? [String: Any])?["visualLayouts"] as? [[String: Any]] else { return [] }
        let known = Dictionary(worktrees.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var result = [Tab]()
        for layout in layouts {
            guard let id = layout["worktreeId"] as? String, let worktree = known[id],
                  let root = layout["root"] as? [String: Any] else { continue }
            for group in groups(root) {
                for tab in group["tabs"] as? [[String: Any]] ?? [] {
                    guard let tabId = tab["tabId"] as? String, !(worktree.isActive && tabId == selectedTabId),
                          let leaf = activeLeaf(of: tab), let handle = leaf["handle"] as? String else { continue }
                    let title = text(tab["title"]) ?? text(leaf["title"]) ?? "Terminal"
                    result.append(Tab(worktreeId: id, tabId: tabId, title: "\(worktree.name) · \(title)",
                        context: [worktree.repo, worktree.branch].filter { !$0.isEmpty }.joined(separator: " "), handle: handle))
                }
            }
        }
        return result
    }

    private static func groups(_ node: [String: Any]) -> [[String: Any]] {
        if node["type"] as? String == "group" { return [node] }
        return [node["first"], node["second"]].compactMap { $0 as? [String: Any] }.flatMap(groups)
    }

    private static func leaves(_ node: [String: Any]) -> [[String: Any]] {
        if node["type"] as? String == "terminal" { return [node] }
        return [node["first"], node["second"]].compactMap { $0 as? [String: Any] }.flatMap(leaves)
    }

    private static func activeLeaf(of tab: [String: Any]) -> [String: Any]? {
        guard let panes = tab["panes"] as? [String: Any] else { return nil }
        let all = leaves(panes)
        let activeId = tab["activeLeafId"] as? String
        return all.first { activeId != nil && $0["leafId"] as? String == activeId }
            ?? all.first { $0["active"] as? Bool == true } ?? all.first
    }

    private static func text(_ value: Any?) -> String? {
        guard let string = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !string.isEmpty else { return nil }
        return string
    }

    // MARK: tab previews

    /// Orca's main window is titled "Orca" for good (tab, worktree and pane changes never rename it), while its
    /// popouts and the agent dashboard carry other titles. Nothing else tells them apart over AX, so the main window
    /// is the single native window of Orca with exactly this title, and none at all when there are two.
    static let mainWindowTitle = "Orca"

    static func mainWindow(_ natives: [BrowserTabsTestable.NativeWindow]) -> CGWindowID? {
        let candidates = natives.filter { $0.title == mainWindowTitle }
        return candidates.count == 1 ? candidates[0].wid : nil
    }

    /// The terminal tab Orca's window shows, as one read of its runtime reported it. `epoch` is the runtime's
    /// `publicationEpoch` of the tab session, so ids republished by a different renderer never match.
    struct Selection: Equatable {
        let runtimeId: String
        let worktreeId: String
        let tabId: String
        let epoch: String
    }

    /// The terminal tab of the active worktree, whether or not the terminal view is what Orca's window shows.
    /// `worktree.ps` is read before and after `session.tabs.list` of the worktree it named active: the answer
    /// is trusted only when Orca still showed that worktree afterwards, else the tab of one worktree could be
    /// paired with the window of another.
    static func shownTab(runtimeId: String, before: [Worktree], session: Any, after: [Worktree]) -> Selection? {
        guard let active = before.first(where: { $0.isActive }), after.first(where: { $0.isActive })?.id == active.id,
              let tabId = selectedTabId(session) else { return nil }
        let epoch = (session as? [String: Any])?["publicationEpoch"] as? String ?? ""
        return Selection(runtimeId: runtimeId, worktreeId: active.id, tabId: tabId, epoch: epoch)
    }

    /// Orca's `ui.get` reply: is the terminal view the page in the window? Settings, Tasks, Activity and the like
    /// replace the terminal view without touching the worktree or its selected tab, so the window pixels would show
    /// that page under an unchanged selection. Anything but an explicit "terminal" (malformed, missing) is no.
    static func isTerminalView(_ ui: Any) -> Bool {
        ((ui as? [String: Any])?["ui"] as? [String: Any])?["activeView"] as? String == "terminal"
    }

    /// What a capture may be filed under: `shownTab`, only when `ui` (read between the two `worktree.ps`) says the
    /// terminal view was showing.
    static func selection(runtimeId: String, before: [Worktree], session: Any, ui: Any, after: [Worktree]) -> Selection? {
        guard isTerminalView(ui) else { return nil }
        return shownTab(runtimeId: runtimeId, before: before, session: session, after: after)
    }

    /// What a cached image is filed under. The process is part of it so a relaunched Orca (new pid, and a new
    /// runtime id) never inherits the images of the previous one, and the worktree so equal tab ids of two
    /// worktrees stay apart.
    struct Key: Hashable {
        let pid: pid_t
        let runtimeId: String
        let worktreeId: String
        let tabId: String
    }

    struct Stamp: Equatable {
        let pid: pid_t
        let wid: CGWindowID
        let selection: Selection
        let title: String
        let frame: BrowserTabsTestable.Frame

        var key: Key { Key(pid: pid, runtimeId: selection.runtimeId, worktreeId: selection.worktreeId, tabId: selection.tabId) }
    }

    static func stillShows(_ stamp: Stamp, pid: pid_t, wid: CGWindowID, title: String, frame: BrowserTabsTestable.Frame?) -> Bool {
        guard let frame else { return false }
        return stamp.pid == pid && stamp.wid == wid && stamp.title == title && stamp.frame.matches(frame)
    }

    struct PendingCapture {
        let stamp: Stamp
        let preview: BrowserTabsTestable.Preview
        /// number of selection reads already started when captured; only a later one can vouch for it
        let afterRead: Int
    }

    enum Verdict { case wait, commit, drop }

    /// `selection` is what read number `read` found. A read that cannot tell (nil) vouches for nothing, and one that
    /// started before the capture says nothing about it and waits.
    static func verdict(_ pending: PendingCapture, read: Int, selection: Selection?) -> Verdict {
        guard read > pending.afterRead else { return .wait }
        return selection == pending.stamp.selection ? .commit : .drop
    }

    /// The cache entries a full read keeps: every listed tab, and the shown one, which is not listed but is the
    /// next entry once the user moves on.
    static func liveKeys(pid: pid_t, runtimeId: String, tabs: [Tab], selection: Selection?) -> Set<Key> {
        var keys = Set(tabs.map { $0.key(pid: pid, runtimeId: runtimeId) })
        if let selection { keys.insert(Key(pid: pid, runtimeId: selection.runtimeId, worktreeId: selection.worktreeId, tabId: selection.tabId)) }
        return keys
    }
}
