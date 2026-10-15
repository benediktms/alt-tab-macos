import XCTest

final class OrcaTabsTests: XCTestCase {
    private typealias Orca = OrcaTabsTestable

    // MARK: runtime metadata and wire frames

    private func metadata(_ transports: [[String: Any]], token: Any = "secret") -> Data {
        try! JSONSerialization.data(withJSONObject: ["runtimeId": "run-1", "authToken": token, "transports": transports])
    }

    func testRuntimeUsesTheUnixTransportNotTheWebsocketOne() {
        let data = metadata([["kind": "websocket", "endpoint": "ws://0.0.0.0:6768"], ["kind": "unix", "endpoint": "/tmp/o.sock"]])
        XCTAssertEqual(Orca.runtime(from: data), .init(id: "run-1", socketPath: "/tmp/o.sock", token: "secret"))
    }

    func testRuntimeIsNilWithoutUnixTransportOrToken() {
        XCTAssertNil(Orca.runtime(from: metadata([["kind": "websocket", "endpoint": "ws://x"]])))
        XCTAssertNil(Orca.runtime(from: metadata([["kind": "unix", "endpoint": "/tmp/o.sock"]], token: "")))
        XCTAssertNil(Orca.runtime(from: Data("not json".utf8)))
    }

    private func frame(_ json: [String: Any], id: String = "req-1") -> Orca.Frame {
        Orca.frame(try! JSONSerialization.data(withJSONObject: json), requestId: id, runtimeId: "run-1")
    }

    func testFrameSkipsKeepalivesAndReturnsTheResultOfOurRequest() {
        guard case .keepalive = frame(["_keepalive": true]) else { return XCTFail("keepalive") }
        guard case .reply(let result) = frame(["id": "req-1", "ok": true, "result": ["a": 1], "_meta": ["runtimeId": "run-1"]]) else { return XCTFail("reply") }
        XCTAssertEqual((result as? [String: Int]), ["a": 1])
    }

    func testFrameFailsOnErrorsAndOnAnswersThatAreNotOurs() {
        for json in [["id": "req-1", "ok": false, "error": ["code": "terminal_handle_stale"]],
                     ["id": "other", "ok": true, "result": [:]],
                     ["id": "req-1", "ok": true, "result": [:], "_meta": ["runtimeId": "restarted"]],
                     ["id": "req-1", "ok": true]] as [[String: Any]] {
            guard case .failed = frame(json) else { return XCTFail("\(json)") }
        }
    }

    func testFocusCountsOnlyAnActualSwitch() {
        XCTAssertTrue(Orca.didNavigate(["focus": ["handle": "h", "tabId": "t", "navigated": true]]))
        XCTAssertTrue(Orca.didNavigate(["focus": ["handle": "h", "tabId": "t"]]))
        XCTAssertFalse(Orca.didNavigate(["focus": ["handle": "h", "navigated": false]])) // headless: nothing switched
        XCTAssertFalse(Orca.didNavigate(["navigated": true]))
        XCTAssertFalse(Orca.didNavigate(["focus": "ok"]))
        XCTAssertFalse(Orca.didNavigate("ok"))
    }

    // MARK: worktrees and the selected tab

    func testWorktreesNameThemAndDropArchivedOnes() {
        let rows: [[String: Any]] = [
            ["worktreeId": "a", "displayName": " Checkout ", "repo": "shop", "branch": "refs/heads/feat/x", "isActive": true],
            ["worktreeId": "b", "displayName": "", "path": "/Users/me/code/app-deals", "branch": "main"],
            ["worktreeId": "c", "isArchived": true, "displayName": "old"],
            ["displayName": "no id"]]
        XCTAssertEqual(Orca.worktrees(["worktrees": rows]), [
            .init(id: "a", name: "Checkout", repo: "shop", branch: "feat/x", isActive: true),
            .init(id: "b", name: "app-deals", repo: "", branch: "main", isActive: false)])
        XCTAssertEqual(Orca.worktrees("nonsense"), [])
    }

    func testSelectedTabIsTheTabOfTheActivePaneOnlyWhenItIsATerminal() {
        let tabs: [[String: Any]] = [["id": "t1::l1", "parentTabId": "t1"], ["id": "file-1"]]
        XCTAssertEqual(Orca.selectedTabId(["activeTabType": "terminal", "activeTabId": "t1::l1", "tabs": tabs]), "t1")
        XCTAssertNil(Orca.selectedTabId(["activeTabType": "editor", "activeTabId": "file-1", "tabs": tabs]))
        XCTAssertNil(Orca.selectedTabId(["activeTabType": "terminal", "activeTabId": "gone", "tabs": tabs]))
    }

    // MARK: one entry per tab

    private func leaf(_ handle: String, _ leafId: String, active: Bool = false, title: String? = nil) -> [String: Any] {
        ["type": "terminal", "handle": handle, "tabId": "ignored", "leafId": leafId, "title": title as Any, "connected": true, "active": active]
    }

    private func tab(_ id: String, _ title: String?, activeLeaf: String?, _ panes: [String: Any]) -> [String: Any] {
        ["tabId": id, "title": title as Any, "activeLeafId": activeLeaf as Any, "panes": panes]
    }

    private func group(_ tabs: [[String: Any]]) -> [String: Any] {
        ["type": "group", "groupId": "g", "activeTabId": tabs.first?["tabId"] as Any, "tabs": tabs]
    }

    private func split(_ first: [String: Any], _ second: [String: Any], type: String = "split") -> [String: Any] {
        ["type": type, "direction": "horizontal", "first": first, "second": second]
    }

    private func list(_ layouts: [String: [String: Any]]) -> [String: Any] {
        ["visualLayouts": layouts.sorted { $0.key < $1.key }.map { ["worktreeId": $0.key, "worktreePath": "/p", "root": $0.value] as [String: Any] }]
    }

    private let shop = Orca.Worktree(id: "w1", name: "Checkout", repo: "shop", branch: "feat/x", isActive: true)
    private let docs = Orca.Worktree(id: "w2", name: "Docs", repo: "shop", branch: "main", isActive: false)

    func testASplitTabIsOneEntryFocusingItsActivePane() {
        let panes = split(leaf("h-left", "l1"), split(leaf("h-top", "l2"), leaf("h-bottom", "l3"), type: "pane-split"))
        let tabs = Orca.tabs(worktrees: [docs], list: list(["w2": group([tab("t1", "server", activeLeaf: "l3", panes)])]), selectedTabId: nil)
        XCTAssertEqual(tabs, [.init(worktreeId: "w2", tabId: "t1", title: "Docs · server", context: "shop main", handle: "h-bottom")])
    }

    func testActivePaneFallsBackToTheActiveFlagThenTheFirstPane() {
        let panes = split(leaf("h1", "l1"), leaf("h2", "l2", active: true))
        XCTAssertEqual(Orca.tabs(worktrees: [docs], list: list(["w2": group([tab("t", "a", activeLeaf: "unknown", panes)])]), selectedTabId: nil).first?.handle, "h2")
        let none = split(leaf("h1", "l1"), leaf("h2", "l2"))
        XCTAssertEqual(Orca.tabs(worktrees: [docs], list: list(["w2": group([tab("t", "a", activeLeaf: nil, none)])]), selectedTabId: nil).first?.handle, "h1")
    }

    func testTabsOfEveryGroupAndWorktreeAreListedWithTheirWorktreeInTheTitle() {
        let layouts = [
            "w1": split(group([tab("a", "one", activeLeaf: "l", leaf("h-a", "l"))]), group([tab("b", "two", activeLeaf: "l", leaf("h-b", "l"))])),
            "w2": group([tab("c", "three", activeLeaf: "l", leaf("h-c", "l"))])]
        let tabs = Orca.tabs(worktrees: [shop, docs], list: list(layouts), selectedTabId: nil)
        XCTAssertEqual(tabs.map(\.title), ["Checkout · one", "Checkout · two", "Docs · three"])
        XCTAssertEqual(tabs.map(\.handle), ["h-a", "h-b", "h-c"])
    }

    func testTheShownTabIsLeftOutOnlyInTheActiveWorktree() {
        let same = group([tab("t1", "shell", activeLeaf: "l", leaf("h", "l")), tab("t2", "other", activeLeaf: "l", leaf("h2", "l"))])
        let tabs = Orca.tabs(worktrees: [shop, docs], list: list(["w1": same, "w2": same]), selectedTabId: "t1")
        XCTAssertEqual(tabs.map(\.title), ["Checkout · other", "Docs · shell", "Docs · other"])
    }

    func testNothingIsLeftOutWhenNoTerminalTabIsShown() {
        let layout = group([tab("t1", "shell", activeLeaf: "l", leaf("h", "l"))])
        XCTAssertEqual(Orca.tabs(worktrees: [shop], list: list(["w1": layout]), selectedTabId: nil).count, 1)
    }

    func testUntitledTabsUseThePaneTitleThenAGenericOne() {
        let layout = group([tab("a", nil, activeLeaf: "l", leaf("h1", "l", title: "zsh")), tab("b", " ", activeLeaf: "l", leaf("h2", "l"))])
        XCTAssertEqual(Orca.tabs(worktrees: [docs], list: list(["w2": layout]), selectedTabId: nil).map(\.title), ["Docs · zsh", "Docs · Terminal"])
    }

    func testUnknownWorktreesAndMalformedTabsAreSkippedWithoutLosingTheRest() {
        let layout = group([["tabId": "no-panes"], tab("ok", "fine", activeLeaf: "l", leaf("h", "l")), tab("no-handle", "x", activeLeaf: "l", ["type": "terminal", "leafId": "l"])])
        let tabs = Orca.tabs(worktrees: [docs], list: list(["w2": layout, "ghost": layout]), selectedTabId: nil)
        XCTAssertEqual(tabs.map(\.tabId), ["ok"])
        XCTAssertEqual(Orca.tabs(worktrees: [docs], list: "nonsense", selectedTabId: nil), [])
    }

    // MARK: tab previews

    private typealias Frame = BrowserTabsTestable.Frame
    private let frame = Frame(x: 0, y: 30, width: 1920, height: 1050)

    private func native(_ wid: CGWindowID, _ title: String) -> BrowserTabsTestable.NativeWindow {
        .init(wid: wid, frame: frame, title: title)
    }

    private func selection(_ tab: String, worktree: String = "w1", runtime: String = "run-1", epoch: String = "renderer") -> Orca.Selection {
        .init(runtimeId: runtime, worktreeId: worktree, tabId: tab, epoch: epoch)
    }

    private func stamp(_ selection: Orca.Selection, pid: pid_t = 50, wid: CGWindowID = 7) -> Orca.Stamp {
        .init(pid: pid, wid: wid, selection: selection, title: "Orca", frame: frame)
    }

    private func image(_ red: UInt8) -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: context.colorSpace!, components: [CGFloat(red) / 255, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        return context.makeImage()!
    }

    private func pending(_ stamp: Orca.Stamp, red: UInt8, afterRead: Int = 0) -> Orca.PendingCapture {
        .init(stamp: stamp, preview: .init(contents: .cgImage(image(red)), size: CGSize(width: 1920, height: 1050)), afterRead: afterRead)
    }

    private func redOf(_ preview: BrowserTabsTestable.Preview?) -> UInt8? {
        guard case .cgImage(let image?) = preview?.contents, let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes[0]
    }

    private func settle(_ cache: inout BrowserTabsTestable.BoundedPreviews<Orca.Key>, _ waiting: Orca.PendingCapture,
                        read: Int, selection: Orca.Selection?) {
        if Orca.verdict(waiting, read: read, selection: selection) == .commit { cache.store(waiting.preview, for: waiting.stamp.key) }
    }

    func testMainWindowIsTheOnlyWindowTitledOrca() {
        XCTAssertEqual(Orca.mainWindow([native(1, "Orca Agent Dashboard"), native(2, "Orca"), native(3, "popout")]), 2)
        XCTAssertNil(Orca.mainWindow([native(2, "Orca"), native(3, "Orca")]))
        XCTAssertNil(Orca.mainWindow([native(1, "Orca Agent Dashboard")]))
        XCTAssertNil(Orca.mainWindow([]))
    }

    func testSelectionNamesTheTerminalTabOfTheActiveWorktreeWithItsRuntime() {
        let session: [String: Any] = ["publicationEpoch": "renderer", "activeTabType": "terminal", "activeTabId": "t1::l1",
                                      "tabs": [["id": "t1::l1", "parentTabId": "t1"]]]
        XCTAssertEqual(Orca.selection(runtimeId: "run-1", before: [shop, docs], session: session, ui: terminalView, after: [shop, docs]),
            selection("t1"))
        let editor: [String: Any] = ["activeTabType": "editor", "activeTabId": "f", "tabs": []]
        XCTAssertNil(Orca.selection(runtimeId: "run-1", before: [shop], session: editor, ui: terminalView, after: [shop]))
        XCTAssertNil(Orca.selection(runtimeId: "run-1", before: [docs], session: session, ui: terminalView, after: [docs]))
    }

    func testSelectionIsRefusedWhenTheActiveWorktreeChangedWhileItsTabsWereRead() {
        let session: [String: Any] = ["activeTabType": "terminal", "activeTabId": "t1::l1", "tabs": [["id": "t1::l1", "parentTabId": "t1"]]]
        let docsActive = Orca.Worktree(id: "w2", name: "Docs", repo: "shop", branch: "main", isActive: true)
        let shopIdle = Orca.Worktree(id: "w1", name: "Checkout", repo: "shop", branch: "feat/x", isActive: false)
        XCTAssertNil(Orca.selection(runtimeId: "run-1", before: [shop, docs], session: session, ui: terminalView, after: [shopIdle, docsActive]))
        XCTAssertNil(Orca.selection(runtimeId: "run-1", before: [shop, docs], session: session, ui: terminalView, after: [shopIdle, docs]))
    }

    private let terminalView: [String: Any] = ["ui": ["activeView": "terminal", "sidebarWidth": 296]]

    func testSelectionIsRefusedWhileAnotherPageReplacesTheTerminalView() {
        // Settings/Tasks leave the worktree, the selected tab and its epoch exactly as they were
        let session: [String: Any] = ["publicationEpoch": "renderer", "activeTabType": "terminal", "activeTabId": "t1::l1",
                                      "tabs": [["id": "t1::l1", "parentTabId": "t1"]]]
        func read(_ ui: Any) -> Orca.Selection? {
            Orca.selection(runtimeId: "run-1", before: [shop], session: session, ui: ui, after: [shop])
        }
        XCTAssertEqual(read(terminalView), selection("t1"))
        for page in ["settings", "tasks", "activity", "automations", "skills", "artifacts"] {
            XCTAssertNil(read(["ui": ["activeView": page]]), page)
        }
        XCTAssertNil(read(["ui": ["activeView": 3]]))
        XCTAssertNil(read(["ui": [:]]))
        XCTAssertNil(read(["activeView": "terminal"]), "not under `ui`")
        XCTAssertNil(read("terminal"))
        // the tab itself is still known (it stays a cache entry to keep), only a capture of the page is refused
        XCTAssertEqual(Orca.shownTab(runtimeId: "run-1", before: [shop], session: session, after: [shop]), selection("t1"))
        XCTAssertTrue(Orca.isTerminalView(terminalView))
        XCTAssertFalse(Orca.isTerminalView(["ui": ["activeView": "settings"]]))
    }

    func testCaptureOnlyCountsForTheWindowItWasRequestedFor() {
        let s = stamp(selection("t1"))
        XCTAssertTrue(Orca.stillShows(s, pid: 50, wid: 7, title: "Orca", frame: Frame(x: 1, y: 31, width: 1919, height: 1051)))
        XCTAssertFalse(Orca.stillShows(s, pid: 50, wid: 8, title: "Orca", frame: frame), "another window of Orca")
        XCTAssertFalse(Orca.stillShows(s, pid: 51, wid: 7, title: "Orca", frame: frame), "a relaunched Orca")
        XCTAssertFalse(Orca.stillShows(s, pid: 50, wid: 7, title: "Orca Agent Dashboard", frame: frame))
        XCTAssertFalse(Orca.stillShows(s, pid: 50, wid: 7, title: "Orca", frame: Frame(x: 0, y: 30, width: 900, height: 700)), "resized meanwhile")
        XCTAssertFalse(Orca.stillShows(s, pid: 50, wid: 7, title: "Orca", frame: nil))
    }

    func testCaptureWaitsForASelectionReadThatStartedAfterIt() {
        let waiting = pending(stamp(selection("t1")), red: 10, afterRead: 3)
        XCTAssertEqual(Orca.verdict(waiting, read: 2, selection: selection("t1")), .wait)
        XCTAssertEqual(Orca.verdict(waiting, read: 3, selection: selection("t1")), .wait)
        XCTAssertEqual(Orca.verdict(waiting, read: 4, selection: selection("t1")), .commit)
    }

    func testCaptureIsDroppedWhenAnotherTabWasShownAfterIt() {
        let waiting = pending(stamp(selection("t1")), red: 10)
        XCTAssertEqual(Orca.verdict(waiting, read: 1, selection: selection("t2")), .drop)
        XCTAssertEqual(Orca.verdict(waiting, read: 1, selection: selection("t1", worktree: "w2")), .drop)
    }

    func testCaptureIsDroppedWhenTheRuntimeRestartedOrRepublishedOrCouldNotAnswer() {
        let waiting = pending(stamp(selection("t1")), red: 10)
        XCTAssertEqual(Orca.verdict(waiting, read: 1, selection: selection("t1", runtime: "run-2")), .drop)
        XCTAssertEqual(Orca.verdict(waiting, read: 1, selection: selection("t1", epoch: "other")), .drop)
        XCTAssertEqual(Orca.verdict(waiting, read: 1, selection: nil), .drop)
    }

    func testATabSwitchDuringACaptureFilesNothingAndTheNextCleanOneDoes() {
        var cache = BrowserTabsTestable.BoundedPreviews<Orca.Key>()
        let t1 = stamp(selection("t1")), t2 = stamp(selection("t2"))
        settle(&cache, pending(t1, red: 10), read: 1, selection: selection("t2"))
        XCTAssertNil(cache.preview(for: t1.key))
        XCTAssertNil(cache.preview(for: t2.key), "the pixels are never filed under the tab the read found")
        settle(&cache, pending(t2, red: 20), read: 2, selection: selection("t2"))
        XCTAssertEqual(redOf(cache.preview(for: t2.key)), 20)
        XCTAssertNil(cache.preview(for: t1.key))
    }

    func testLastConfirmedCaptureWinsAndAnUnconfirmedOneKeepsTheOldImage() {
        var cache = BrowserTabsTestable.BoundedPreviews<Orca.Key>()
        let t1 = stamp(selection("t1"))
        settle(&cache, pending(t1, red: 10), read: 1, selection: selection("t1"))
        settle(&cache, pending(t1, red: 99), read: 2, selection: selection("t7"))
        XCTAssertEqual(redOf(cache.preview(for: t1.key)), 10)
        settle(&cache, pending(t1, red: 30), read: 3, selection: selection("t1"))
        XCTAssertEqual(redOf(cache.preview(for: t1.key)), 30)
    }

    func testSameTabIdInTwoWorktreesAndTwoRuntimesAreKeptApart() {
        var cache = BrowserTabsTestable.BoundedPreviews<Orca.Key>()
        let a = stamp(selection("t1", worktree: "w1")), b = stamp(selection("t1", worktree: "w2"))
        let restarted = stamp(selection("t1", runtime: "run-2"), pid: 99)
        settle(&cache, pending(a, red: 1), read: 1, selection: selection("t1", worktree: "w1"))
        settle(&cache, pending(b, red: 2), read: 1, selection: selection("t1", worktree: "w2"))
        settle(&cache, pending(restarted, red: 3), read: 1, selection: selection("t1", runtime: "run-2"))
        XCTAssertEqual([a, b, restarted].map { redOf(cache.preview(for: $0.key)) }, [1, 2, 3])
        XCTAssertEqual(cache.count, 3)
    }

    func testPreviewsOfTabsThatAreGoneAreDroppedAndTheShownTabIsKept() {
        var cache = BrowserTabsTestable.BoundedPreviews<Orca.Key>()
        let layout = group([tab("t2", "other", activeLeaf: "l", leaf("h2", "l"))])
        let tabs = Orca.tabs(worktrees: [shop], list: list(["w1": layout]), selectedTabId: "t1")
        let shown = selection("t1"), listed = stamp(selection("t2")), closed = stamp(selection("t3"))
        let oldRuntime = stamp(selection("t2", runtime: "run-0"), pid: 49)
        for s in [stamp(shown), listed, closed, oldRuntime] { cache.store(pending(s, red: 5).preview, for: s.key) }
        let live = Orca.liveKeys(pid: 50, runtimeId: "run-1", tabs: tabs, selection: shown)
        cache.remove { !live.contains($0) }
        XCTAssertNotNil(cache.preview(for: stamp(shown).key), "the shown tab is not listed but is the next entry once left")
        XCTAssertNotNil(cache.preview(for: listed.key))
        XCTAssertNil(cache.preview(for: closed.key))
        XCTAssertNil(cache.preview(for: oldRuntime.key), "images of a previous Orca process are never inherited")
    }

    func testPreviewsAreBoundedAndDropTheOldestStoredFirst() {
        var cache = BrowserTabsTestable.BoundedPreviews<Orca.Key>(capacity: 2)
        let stamps = ["a", "b", "c"].map { stamp(selection($0)) }
        for (index, s) in stamps.enumerated() { cache.store(pending(s, red: UInt8(index)).preview, for: s.key) }
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.preview(for: stamps[0].key))
        XCTAssertNotNil(cache.preview(for: stamps[2].key))
    }
}
