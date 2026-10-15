import CoreGraphics
import Foundation

/// Ghostty gives every native tab its own NSWindow, so its tabs are ordinary `Window`s grouped by `TabGroups`
/// (unlike the `VirtualTabWindow` entries of browsers and Orca). See `GhosttyTabPolicySpecs.md`.
enum GhosttyTabPolicy {
    static let bundleId = "com.mitchellh.ghostty"

    static func isGhostty(_ app: ApplicationState) -> Bool { app.bundleIdentifier == bundleId }

    /// An inactive tab a non-empty search may list whatever the shortcut's tab grouping says.
    static func isSearchableInactiveTab(_ s: WindowState, _ app: ApplicationState, isAlive: Bool,
                                        groupHasScreenClaim: Bool) -> Bool {
        isGhostty(app) && s.isTabbed && !s.isPhantom && !s.isWindowlessApp && s.axStatus == .axVerified
            && isAlive && groupHasScreenClaim
    }

    /// Is this window the tab Ghostty is showing, so a capture of it holds its own pixels? An ordered-out tab
    /// shares its group's frame and Space, and a capture of it can return anything. Being the group's
    /// representative (`!isTabbed`) or a borrowed Space are inferences, so the WindowServer must also have it
    /// ordered in on a Space the user sees.
    static func isShownTab(_ s: WindowState, _ app: ApplicationState, isOrderedIn: Bool, spaceIsBorrowed: Bool,
                           isAlive: Bool, visibleSpaceIds: [UInt64]) -> Bool {
        isGhostty(app) && !s.isTabbed && !s.isPhantom && !s.isWindowlessApp && !s.isMinimized && !app.isHidden
            && isAlive && isOrderedIn && !spaceIsBorrowed
            && s.spaceIds.contains { visibleSpaceIds.contains($0) }
    }

    static let captureGate = CaptureGate()

    /// Which uninterrupted run of being shown a capture request was made in. Main records every change
    /// (`update`); capture queues, which cannot read the model, compare (`holds`). A tab hidden and shown again
    /// starts a new run, so a capture requested before it is refused.
    final class CaptureGate {
        private let lock = NSLock()
        private var runs = [CGWindowID: UInt64]()
        private var lastRun: UInt64 = 0

        /// Main-thread. Returns the tab's current run, nil when it is not shown.
        @discardableResult
        func update(_ wid: CGWindowID, shown: Bool) -> UInt64? {
            lock.lock()
            defer { lock.unlock() }
            guard shown else {
                runs[wid] = nil
                return nil
            }
            if let run = runs[wid] { return run }
            lastRun += 1
            runs[wid] = lastRun
            return lastRun
        }

        /// Any thread.
        func holds(_ wid: CGWindowID, run: UInt64) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return runs[wid] == run
        }
    }
}
