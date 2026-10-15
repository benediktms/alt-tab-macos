import Cocoa

/// Browser tabs surfaced as switcher entries while searching, read over AppleScript. Every Apple Event runs in an
/// `osascript` child on `queue`, never on the main thread: a browser that is slow, or waiting on the Automation
/// prompt, would otherwise freeze the switcher (see "Main-thread IPC" in AGENTS.md).
///
/// Inactive tabs cannot be captured without raising them, so their preview is the last capture taken while they
/// were the active tab of their window (`previews`).
enum BrowserTabs {
    typealias Browser = BrowserTabsTestable.Browser
    typealias Tab = BrowserTabsTestable.Tab
    typealias Key = BrowserTabsTestable.Key
    typealias Stamp = BrowserTabsTestable.Stamp

    private static let queue = DispatchQueue(label: "browser-tabs", qos: .userInitiated, attributes: .concurrent)
    // all of the following: main-thread only
    private static var inFlight = Set<Browser>()
    /// browsers whose Automation access has answered once; title events only read those, so browsing never
    /// raises the permission prompt that a search would
    private static var answered = Set<Browser>()
    private static var latest = [Browser: (pid: pid_t, tabs: [Tab])]()
    private static var bindings = [CGWindowID: Stamp]()
    /// native window → the tab key it was last paired with, kept across a title change so closing the window
    /// can still drop that tab's preview
    private static var windowKeys = [CGWindowID: Key]()
    private static var pending = [CGWindowID: BrowserTabsTestable.PendingCapture]()
    private static var previews = BrowserTabsTestable.PreviewCache()
    private static var debouncedReads = [Browser: DispatchWorkItem]()
    /// bumped by a title change, window close or quit: a read that started before it may describe a page that
    /// is gone, and is discarded
    private static var revisions = [Browser: Int]()
    private static var readsStarted = [Browser: Int]()
    /// lets the page paint after the title changed before its window is captured
    private static let titleReadDelay = 0.5

    static func refresh() {
        read(Browser.allCases, showTabs: true)
    }

    /// Drops the pairing and any pending capture at once, so nothing captured before the change is filed under the new page.
    static func activeTabMayHaveChanged(_ window: Window) {
        guard let browser = browser(of: window), let wid = window.cgWindowId else { return }
        bindings[wid] = nil
        pending[wid] = nil
        revisions[browser, default: 0] += 1
        guard answered.contains(browser), ScreenRecordingPermission.status == .granted,
              Preferences.anyShortcutShowsWindowCaptures else { return }
        scheduleRead(browser)
    }

    static func windowClosed(_ window: Window) {
        guard let wid = window.cgWindowId else { return }
        bindings[wid] = nil
        pending[wid] = nil
        if let key = windowKeys.removeValue(forKey: wid) { previews.removeWindow(pid: key.pid, windowId: key.windowId) }
        guard let browser = browser(of: window) else { return }
        revisions[browser, default: 0] += 1
        if answered.contains(browser) { scheduleRead(browser) }
    }

    static func applicationsQuit(_ apps: [NSRunningApplication]) {
        for app in apps {
            forget(pid: app.processIdentifier)
            previews.retain(pid: app.processIdentifier, live: [])
            guard let browser = Browser.allCases.first(where: { $0.bundleId == app.bundleIdentifier }) else { continue }
            revisions[browser, default: 0] += 1
            latest[browser] = nil
        }
    }

    private static func forget(pid: pid_t) {
        bindings = bindings.filter { $0.value.key.pid != pid }
        pending = pending.filter { $0.value.stamp.key.pid != pid }
        windowKeys = windowKeys.filter { $0.value.pid != pid }
    }

    static func stamp(_ window: Window) -> Stamp? {
        guard let wid = window.cgWindowId else { return nil }
        let frame = window.position.flatMap { position in window.size.map { BrowserTabsTestable.Frame(position: position, size: $0) } }
        return BrowserTabsTestable.liveStamp(bindings[wid], title: window.title, frame: frame)
    }

    /// The pixels wait for a read that started after the capture to agree with the stamp: the title alone can't tell two pages apart.
    static func captured(_ window: Window, _ contents: CALayerContents, _ requested: Stamp?) {
        guard let requested, requested == stamp(window), let size = window.size, let wid = window.cgWindowId,
              let browser = browser(of: window) else { return }
        pending[wid] = .init(stamp: requested, preview: .init(contents: contents, size: size),
            revision: revisions[browser] ?? 0, afterRead: readsStarted[browser] ?? 0)
        scheduleRead(browser)
    }

    static func preview(_ pid: pid_t, _ tab: Tab) -> BrowserTabsTestable.Preview? {
        previews.preview(for: Key(pid: pid, windowId: tab.windowId, url: tab.url))
    }

    private static func browser(of window: Window) -> Browser? {
        let bundleId = window.application.bundleIdentifier
        return Browser.allCases.first { $0.bundleId == bundleId }
    }

    private static func scheduleRead(_ browser: Browser) {
        debouncedReads[browser]?.cancel()
        let work = DispatchWorkItem {
            debouncedReads[browser] = nil
            read([browser], showTabs: false)
        }
        debouncedReads[browser] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + titleReadDelay, execute: work)
    }

    private static func showLatest() {
        let tabs = latest.flatMap { browser, entry -> [BrowserTabWindow] in
            guard let app = Applications.list.first(where: { $0.pid == entry.pid }) else { return [] }
            // active tabs are skipped: their window's own tile already shows them
            return entry.tabs.filter { !$0.isActive }.map { BrowserTabWindow(app, browser, $0) }
        }
        Windows.replaceTabs(BrowserTabWindow.self, with: tabs)
    }

    private static func read(_ browsers: [Browser], showTabs: Bool) {
        var running = [(Browser, pid_t)]()
        for browser in browsers {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: browser.bundleId).first(where: { !$0.isTerminated }) {
                running.append((browser, app.processIdentifier))
            } else if let gone = latest.removeValue(forKey: browser) {
                forget(pid: gone.pid)
                previews.retain(pid: gone.pid, live: [])
            }
        }
        var idle = [(browser: Browser, pid: pid_t, revision: Int, number: Int)]()
        for (browser, pid) in running {
            if inFlight.insert(browser).inserted {
                readsStarted[browser, default: 0] += 1
                idle.append((browser, pid, revisions[browser] ?? 0, readsStarted[browser]!))
            } else if !showTabs { scheduleRead(browser) }
        }
        guard !idle.isEmpty else {
            if showTabs { showLatest() }
            return
        }
        queue.async {
            var results = [[Tab]?](repeating: nil, count: idle.count)
            // each iteration owns exactly one slot, so the buffer is written without a lock
            results.withUnsafeMutableBufferPointer { slots in
                DispatchQueue.concurrentPerform(iterations: idle.count) { slot in
                    slots[slot] = runOsascript(BrowserTabsTestable.listScript(idle[slot].browser)).map(BrowserTabsTestable.parse)
                }
            }
            DispatchQueue.main.async {
                var changed = [(pid_t, CGWindowID)]()
                for (slot, started) in idle.enumerated() {
                    let browser = started.browser
                    inFlight.remove(browser)
                    guard (revisions[browser] ?? 0) == started.revision else { scheduleRead(browser); continue }
                    guard let tabs = results[slot] else {
                        latest[browser] = nil // denied or timed out
                        forget(pid: started.pid)
                        continue
                    }
                    answered.insert(browser)
                    changed += rebind(browser, started.pid, tabs, read: started.number, revision: started.revision).map { (started.pid, $0) }
                }
                if showTabs || SwitcherSession.isActive { showLatest() }
                captureNewlyPairedWindows(changed)
            }
        }
    }

    private static func rebind(_ browser: Browser, _ pid: pid_t, _ tabs: [Tab], read: Int, revision: Int) -> [CGWindowID] {
        latest[browser] = (pid, tabs)
        previews.retain(pid: pid, live: Set(tabs.map { Key(pid: pid, windowId: $0.windowId, url: $0.url) }))
        let natives = Windows.list.compactMap { window -> BrowserTabsTestable.NativeWindow? in
            guard !(window is BrowserTabWindow), window.application.pid == pid, let wid = window.cgWindowId else { return nil }
            let frame = window.position.flatMap { position in window.size.map { BrowserTabsTestable.Frame(position: position, size: $0) } }
            return .init(wid: wid, frame: frame, title: window.title)
        }
        let paired = BrowserTabsTestable.pair(tabs, natives)
        var changed = [CGWindowID]()
        for native in natives {
            let fresh = paired.first(where: { $0.value == native.wid }).flatMap { entry -> Stamp? in
                guard let tab = tabs.first(where: { $0.windowId == entry.key && $0.isActive }), let frame = native.frame else { return nil }
                return Stamp(key: Key(pid: pid, windowId: entry.key, url: tab.url), nativeTitle: native.title, frame: frame)
            }
            if bindings[native.wid] != fresh { changed.append(native.wid) }
            bindings[native.wid] = fresh
            if let key = fresh?.key { windowKeys[native.wid] = key }
            guard let waiting = pending[native.wid] else { continue }
            switch BrowserTabsTestable.verdict(waiting, fresh: fresh, read: read, revision: revision) {
                case .wait: break
                case .commit:
                    previews.store(waiting.preview, for: waiting.stamp.key)
                    pending[native.wid] = nil
                case .drop: pending[native.wid] = nil
            }
        }
        return changed
    }

    /// While the switcher is open its show-time capture ran before the page was known, so refresh; otherwise only the
    /// frontmost browser is captured.
    private static func captureNewlyPairedWindows(_ changed: [(pid_t, CGWindowID)]) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        for (pid, wid) in changed where bindings[wid] != nil {
            guard let window = Windows.byWindowId[wid] else { continue }
            if SwitcherSession.isActive {
                WindowThumbnails.refreshAsync([window], .refreshUiAfterExternalEvent)
            } else if pid == front {
                WindowThumbnails.captureFocusedInBackground(window)
            }
        }
    }

    /// The browser itself selects the tab and raises the window, and macOS switches to its Space. If it refuses (tab or
    /// window gone), activate the app so the keypress still lands. `onFronted` runs on main once the browser has replied
    /// (or refused and been activated), whichever way it went: the panel must not stay held until its limit.
    static func focus(_ tab: BrowserTabWindow, _ onFronted: @escaping () -> Void) {
        let script = BrowserTabsTestable.focusScript(tab.browser, windowId: tab.scriptWindowId)
        let arguments = [tab.url, String(tab.tabIndex)]
        let app = tab.application.runningApplication
        FocusIntents.shared.supersede()
        queue.async {
            if runOsascript(script, arguments) == nil { app.activate(options: .activateAllWindows) }
            DispatchQueue.main.async(execute: onFronted)
        }
    }

    /// `osascript` rather than `NSAppleScript`, which isn't safe off the main thread. TCC attributes the
    /// Automation permission to AltTab, as the responsible process.
    private static func runOsascript(_ script: String, _ arguments: [String] = []) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeout)
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        timeout.cancel()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines)
    }
}

final class BrowserTabWindow: VirtualTabWindow {
    let browser: BrowserTabs.Browser
    let scriptWindowId: Int
    let tabIndex: Int
    let url: String

    init(_ application: Application, _ browser: BrowserTabs.Browser, _ tab: BrowserTabs.Tab) {
        self.browser = browser
        scriptWindowId = tab.windowId
        tabIndex = tab.index
        url = tab.url
        // The URL is in the id because the index alone is reused by whatever tab slides into it after a
        // refresh, and the selection follows `id`.
        super.init(tabOf: application, id: "tab-\(browser.bundleId)-\(tab.windowId)-\(tab.index)-\(tab.url)",
            title: tab.title.isEmpty ? tab.url : tab.title)
        if let preview = BrowserTabs.preview(application.pid, tab) {
            thumbnail = preview.contents
            self.size = preview.size
        }
    }

    override var searchableSecondary: String { BrowserTabsTestable.searchableUrl(url) }

    override func focus(_ onFronted: @escaping () -> Void = {}) {
        BrowserTabs.focus(self, onFronted)
    }
}
