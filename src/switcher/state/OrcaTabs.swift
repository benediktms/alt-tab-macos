import Cocoa

/// Orca (the agent IDE, `com.stablyai.orca`) terminal tabs surfaced as switcher entries while searching. Orca has
/// one OS window holding every worktree's tabs, so they are read from its local runtime: one JSON line over the unix
/// socket named in `orca-runtime.json`, one reply per connection, no push. Every socket call runs on `queue`, never
/// on the main thread: an Orca that is hung or asleep would otherwise freeze the switcher (see "Main-thread IPC" in
/// AGENTS.md).
enum OrcaTabs {
    typealias Tab = OrcaTabsTestable.Tab
    typealias Key = OrcaTabsTestable.Key
    typealias Selection = OrcaTabsTestable.Selection
    typealias Stamp = OrcaTabsTestable.Stamp

    private static let queue = DispatchQueue(label: "orca-tabs", qos: .userInitiated, attributes: .concurrent)
    // all of the following: main-thread only
    private static var inFlight = false
    /// something asked for a read while one was running: its answer may predate the ask
    private static var again = false
    private static let requestTimeout: TimeInterval = 5
    /// The last accepted capture of each terminal tab while it was the one Orca showed: inactive tabs cannot be captured.
    private static var previews = BrowserTabsTestable.BoundedPreviews<Key>(capacity: 32)
    private static var pending: OrcaTabsTestable.PendingCapture?
    /// what the capture being requested right now shows; set only around the synchronous `refreshAsync` call that
    /// snapshots it, so no other capture can ever pick it up
    private static var binding: Stamp?
    private static var selecting = false
    private static var selectionReads = 0
    /// bumped when Orca quits: answers that were asked for before it are discarded
    private static var generation = 0

    static func refresh() {
        guard let pid = NSRunningApplication.runningApplications(withBundleIdentifier: OrcaTabsTestable.bundleId)
            .first(where: { !$0.isTerminated })?.processIdentifier else { return forget() }
        guard !inFlight else { again = true; return }
        inFlight = true
        queue.async {
            let read = readTabs()
            DispatchQueue.main.async {
                inFlight = false
                show(read, pid)
                if again { again = false; refresh() }
            }
        }
    }

    static func applicationsQuit(_ apps: [NSRunningApplication]) {
        if apps.contains(where: { $0.bundleIdentifier == OrcaTabsTestable.bundleId }) { forget() }
    }

    private static func forget() {
        generation += 1
        pending = nil
        previews = .init(capacity: previews.capacity)
        Windows.replaceTabs(OrcaTabWindow.self, with: [])
    }

    /// An unreadable runtime lists nothing but keeps the previews: Orca may only be busy.
    private static func show(_ read: (tabs: [Tab], runtimeId: String, selection: Selection?)?, _ pid: pid_t) {
        guard let read else { return Windows.replaceTabs(OrcaTabWindow.self, with: []) }
        let live = OrcaTabsTestable.liveKeys(pid: pid, runtimeId: read.runtimeId, tabs: read.tabs, selection: read.selection)
        previews.remove { !live.contains($0) }
        guard let app = Applications.list.first(where: { $0.pid == pid }) else { return Windows.replaceTabs(OrcaTabWindow.self, with: []) }
        Windows.replaceTabs(OrcaTabWindow.self, with: read.tabs.map { tab in
            OrcaTabWindow(app, tab, preview: previews.preview(for: tab.key(pid: pid, runtimeId: read.runtimeId)))
        })
    }

    // MARK: previews

    static func windowFocused(_ window: Window) {
        guard window.application.bundleIdentifier == OrcaTabsTestable.bundleId else { return }
        WindowThumbnails.focusedCaptureThrottler.throttleOrProceed(key: "orca-selection") { captureSelected() }
    }

    /// The window pixels cannot name their tab, so the runtime does, twice: a selection read stamps the capture, and a
    /// second read that started after the capture arrived must name the same tab (`OrcaTabsTestable.verdict`) or
    /// nothing is filed.
    static func captureSelected() {
        guard !selecting, ScreenRecordingPermission.status == .granted, Preferences.anyShortcutShowsWindowCaptures,
              capturableWindow() != nil else { return }
        selecting = true
        let started = generation
        queue.async {
            let selection = readSelection()
            DispatchQueue.main.async {
                selecting = false
                guard generation == started, let selection, let window = capturableWindow(), let wid = window.cgWindowId,
                      let frame = windowFrame(window) else { return }
                binding = Stamp(pid: window.application.pid, wid: wid, selection: selection, title: window.title, frame: frame)
                defer { binding = nil }
                WindowThumbnails.refreshAsync([window], .refreshUiAfterExternalEvent, force: true)
            }
        }
    }

    static func stamp(_ window: Window) -> Stamp? {
        guard let binding, binding.wid == window.cgWindowId else { return nil }
        return binding
    }

    static func captured(_ window: Window, _ contents: CALayerContents, _ requested: Stamp) {
        guard let wid = window.cgWindowId, let size = window.size,
              OrcaTabsTestable.stillShows(requested, pid: window.application.pid, wid: wid, title: window.title, frame: windowFrame(window)),
              capturableWindow() === window else { return }
        pending = .init(stamp: requested, preview: .init(contents: contents, size: size), afterRead: selectionReads)
        verify()
    }

    private static func verify() {
        selectionReads += 1
        let read = selectionReads
        let started = generation
        queue.async {
            let selection = readSelection()
            DispatchQueue.main.async {
                guard generation == started, let waiting = pending else { return }
                switch OrcaTabsTestable.verdict(waiting, read: read, selection: selection) {
                    case .wait: break
                    case .commit:
                        previews.store(waiting.preview, for: waiting.stamp.key)
                        pending = nil
                    case .drop: pending = nil
                }
            }
        }
    }

    /// Orca's main window, only while a capture can show the selected tab: Orca is frontmost (a covered or backgrounded
    /// Chromium window may not have painted a tab switched to over the runtime) and the window is on screen on the
    /// current Space.
    private static func capturableWindow() -> Window? {
        let candidates = Windows.list.filter { window in
            !(window is VirtualTabWindow) && window.application.bundleIdentifier == OrcaTabsTestable.bundleId && window.cgWindowId != nil
        }
        guard let pid = candidates.first?.application.pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        let natives = candidates.filter { $0.application.pid == pid }.compactMap { window in
            window.cgWindowId.map { BrowserTabsTestable.NativeWindow(wid: $0, frame: windowFrame(window), title: window.title) }
        }
        guard let wid = OrcaTabsTestable.mainWindow(natives), let window = Windows.byWindowId[wid],
              !window.isMinimized, window.spaceIds.contains(Spaces.currentSpaceId) else { return nil }
        return window
    }

    private static func windowFrame(_ window: Window) -> BrowserTabsTestable.Frame? {
        window.position.flatMap { position in window.size.map { BrowserTabsTestable.Frame(position: position, size: $0) } }
    }

    /// Orca's runtime switches worktree, tab and pane but does not raise the app, so the Orca window is focused here.
    /// The reply can take seconds: if any other focus was requested meanwhile (`isNewest`), the raise is skipped.
    /// `onFronted` always runs on main: by the native focus once it has fronted Orca, otherwise right away because
    /// nothing more will be fronted (failed, superseded, or no window to focus).
    static func focus(_ tab: OrcaTabWindow, _ onFronted: @escaping () -> Void) {
        let token = FocusIntents.shared.supersede()
        let handle = tab.handle
        let application = tab.application
        queue.async {
            let switched = runtime().flatMap { call($0, "terminal.focus", ["terminal": handle, "navigation": "host"]) }
                .map(OrcaTabsTestable.didNavigate) ?? false
            DispatchQueue.main.async {
                guard switched else {
                    if FocusIntents.shared.isNewest(token) { NSSound.beep() }
                    refresh()
                    return onFronted()
                }
                guard FocusIntents.shared.isNewest(token) else { return onFronted() }
                let window = Windows.list.filter { !($0 is VirtualTabWindow) && $0.application.pid == application.pid && $0.cgWindowId != nil }
                    .min { $0.lastFocusOrder < $1.lastFocusOrder }
                if let window {
                    window.focus(onFronted)
                } else {
                    application.runningApplication.activate(options: .activateAllWindows)
                    onFronted()
                }
            }
        }
    }

    /// nil when any step fails: a partial answer could hide the wrong tab as selected or name the wrong worktree
    private static func readTabs() -> (tabs: [Tab], runtimeId: String, selection: Selection?)? {
        guard let runtime = runtime(),
              let ps = call(runtime, "worktree.ps", ["limit": 1000]),
              let list = call(runtime, "terminal.list", ["includeVisualLayouts": true, "limit": 1000]) else { return nil }
        let worktrees = OrcaTabsTestable.worktrees(ps)
        var session: Any?
        if let active = worktrees.first(where: { $0.isActive }) {
            guard let reply = call(runtime, "session.tabs.list", ["worktree": "id:\(active.id)"]) else { return nil }
            session = reply
        }
        let tabs = OrcaTabsTestable.tabs(worktrees: worktrees, list: list, selectedTabId: session.flatMap(OrcaTabsTestable.selectedTabId))
        // only prunes previews (a stale answer keeps one entry too many), so the worktrees and view are not read again
        let selection = session.flatMap { OrcaTabsTestable.shownTab(runtimeId: runtime.id, before: worktrees, session: $0, after: worktrees) }
        return (tabs, runtime.id, selection)
    }

    /// The tab Orca shows, for filing a capture: the active worktree is read on both sides of its tab session and must
    /// not have changed, and `ui.get` (read in between) must say the terminal view is the page shown.
    private static func readSelection() -> Selection? {
        guard let runtime = runtime(), let before = call(runtime, "worktree.ps", ["limit": 1000]),
              let active = OrcaTabsTestable.worktrees(before).first(where: { $0.isActive }),
              let session = call(runtime, "session.tabs.list", ["worktree": "id:\(active.id)"]),
              let ui = call(runtime, "ui.get", [:]),
              let after = call(runtime, "worktree.ps", ["limit": 1000]) else { return nil }
        return OrcaTabsTestable.selection(runtimeId: runtime.id, before: OrcaTabsTestable.worktrees(before), session: session, ui: ui,
            after: OrcaTabsTestable.worktrees(after))
    }

    private static func runtime() -> OrcaTabsTestable.Runtime? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
              let data = try? Data(contentsOf: support.appendingPathComponent("orca/orca-runtime.json")) else { return nil }
        return OrcaTabsTestable.runtime(from: data)
    }

    private static func call(_ runtime: OrcaTabsTestable.Runtime, _ method: String, _ params: [String: Any]) -> Any? {
        let requestId = UUID().uuidString
        guard var request = try? JSONSerialization.data(withJSONObject:
            ["id": requestId, "authToken": runtime.token, "method": method, "params": params]) else { return nil }
        request.append(10)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(runtime.socketPath.utf8CString)
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { return nil }
        path.withUnsafeBytes { source in withUnsafeMutableBytes(of: &address.sun_path) { $0.copyMemory(from: source) } }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { return nil }
        var sent = 0
        while sent < request.count {
            let written = request.withUnsafeBytes { send(fd, $0.baseAddress! + sent, request.count - sent, 0) }
            guard written > 0 else { return nil }
            sent += written
        }
        // the server may interleave keepalive frames before the one reply, and does not necessarily close after it
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 65536)
        let deadline = Date().addingTimeInterval(requestTimeout)
        while Date() < deadline && buffer.count < 16_000_000 {
            while let newline = buffer.firstIndex(of: 10) {
                let line = buffer[buffer.startIndex..<newline]
                buffer = Data(buffer[(newline + 1)...])
                if line.allSatisfy({ $0 == 32 || $0 == 13 }) { continue }
                switch OrcaTabsTestable.frame(Data(line), requestId: requestId, runtimeId: runtime.id) {
                    case .keepalive: continue
                    case .reply(let result): return result
                    case .failed: return nil
                }
            }
            let received = recv(fd, &chunk, chunk.count, 0)
            guard received > 0 else { return nil }
            buffer.append(chunk, count: received)
        }
        return nil
    }
}

final class OrcaTabWindow: VirtualTabWindow {
    let handle: String
    private let context: String

    init(_ application: Application, _ tab: OrcaTabs.Tab, preview: BrowserTabsTestable.Preview?) {
        handle = tab.handle
        context = tab.context
        super.init(tabOf: application, id: "orca-tab-\(tab.id)", title: tab.title)
        if let preview {
            thumbnail = preview.contents
            self.size = preview.size
        }
    }

    override var searchableSecondary: String { context }

    override func focus(_ onFronted: @escaping () -> Void = {}) {
        OrcaTabs.focus(self, onFronted)
    }
}
