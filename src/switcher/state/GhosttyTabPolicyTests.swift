import XCTest

final class GhosttyTabPolicyTests: XCTestCase {
    private typealias Policy = GhosttyTabPolicy

    private func ws(isPhantom: Bool = false, isWindowlessApp: Bool = false, isMinimized: Bool = false,
                    isTabbed: Bool = false, spaceIds: [UInt64] = [1],
                    axStatus: AxSemanticStatus = .axVerified) -> WindowState {
        var state = WindowState(id: "w", isPhantom: isPhantom, isWindowlessApp: isWindowlessApp, isFullscreen: false,
                                isMinimized: isMinimized, isTabbed: isTabbed, isOnAllSpaces: false, spaceIds: spaceIds,
                                spaceIndexes: [], lastFocusOrder: 0, creationOrder: 0, title: "tab")
        state.axStatus = axStatus
        return state
    }

    private func app(_ bundleIdentifier: String? = Policy.bundleId, isHidden: Bool = false) -> ApplicationState {
        ApplicationState(pid: 1, bundleIdentifier: bundleIdentifier, localizedName: nil, isHidden: isHidden)
    }

    // MARK: search candidates

    func testALiveInactiveGhosttyTabIsSearchable() {
        XCTAssertTrue(Policy.isSearchableInactiveTab(ws(isTabbed: true), app(), isAlive: true, groupHasScreenClaim: true))
    }

    func testOnlyGhosttyIsSupplemented() {
        XCTAssertFalse(Policy.isSearchableInactiveTab(ws(isTabbed: true), app("com.apple.Terminal"), isAlive: true,
                                                      groupHasScreenClaim: true))
        XCTAssertFalse(Policy.isSearchableInactiveTab(ws(isTabbed: true), app(nil), isAlive: true, groupHasScreenClaim: true))
    }

    func testTheShownTabAndStandaloneWindowsAreNotSupplemented() {
        XCTAssertFalse(Policy.isSearchableInactiveTab(ws(isTabbed: false), app(), isAlive: true, groupHasScreenClaim: true))
    }

    func testOnlyAVerifiedLivingMemberOfALiveGroupIsSearchable() {
        XCTAssertFalse(Policy.isSearchableInactiveTab(ws(isPhantom: true, isTabbed: true), app(), isAlive: true,
                                                      groupHasScreenClaim: true), "phantom")
        XCTAssertFalse(Policy.isSearchableInactiveTab(ws(isTabbed: true), app(), isAlive: false,
                                                      groupHasScreenClaim: true), "closing, replaced or unverified")
        XCTAssertFalse(Policy.isSearchableInactiveTab(ws(isTabbed: true, axStatus: .attentionCandidate), app(),
                                                      isAlive: true, groupHasScreenClaim: true), "no AX verification")
        XCTAssertFalse(Policy.isSearchableInactiveTab(ws(isWindowlessApp: true, isTabbed: true), app(), isAlive: true,
                                                      groupHasScreenClaim: true), "placeholder")
        XCTAssertFalse(Policy.isSearchableInactiveTab(ws(isTabbed: true), app(), isAlive: true,
                                                      groupHasScreenClaim: false), "what a dead group leaves behind")
    }

    // MARK: the shown tab

    private func shown(_ window: WindowState? = nil, _ application: ApplicationState? = nil, isOrderedIn: Bool = true,
                       spaceIsBorrowed: Bool = false, isAlive: Bool = true, visible: [UInt64] = [1, 2]) -> Bool {
        Policy.isShownTab(window ?? ws(), application ?? app(), isOrderedIn: isOrderedIn,
                          spaceIsBorrowed: spaceIsBorrowed, isAlive: isAlive, visibleSpaceIds: visible)
    }

    func testAnOrderedInTabOnAVisibleSpaceIsShown() {
        XCTAssertTrue(shown())
        XCTAssertTrue(shown(ws(spaceIds: [2])), "a fullscreen Space the user is looking at")
    }

    func testEveryPhysicalFactIsRequired() {
        XCTAssertFalse(shown(ws(isTabbed: true)), "inactive tab")
        XCTAssertFalse(shown(isOrderedIn: false), "ordered out by the WindowServer")
        XCTAssertFalse(shown(spaceIsBorrowed: true), "a Space lent by the group is not evidence")
        XCTAssertFalse(shown(visible: [7]), "another Space")
        XCTAssertFalse(shown(ws(spaceIds: [])), "no Space")
        XCTAssertFalse(shown(ws(isMinimized: true)), "minimized")
        XCTAssertFalse(shown(nil, app(isHidden: true)), "hidden app")
        XCTAssertFalse(shown(ws(isPhantom: true)), "phantom")
        XCTAssertFalse(shown(isAlive: false), "closing or replaced")
        XCTAssertFalse(shown(ws(isWindowlessApp: true)), "placeholder")
    }

    // MARK: the capture gate

    func testARunIsStableWhileTheTabStaysShown() {
        let gate = Policy.CaptureGate()
        let run = gate.update(10, shown: true)
        XCTAssertNotNil(run)
        XCTAssertEqual(gate.update(10, shown: true), run)
        XCTAssertTrue(gate.holds(10, run: run!))
    }

    /// Work queued before a hide is refused even though the tab is shown again when it reaches the capture API.
    func testAHiddenThenShownTabRefusesWorkRequestedBeforeItWasHidden() throws {
        let gate = Policy.CaptureGate()
        let first = try XCTUnwrap(gate.update(10, shown: true))
        XCTAssertNil(gate.update(10, shown: false))
        XCTAssertFalse(gate.holds(10, run: first), "hidden: the queued capture is refused")
        let second = try XCTUnwrap(gate.update(10, shown: true))
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(gate.holds(10, run: first), "shown again: still not the run it was requested in")
        XCTAssertTrue(gate.holds(10, run: second))
    }

    func testTabsAreGatedIndependently() throws {
        let gate = Policy.CaptureGate()
        let shownRun = try XCTUnwrap(gate.update(10, shown: true))
        let hiddenRun = try XCTUnwrap(gate.update(11, shown: true))
        gate.update(11, shown: false)
        XCTAssertTrue(gate.holds(10, run: shownRun))
        XCTAssertFalse(gate.holds(11, run: hiddenRun))
        XCTAssertNotEqual(shownRun, hiddenRun)
    }

    func testAWindowTheGateNeverSawHoldsNothing() {
        XCTAssertFalse(Policy.CaptureGate().holds(99, run: 1))
    }
}
