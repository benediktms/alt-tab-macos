import XCTest
import CoreGraphics

final class BrowserTabsTests: XCTestCase {
    private let rs = "\u{1E}", us = "\u{1F}"
    private typealias Frame = BrowserTabsTestable.Frame
    private typealias Key = BrowserTabsTestable.Key
    private let frame = Frame(x: 10, y: 20, width: 800, height: 600)

    private func record(_ window: Int, _ index: Int, _ active: Bool, _ title: String, _ url: String, geometry: [String] = ["10", "20", "800", "600"]) -> String {
        ([String(window), String(index), active ? "true" : "false", title, url] + geometry).joined(separator: us) + rs
    }

    func testParseReadsEveryTabInOrder() {
        let output = record(7, 1, true, "Inbox", "https://mail.example.com/") + record(7, 2, false, "Docs", "https://docs.example.com/a")
        XCTAssertEqual(BrowserTabsTestable.parse(output), [
            .init(windowId: 7, index: 1, isActive: true, title: "Inbox", url: "https://mail.example.com/", frame: frame),
            .init(windowId: 7, index: 2, isActive: false, title: "Docs", url: "https://docs.example.com/a", frame: frame)])
    }

    func testParseKeepsTabsWithEmptyTitleOrUrl() {
        XCTAssertEqual(BrowserTabsTestable.parse(record(3, 4, false, "", "")),
            [.init(windowId: 3, index: 4, isActive: false, title: "", url: "", frame: frame)])
    }

    func testParseKeepsTabsWithoutUsableGeometryButNoFrame() {
        XCTAssertNil(BrowserTabsTestable.parse(record(1, 1, true, "t", "u", geometry: ["0", "0", "0", "0"])).first?.frame)
        XCTAssertNil(BrowserTabsTestable.parse(record(1, 1, true, "t", "u", geometry: ["a", "0", "9", "9"])).first?.frame)
        XCTAssertEqual(BrowserTabsTestable.parse(record(1, 1, true, "t", "u", geometry: ["10.0", "20", "800.4", "600"])).first?.frame, frame)
    }

    // MARK: pairing a browser window with a native window

    private func tab(_ window: Int, _ title: String, active: Bool = true, frame: Frame? = Frame(x: 10, y: 20, width: 800, height: 600)) -> BrowserTabsTestable.Tab {
        .init(windowId: window, index: 1, isActive: active, title: title, url: "https://e.com/\(title)", frame: frame)
    }

    private func native(_ wid: CGWindowID, _ title: String, frame: Frame? = Frame(x: 10, y: 20, width: 800, height: 600)) -> BrowserTabsTestable.NativeWindow {
        .init(wid: wid, frame: frame, title: title)
    }

    func testPairMatchesUniqueGeometryAndBrowserTitleSuffix() {
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox")], [native(100, "Inbox - Google Chrome - Work")]), [7: 100])
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox")], [native(100, "Inbox")]), [7: 100])
    }

    func testPairToleratesSubPointRoundingDifferences() {
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox")], [native(100, "Inbox", frame: Frame(x: 11, y: 19, width: 801, height: 600))]), [7: 100])
    }

    func testPairRefusesWhenTheTitleDisagrees() {
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox")], [native(100, "Docs - Google Chrome")]), [:])
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox")], [native(100, "Inboxes")]), [:])
    }

    func testPairRefusesWindowsStackedOnTheSameRectangle() {
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox")], [native(100, "Inbox"), native(101, "Inbox")]), [:])
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox"), tab(8, "Inbox")], [native(100, "Inbox")]), [:])
    }

    func testPairKeepsWindowsAtDifferentRectanglesApart() {
        let other = Frame(x: 400, y: 300, width: 800, height: 600)
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "A"), tab(8, "B", frame: other)],
            [native(100, "A"), native(101, "B", frame: other)]), [7: 100, 8: 101])
    }

    func testPairIgnoresInactiveTabsAndMissingGeometryOrTitle() {
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox", active: false)], [native(100, "Inbox")]), [:])
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "Inbox", frame: nil)], [native(100, "Inbox")]), [:])
        XCTAssertEqual(BrowserTabsTestable.pair([tab(7, "")], [native(100, "")]), [:])
    }

    // MARK: the preview cache, with real pixels

    private func image(_ red: UInt8) -> CGImage {
        let context = CGContext(data: nil, width: 4, height: 3, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // the context's own space: a GenericRGB CGColor would be converted to DeviceRGB and shift the byte
        context.setFillColor(CGColor(colorSpace: context.colorSpace!, components: [CGFloat(red) / 255, 0, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        return context.makeImage()!
    }

    private func preview(_ red: UInt8) -> BrowserTabsTestable.Preview {
        .init(contents: .cgImage(image(red)), size: CGSize(width: 800, height: 600))
    }

    private func redOf(_ preview: BrowserTabsTestable.Preview?) -> UInt8? {
        guard case .cgImage(let image?) = preview?.contents, let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        return bytes[0]
    }

    func testCacheReturnsTheLastCaptureOfATabAndNothingForAnUnseenOne() {
        var cache = BrowserTabsTestable.PreviewCache()
        let a = Key(pid: 1, windowId: 7, url: "https://a/"), c = Key(pid: 1, windowId: 7, url: "https://c/")
        cache.store(preview(200), for: a)
        XCTAssertEqual(redOf(cache.preview(for: a)), 200)
        XCTAssertEqual(cache.preview(for: a)?.size, CGSize(width: 800, height: 600))
        XCTAssertNil(cache.preview(for: c))
        cache.store(preview(50), for: a)
        XCTAssertEqual(redOf(cache.preview(for: a)), 50)
        XCTAssertEqual(cache.count, 1)
    }

    func testCacheKeepsSameUrlInDifferentWindowsAndBrowsersApart() {
        var cache = BrowserTabsTestable.PreviewCache()
        cache.store(preview(10), for: Key(pid: 1, windowId: 7, url: "https://a/"))
        cache.store(preview(20), for: Key(pid: 1, windowId: 8, url: "https://a/"))
        cache.store(preview(30), for: Key(pid: 2, windowId: 7, url: "https://a/"))
        XCTAssertEqual(redOf(cache.preview(for: Key(pid: 1, windowId: 7, url: "https://a/"))), 10)
        XCTAssertEqual(redOf(cache.preview(for: Key(pid: 1, windowId: 8, url: "https://a/"))), 20)
        XCTAssertEqual(redOf(cache.preview(for: Key(pid: 2, windowId: 7, url: "https://a/"))), 30)
    }

    func testCacheIsBoundedAndDropsTheOldestStoredFirst() {
        var cache = BrowserTabsTestable.PreviewCache(capacity: 2)
        let keys = (0..<3).map { Key(pid: 1, windowId: 1, url: "https://\($0)/") }
        cache.store(preview(1), for: keys[0])
        cache.store(preview(2), for: keys[1])
        cache.store(preview(1), for: keys[0])
        cache.store(preview(3), for: keys[2])
        XCTAssertEqual(cache.count, 2)
        XCTAssertNil(cache.preview(for: keys[1]))
        XCTAssertNotNil(cache.preview(for: keys[0]))
        XCTAssertNotNil(cache.preview(for: keys[2]))
    }

    func testRetainDropsClosedTabsAndWindowsOfOneBrowserOnly() {
        var cache = BrowserTabsTestable.PreviewCache()
        let open = Key(pid: 1, windowId: 7, url: "https://open/"), closed = Key(pid: 1, windowId: 8, url: "https://closed/")
        let navigatedAway = Key(pid: 1, windowId: 7, url: "https://old/"), other = Key(pid: 2, windowId: 7, url: "https://x/")
        for key in [open, closed, navigatedAway, other] { cache.store(preview(9), for: key) }
        cache.retain(pid: 1, live: [open])
        XCTAssertNotNil(cache.preview(for: open))
        XCTAssertNil(cache.preview(for: closed))
        XCTAssertNil(cache.preview(for: navigatedAway))
        XCTAssertNotNil(cache.preview(for: other))
        cache.retain(pid: 2, live: [])
        XCTAssertEqual(cache.count, 1)
    }

    func testRemoveWindowDropsOnlyThatWindowsTabs() {
        var cache = BrowserTabsTestable.PreviewCache()
        let gone = Key(pid: 1, windowId: 7, url: "https://a/"), goneToo = Key(pid: 1, windowId: 7, url: "https://b/")
        let kept = Key(pid: 1, windowId: 8, url: "https://a/")
        for key in [gone, goneToo, kept] { cache.store(preview(9), for: key) }
        cache.removeWindow(pid: 1, windowId: 7)
        XCTAssertNil(cache.preview(for: gone))
        XCTAssertNil(cache.preview(for: goneToo))
        XCTAssertNotNil(cache.preview(for: kept))
    }

    // MARK: a capture is filed only when the page it shows is confirmed

    private func stamp(_ url: String, title: String = "Inbox") -> BrowserTabsTestable.Stamp {
        .init(key: Key(pid: 1, windowId: 7, url: url), nativeTitle: title, frame: frame)
    }

    private func pending(_ url: String, revision: Int = 0, afterRead: Int = 3, red: UInt8 = 200) -> BrowserTabsTestable.PendingCapture {
        .init(stamp: stamp(url), preview: preview(red), revision: revision, afterRead: afterRead)
    }

    func testLiveStampDiesWhenTheTitleOrRectangleChangedSinceThePairing() {
        let binding = stamp("https://a/")
        XCTAssertEqual(BrowserTabsTestable.liveStamp(binding, title: "Inbox", frame: frame), binding)
        XCTAssertNil(BrowserTabsTestable.liveStamp(binding, title: "Docs", frame: frame))
        XCTAssertNil(BrowserTabsTestable.liveStamp(binding, title: "Inbox", frame: Frame(x: 10, y: 20, width: 500, height: 600)))
        XCTAssertNil(BrowserTabsTestable.liveStamp(binding, title: "Inbox", frame: nil))
        XCTAssertNil(BrowserTabsTestable.liveStamp(nil, title: "Inbox", frame: frame))
    }

    func testCaptureWaitsForAReadThatStartedAfterIt() {
        XCTAssertEqual(BrowserTabsTestable.verdict(pending("https://a/"), fresh: stamp("https://a/"), read: 3, revision: 0), .wait)
        XCTAssertEqual(BrowserTabsTestable.verdict(pending("https://a/"), fresh: stamp("https://a/"), read: 4, revision: 0), .commit)
    }

    func testSameTitleDifferentUrlIsNotFiledUnderTheCapturedUrl() {
        XCTAssertEqual(BrowserTabsTestable.verdict(pending("https://a/"), fresh: stamp("https://b/"), read: 4, revision: 0), .drop)
        XCTAssertEqual(BrowserTabsTestable.verdict(pending("https://a/"), fresh: nil, read: 4, revision: 0), .drop)
    }

    func testCaptureIsDroppedWhenTheWindowChangedOrClosedAfterItWasTaken() {
        XCTAssertEqual(BrowserTabsTestable.verdict(pending("https://a/", revision: 0), fresh: stamp("https://a/"), read: 4, revision: 1), .drop)
        XCTAssertEqual(BrowserTabsTestable.verdict(pending("https://a/", revision: 0), fresh: stamp("https://a/"), read: 3, revision: 1), .drop)
    }

    func testConfirmedCaptureEndsUpAsTheLastSeenPreviewOfItsTab() {
        var cache = BrowserTabsTestable.PreviewCache()
        let a = pending("https://a/", red: 200), b = pending("https://b/", red: 50)
        if BrowserTabsTestable.verdict(a, fresh: stamp("https://a/"), read: 4, revision: 0) == .commit {
            cache.store(a.preview, for: a.stamp.key)
        }
        if BrowserTabsTestable.verdict(b, fresh: stamp("https://a/"), read: 4, revision: 0) == .commit {
            cache.store(b.preview, for: b.stamp.key)
        }
        XCTAssertEqual(redOf(cache.preview(for: Key(pid: 1, windowId: 7, url: "https://a/"))), 200)
        XCTAssertNil(cache.preview(for: Key(pid: 1, windowId: 7, url: "https://b/")))
    }

    func testParseDropsMalformedRecordsWithoutLosingTheRest() {
        let output = "garbage" + rs + record(1, 1, false, "ok", "u") + "x" + us + "2" + us + "false" + us + "t" + us + "u" + rs
        XCTAssertEqual(BrowserTabsTestable.parse(output).map(\.title), ["ok"])
    }

    func testParseOfEmptyOutputIsEmpty() {
        XCTAssertEqual(BrowserTabsTestable.parse(""), [])
    }

    func testSearchableUrlDropsSchemeAndWww() {
        XCTAssertEqual(BrowserTabsTestable.searchableUrl("https://www.example.com/a/b?q=1#f"), "example.com/a/b")
        XCTAssertEqual(BrowserTabsTestable.searchableUrl("http://docs.example.com"), "docs.example.com")
    }

    func testSearchableUrlWithoutHostIsUnchanged() {
        XCTAssertEqual(BrowserTabsTestable.searchableUrl("about:blank"), "about:blank")
        XCTAssertEqual(BrowserTabsTestable.searchableUrl(""), "")
    }
}
