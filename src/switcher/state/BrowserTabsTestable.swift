import Foundation
import CoreGraphics

/// The pure half of browser-tab search (no process or AppKit access), so `BrowserTabsTests` pins it.
enum BrowserTabsTestable {
    enum Browser: CaseIterable {
        case chrome, brave, safari

        var bundleId: String {
            switch self {
                case .chrome: return "com.google.Chrome"
                case .brave: return "com.brave.Browser"
                case .safari: return "com.apple.Safari"
            }
        }
    }

    /// A window rectangle in top-left-origin points, the coordinate space of both AppleScript `bounds` and AX.
    struct Frame: Equatable {
        let x: Int, y: Int, width: Int, height: Int

        init(x: Int, y: Int, width: Int, height: Int) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }

        init(position: CGPoint, size: CGSize) {
            self.init(x: Int(position.x.rounded()), y: Int(position.y.rounded()),
                width: Int(size.width.rounded()), height: Int(size.height.rounded()))
        }

        /// Rounding differs a point or two between the browser's report and AX, so equality is approximate.
        func matches(_ other: Frame) -> Bool {
            abs(x - other.x) <= 2 && abs(y - other.y) <= 2 && abs(width - other.width) <= 2 && abs(height - other.height) <= 2
        }
    }

    struct Tab: Equatable {
        let windowId: Int
        let index: Int
        let isActive: Bool
        let title: String
        let url: String
        let frame: Frame?
    }

    struct NativeWindow: Equatable {
        let wid: CGWindowID
        let frame: Frame?
        let title: String
    }

    /// AppleScript window ids are not CGWindowIDs and nothing else maps one to the other. A pairing is made only when
    /// it is unambiguous: the active tab's window rectangle matches exactly one native window and no other browser
    /// window, and that native window's title is the tab's title (the browser appends " - <browser>" to it).
    static func pair(_ tabs: [Tab], _ natives: [NativeWindow]) -> [Int: CGWindowID] {
        let active = tabs.filter { $0.isActive }
        var paired = [Int: CGWindowID]()
        for tab in active {
            guard let frame = tab.frame, !tab.title.isEmpty else { continue }
            let candidates = natives.filter { $0.frame?.matches(frame) == true }
            guard candidates.count == 1, let native = candidates.first,
                  native.title == tab.title || native.title.hasPrefix(tab.title + " - "),
                  active.count(where: { $0.frame?.matches(frame) == true }) == 1 else { continue }
            paired[tab.windowId] = native.wid
        }
        return paired
    }

    struct Key: Hashable {
        let pid: pid_t
        let windowId: Int
        let url: String
    }

    /// What a capture of a native window is known to show, taken when requested and compared with the live one when
    /// delivered: any difference means the page may have changed in between, so the pixels are dropped.
    struct Stamp: Equatable {
        let key: Key
        let nativeTitle: String
        let frame: Frame
    }

    struct Preview {
        let contents: CALayerContents
        let size: CGSize
    }

    /// The last accepted capture of each tab while it was the active one. Two tabs of one window with the same URL
    /// share an entry (the later capture wins), the accepted cost of keying on the URL. Generic over the key so
    /// Orca's terminal-tab previews use the same bounded store.
    struct BoundedPreviews<K: Hashable> {
        private var previews = [K: Preview]()
        private var order = [K]()
        let capacity: Int

        init(capacity: Int = 24) { self.capacity = capacity }

        var count: Int { order.count }

        func preview(for key: K) -> Preview? { previews[key] }

        mutating func store(_ preview: Preview, for key: K) {
            if previews.updateValue(preview, forKey: key) != nil { order.removeAll { $0 == key } }
            order.append(key)
            while order.count > capacity { previews[order.removeFirst()] = nil }
        }

        mutating func remove(where doomed: (K) -> Bool) {
            order.removeAll { key in
                guard doomed(key) else { return false }
                previews[key] = nil
                return true
            }
        }
    }

    typealias PreviewCache = BoundedPreviews<Key>

    static func liveStamp(_ binding: Stamp?, title: String, frame: Frame?) -> Stamp? {
        guard let binding, let frame, title == binding.nativeTitle, frame.matches(binding.frame) else { return nil }
        return binding
    }

    /// An accepted capture held back until a read that STARTED after it confirms the page its window showed: only a
    /// read tells the browser's active URL.
    struct PendingCapture {
        let stamp: Stamp
        let preview: Preview
        let revision: Int
        /// number of reads already started when captured; only a later one can vouch for it
        let afterRead: Int
    }

    enum Verdict { case wait, commit, drop }

    static func verdict(_ pending: PendingCapture, fresh: Stamp?, read: Int, revision: Int) -> Verdict {
        guard pending.revision == revision else { return .drop }
        guard read > pending.afterRead else { return .wait }
        return fresh == pending.stamp ? .commit : .drop
    }

    private static let recordSeparator = "\u{1E}"
    private static let fieldSeparator = "\u{1F}"

    /// One record per tab, in the order `listScript` writes them; malformed records are dropped.
    static func parse(_ output: String) -> [Tab] {
        output.split(separator: Character(recordSeparator)).compactMap { record in
            let fields = record.split(separator: Character(fieldSeparator), omittingEmptySubsequences: false)
            guard fields.count == 9, let windowId = Int(fields[0]), let index = Int(fields[1]) else { return nil }
            let numbers = fields[5...].compactMap { Double($0) }
            let frame = numbers.count == 4 && numbers[2] > 0 && numbers[3] > 0
                ? Frame(position: CGPoint(x: numbers[0], y: numbers[1]), size: CGSize(width: numbers[2], height: numbers[3])) : nil
            return Tab(windowId: windowId, index: index, isActive: fields[2] == "true",
                title: String(fields[3]), url: String(fields[4]), frame: frame)
        }
    }

    static func searchableUrl(_ url: String) -> String {
        guard let components = URLComponents(string: url), let host = components.host else { return url }
        let trimmedHost = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return trimmedHost + components.path
    }

    static func listScript(_ browser: Browser) -> String {
        let activeIndex = browser == .safari ? "index of current tab of w" : "active tab index of w"
        let titles = browser == .safari ? "name of every tab of w" : "title of every tab of w"
        return """
        set RS to (ASCII character 30)
        set US to (ASCII character 31)
        set out to ""
        tell application id "\(browser.bundleId)"
            repeat with w in windows
                try
                    set wid to id of w
                    set b to {0, 0, 0, 0}
                    try
                        set b to bounds of w
                    end try
                    set geometry to ((item 1 of b) as text) & US & ((item 2 of b) as text) & US & (((item 3 of b) - (item 1 of b)) as text) & US & (((item 4 of b) - (item 2 of b)) as text)
                    set ai to \(activeIndex)
                    set ts to \(titles)
                    set us_ to URL of every tab of w
                    repeat with i from 1 to count of ts
                        set t to item i of ts
                        if t is missing value then set t to ""
                        set u to item i of us_
                        if u is missing value then set u to ""
                        set out to out & wid & US & i & US & (i = ai) & US & t & US & u & US & geometry & RS
                    end repeat
                end try
            end repeat
        end tell
        return out
        """
    }

    /// Takes the tab's URL and its index when listed as `argv`, never interpolated into the source. The list
    /// may be older than the browser: tabs shift when the user closes or reorders one. So the remembered index is
    /// used only if it still holds that URL; otherwise the first tab with that URL, and when none does the script
    /// fails (non-zero exit) rather than raise some other tab.
    static func focusScript(_ browser: Browser, windowId: Int) -> String {
        let selectTab = browser == .safari
            ? "set current tab of w to tab found of w"
            : "set active tab index of w to found"
        return """
        on run argv
            set wantedUrl to item 1 of argv
            set wantedIndex to (item 2 of argv) as integer
            tell application id "\(browser.bundleId)"
                set w to window id \(windowId)
                set urls to URL of every tab of w
                set found to 0
                if wantedIndex <= (count of urls) then
                    if item wantedIndex of urls is wantedUrl then set found to wantedIndex
                end if
                if found is 0 then
                    repeat with i from 1 to count of urls
                        if item i of urls is wantedUrl then
                            set found to i
                            exit repeat
                        end if
                    end repeat
                end if
                if found is 0 then error "tab is gone"
                \(selectTab)
                set index of w to 1
                activate
            end tell
        end run
        """
    }
}

extension BrowserTabsTestable.BoundedPreviews where K == BrowserTabsTestable.Key {
    mutating func retain(pid: pid_t, live: Set<K>) {
        remove { $0.pid == pid && !live.contains($0) }
    }

    mutating func removeWindow(pid: pid_t, windowId: Int) {
        remove { $0.pid == pid && $0.windowId == windowId }
    }
}
