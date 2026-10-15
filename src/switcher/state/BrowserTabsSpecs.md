# Browser and Orca tab search — Specs

## Summary

While the user types a search query, the switcher also lists the **inactive tabs** of running Chrome, Brave and
Safari, matched on tab title and URL. Choosing one selects that tab in its own browser window and raises the window.
Active tabs are not listed: their window's own tile already represents them. Orca terminal tabs work the same way, see
"Orca terminal tabs".

## Behavior & edge cases

- **Only while searching.** A tab entry (`VirtualTabWindow`: `BrowserTabWindow`, `OrcaTabWindow`) sits in `Windows.list` (so
  tiles, ranking and selection treat it like any window) but `Windows.shouldDisplay` hides it when the normalized
  query is empty. Ordinary window search and the empty-query list are unchanged.
- **Matching.** The tab title is matched as the window title; the URL (host + path, no scheme or `www.`) takes the
  app-name slot, so "chrome" does not list every tab. Tabs never get an app-name highlight.
- **Not a window.** A tab has no CGWindowID and never enters the reducer (`TrackedWindowStateBridge.snapshot` skips
  it). It does not count for the windowless-app placeholder, the one-window-per-app filter, the search hint's window
  count, `--list`/`--detailed-list`, or `Window.lastFocusOrder` numbering. It bypasses the Space/screen/app filters, so a
  search reaches every open tab. Close, minimize and fullscreen are disabled; no Space number is drawn.
- **Reading tabs.** `BrowserTabs.refresh()` runs after the switcher is shown, on a background queue, one `osascript`
  child per running browser, with a 10 s timeout. The main thread only receives the parsed result
  (`Windows.replaceTabs`). A browser that is not running is not asked (that would launch it). The same read also
  runs 0.5 s (debounced) after a browser window's title changes, see "Tab previews"; that one only asks browsers that
  already answered a read, so browsing never raises the Automation prompt.
- **Focusing.** The script gets the tab URL and index as `argv`. The index is used only if it still holds that URL;
  otherwise the first tab with that URL; if there is none the script fails. On failure AltTab just activates the
  browser. The browser raises the window, and macOS switches Space as for any activation.
- **Stale lists.** Each tab's `id` includes window id, index and URL, so a refresh that shifts tabs does not leave the
  selection on a different tab.
- **Permission.** macOS asks once per browser for Automation access (`NSAppleEventsUsageDescription`). The hardened
  runtime build carries `com.apple.security.automation.apple-events` in `alt_tab_macos.entitlements` (the entitlement
  does not touch Developer ID, TeamID or bundle ID). If denied, no tabs of that browser appear; nothing else changes.
- **Browser dictionaries.** Safari: `current tab`, tab `index`, `name`, `URL` (confirmed against `sdef Safari.app`).
  Chrome and Brave (Chromium): `active tab index`, tab `title`, `URL`. The AppleScript itself has no unit test; the
  focus-by-URL fallback is covered by the manual smoke in the PR notes.

## Tab previews

An inactive tab is never captured (that would mean raising it). Its tile shows the **last capture taken while it was the
active tab of its window**; a tab never seen active keeps the app icon. Nothing is persisted: the cache is in memory
only and also holds pages from private/incognito windows, since the scripting dictionaries expose no private-mode flag.

- **Capture.** No new capture mechanism. A browser window's ordinary thumbnail capture (summon, or the focused-window
  background capture) is filed under its tab when `Window.refreshThumbnail` accepted the frame. Window tiles are
  unchanged. After an identified title change in the frontmost browser, `captureFocusedInBackground` takes one capture
  (same permission, lock and preference guards, 800 ms throttle). No timer and no polling.
- **Identity.** The browser's window id is not a CGWindowID. A browser window is paired with a native window only when
  its active tab's rectangle (AppleScript `bounds`, ±2 pt) matches exactly one native window of that process and no
  other browser window, and the native title equals the tab title or starts with `"<tab title> - "`. Otherwise no
  pairing and no preview. Title alone is never used.
- **Stale pixels.** The pairing (page URL, native title, rectangle) is stamped when a capture is requested and
  re-checked when it is delivered; any difference drops the pixels. Accepted pixels then wait: they are filed under
  the tab only after a read that STARTED after the capture reports that window still showing the stamped URL, so two
  pages with the same title are told apart. A title change, however AltTab learned it (the app's pushed AX title, the
  generic window-title read, or the window re-read on any window event), window close or quit bumps the browser's revision: the
  waiting capture is dropped and any read that started earlier is discarded and asked again. A failed read drops all
  pairings of that browser. Residual race: navigating away and back between the capture and the confirming read cannot
  be told apart. A window with no pairing yet (AltTab started while it was already on that page) is first remembered
  after its next title change. While the switcher is open, a newly identified window is re-captured through the
  ordinary refresh, since its show-time capture predates the pairing.
- **Key and bound.** Cache key is browser pid + browser window id + full URL; two tabs of one window with the same URL
  share an entry (the later capture wins). At most 24 entries, oldest stored dropped first. Every read prunes entries
  whose tab/URL is no longer open in that browser; a quitting browser drops all of its entries.
- **Display.** `BrowserTabWindow` copies the cached `CALayerContents` and window size into `thumbnail`/`size`, so the
  existing tile layout draws it; no pixels are copied. A tab has no wid, so it is never captured itself.

## Orca terminal tabs

The same search also lists the **terminal tabs of Orca** (`com.stablyai.orca`), across all its worktrees. Orca shows one
worktree at a time inside one OS window, so only the tab on screen has a tile of its own; every other tab is a
`OrcaTabWindow` (a `VirtualTabWindow`, like `BrowserTabWindow`: same visibility, reducer, filter and Space rules as above).

- **Title and matching.** The title is "`<worktree> · <tab title>`" (worktree = Orca's display name, else its folder
  name; an untitled tab uses its pane's title, else "Terminal"). The app-name slot holds "`<repo> <branch>`", so
  searching "orca" does not list every tab. The tile shows the last capture taken while that tab was the selected one,
  else the app icon, see "Orca tab previews".
- **One entry per tab.** A tab split into panes is one entry; focusing it focuses the tab's active pane
  (`activeLeafId`, else the pane flagged `active`, else the first). Tabs of every tab group (split layout) of every
  non-archived worktree are listed. Editor, browser and other non-terminal tabs are not.
- **Selected tab.** The terminal tab Orca is showing is not listed: Orca's own window tile represents it. That is the
  pane named by `session.tabs.list.activeTabId` of the active worktree (`worktree.ps` `isActive`), and only when
  `activeTabType` is `terminal`; with an editor shown, all terminal tabs are listed. Other worktrees are never
  affected.
- **Reading.** `OrcaTabs.refresh()` runs on summon, next to the browser read, on a background queue; the main thread
  only receives the result (`Windows.replaceTabs`). It reads `~/Library/Application Support/orca/orca-runtime.json`
  (socket path, token, runtime id) and sends three one-line JSON requests, one connection each: `worktree.ps`,
  `terminal.list` with visual layouts, and `session.tabs.list` for the active worktree. The runtime pushes nothing on
  this transport, so there is no polling and no refresh while the switcher is open. Each request is bounded (3 s per
  read, 5 s total). The token is never logged or stored. Orca is never launched: not running, no runtime file, stopped
  runtime, a reply from another runtime id, or any failing request lists no Orca tabs at all (a partial answer could
  name the wrong worktree or show the selected tab twice). Orca quitting removes its entries at once.
- **Focusing.** `terminal.focus` with the pane's handle and `navigation: "host"` makes Orca switch worktree, tab and
  pane; it does not raise Orca. Orca answers `{focus: {handle, tabId, navigated}}`; a missing `focus` object or
  `navigated: false` counts as no switch. After a successful switch AltTab focuses Orca's own window (the most
  recently used one), like any window, so Space switches and minimized windows work; with no Orca window it
  activates the app. AltTab's focus-intent token is taken when the tab is chosen and checked when the reply lands:
  if any other focus was requested meanwhile, nothing is raised. If the runtime refuses (stale handle, Orca gone,
  headless) nothing is raised, AltTab beeps and the list is re-read, which drops the stale entry. No fallback
  destination is invented.

### Orca tab previews

Same idea as the browser previews: Orca's window can only be captured as a whole, so an inactive tab shows the last
capture taken while it was the one on screen. Nothing is persisted; the images live in memory only (the terminal
content they show is never written anywhere or logged).

- **Capture.** Only Orca's **main window** is captured, through the ordinary thumbnail capture
  (`WindowThumbnails.refreshAsync`, same permission, lock and preference guards; frames the OS drew mid-animation are
  refused as for any window). Orca titles its main window "Orca" and never renames it, while popouts and the agent
  dashboard have other titles, so the main window is the single native Orca window titled exactly "Orca"; with two
  such windows, none is captured. Captures are taken on summon (`OrcaTabs.captureSelected()`, next to the tab read)
  and when Orca's window gets the focus; there is no timer and no polling, and tab switches inside Orca send no
  event AltTab can see, so a tab is remembered only if it was on screen at one of those moments.
- **Only a visible window.** Orca must be the frontmost app, its main window not minimized and on the current Space.
  A covered or backgrounded Chromium window may not have painted a tab that was selected over the runtime, so
  summoning from another app does not capture Orca (correctness over hit rate).
- **Identity: read, capture, read.** The window pixels cannot name their tab. A selection read (`worktree.ps`, then
  `session.tabs.list` of the active worktree, then `ui.get`, then `worktree.ps` again, which must name the same active
  worktree) gives the runtime id, worktree id, tab id and `publicationEpoch` of the shown terminal tab; it is stamped on
  the capture (with Orca's pid, the window id, title and rectangle) only for the one synchronous capture request it
  triggers. `ui.get` must report `ui.activeView == "terminal"`: Settings, Tasks, Activity and the other full-page
  views replace the terminal in the window without changing the worktree, the selected tab or its epoch, so only
  `activeView` tells them apart; a missing or malformed answer counts as not terminal. When the frame is accepted,
  the window must still be the same main window at the same rectangle (±2 pt); the pixels then wait for a second
  selection read (same steps) that STARTED after the capture arrived, and are filed only if it reports the same
  selection. A tab switch in between, another worktree with the same tab id, a restarted runtime or republished
  epoch, an unanswered read, an editor/browser tab on screen, or a non-terminal page on either side of the capture
  files nothing. Reads that started before the capture never vouch for it. All socket calls run on the `orca-tabs`
  queue, never on the main thread, and are started after the switcher is shown. Residual race: switching away and back
  between the two reads cannot be told apart.
- **Key and bound.** Orca pid + runtime id + worktree id + tab id, so equal tab ids of two worktrees and a relaunched Orca
  never share an entry. At most 32 entries (the bounded store of the browser previews), oldest stored dropped first.
  Every successful tab read prunes entries of tabs that are gone (the shown tab, not listed, is kept); Orca quitting
  drops all of them and discards any answer asked for before. A failed read lists no tabs but keeps the images.
- **Display.** `OrcaTabWindow` copies the cached `CALayerContents` and window size into `thumbnail`/`size`, so the
  existing tile layout draws it; a tab never seen on screen keeps the app icon.

## Ghostty native tabs

Ghostty gives every tab its own native window, so its tabs are **not** virtual entries: each is an ordinary
`Window` (same wid, same `TabGroups` membership, focused through the ordinary native `Window.focus`, no Automation
permission, no IPC). `GhosttyTabPolicySpecs.md` has the rules; how they differ from the entries above:

- **Search.** With a non-empty query, a live inactive Ghostty tab is listed even when the shortcut groups tabs and
  whatever its Space, screen or the one-window-per-app setting. The active tab stays its group's single ordinary row.
  With an empty query nothing changes: grouped listing still shows only the active tab.
- **Previews.** One cached picture per tab, kept on its own `Window` and captured only while that tab is shown; no
  picture is ever copied from a sibling, and selecting an inactive result requests no capture. A tab never captured
  while shown draws the app icon. Delayed captures are dropped if the tab was hidden, closed or replaced meanwhile.
- **Window actions** (close, minimize, quit) act on that native window like any other.

## Test scenarios

Mirrors `BrowserTabsTests.swift` (the parsing, pairing, cache policy and URL normalization in `BrowserTabsTestable.swift`).

- **testParseReadsEveryTabInOrder** · **testParseKeepsTabsWithEmptyTitleOrUrl** ·
  **testParseKeepsTabsWithoutUsableGeometryButNoFrame** ·
  **testParseDropsMalformedRecordsWithoutLosingTheRest** · **testParseOfEmptyOutputIsEmpty**
- **testPairMatchesUniqueGeometryAndBrowserTitleSuffix** · **testPairToleratesSubPointRoundingDifferences** ·
  **testPairRefusesWhenTheTitleDisagrees** · **testPairRefusesWindowsStackedOnTheSameRectangle** ·
  **testPairKeepsWindowsAtDifferentRectanglesApart** · **testPairIgnoresInactiveTabsAndMissingGeometryOrTitle**
- **testCacheReturnsTheLastCaptureOfATabAndNothingForAnUnseenOne** ·
  **testCacheKeepsSameUrlInDifferentWindowsAndBrowsersApart** · **testCacheIsBoundedAndDropsTheOldestStoredFirst** ·
  **testRetainDropsClosedTabsAndWindowsOfOneBrowserOnly** · **testRemoveWindowDropsOnlyThatWindowsTabs**
- **testLiveStampDiesWhenTheTitleOrRectangleChangedSinceThePairing** · **testCaptureWaitsForAReadThatStartedAfterIt** ·
  **testSameTitleDifferentUrlIsNotFiledUnderTheCapturedUrl** ·
  **testCaptureIsDroppedWhenTheWindowChangedOrClosedAfterItWasTaken** ·
  **testConfirmedCaptureEndsUpAsTheLastSeenPreviewOfItsTab**
- **testSearchableUrlDropsSchemeAndWww** · **testSearchableUrlWithoutHostIsUnchanged**

Mirrors `OrcaTabsTests.swift` (the parsing and tab mapping in `OrcaTabsTestable.swift`).

- **testRuntimeUsesTheUnixTransportNotTheWebsocketOne** · **testRuntimeIsNilWithoutUnixTransportOrToken**
- **testFrameSkipsKeepalivesAndReturnsTheResultOfOurRequest** ·
  **testFrameFailsOnErrorsAndOnAnswersThatAreNotOurs** · **testFocusCountsOnlyAnActualSwitch**
- **testWorktreesNameThemAndDropArchivedOnes** ·
  **testSelectedTabIsTheTabOfTheActivePaneOnlyWhenItIsATerminal**
- **testASplitTabIsOneEntryFocusingItsActivePane** · **testActivePaneFallsBackToTheActiveFlagThenTheFirstPane** ·
  **testTabsOfEveryGroupAndWorktreeAreListedWithTheirWorktreeInTheTitle** ·
  **testTheShownTabIsLeftOutOnlyInTheActiveWorktree** · **testNothingIsLeftOutWhenNoTerminalTabIsShown** ·
  **testUntitledTabsUseThePaneTitleThenAGenericOne** ·
  **testUnknownWorktreesAndMalformedTabsAreSkippedWithoutLosingTheRest**

Orca previews (same file, `OrcaTabsTestable`'s selection, stamp, verdict and cache keys).

- **testMainWindowIsTheOnlyWindowTitledOrca** · **testSelectionNamesTheTerminalTabOfTheActiveWorktreeWithItsRuntime** ·
  **testSelectionIsRefusedWhenTheActiveWorktreeChangedWhileItsTabsWereRead** ·
  **testSelectionIsRefusedWhileAnotherPageReplacesTheTerminalView**
- **testCaptureOnlyCountsForTheWindowItWasRequestedFor** · **testCaptureWaitsForASelectionReadThatStartedAfterIt** ·
  **testCaptureIsDroppedWhenAnotherTabWasShownAfterIt** ·
  **testCaptureIsDroppedWhenTheRuntimeRestartedOrRepublishedOrCouldNotAnswer**
- **testATabSwitchDuringACaptureFilesNothingAndTheNextCleanOneDoes** ·
  **testLastConfirmedCaptureWinsAndAnUnconfirmedOneKeepsTheOldImage** ·
  **testSameTabIdInTwoWorktreesAndTwoRuntimesAreKeptApart** ·
  **testPreviewsOfTabsThatAreGoneAreDroppedAndTheShownTabIsKept** ·
  **testPreviewsAreBoundedAndDropTheOldestStoredFirst**
