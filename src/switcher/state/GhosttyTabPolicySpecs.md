# GhosttyTabPolicy

Ghostty's native tabs: which inactive ones a search lists, and when a capture of a tab's window is that tab's own
picture. Pinned by `GhosttyTabPolicyTests.swift`; the reducer half (no thumbnail borrowing) by
`TestReducerRunnerTests`.

## Why it exists

Ghostty gives every tab its own `NSWindow` in a native tab group, so a tab is an ordinary `Window` grouped by
`TabGroups`, not a `VirtualTabWindow` like a browser or Orca tab. Two consequences need a Ghostty-specific rule:

- With tabs grouped (the default) `WindowFilterResolver` hides every inactive tab, so a search cannot reach it.
- An inactive tab is an ordered-out window that shares its group's frame. A capture addressed to it proves nothing
  about its content, and a sibling's picture is another terminal. Other apps tolerate both because their placeholder
  is only a stop-gap; for a terminal it is wrong content.

## Behavior & edge cases

- **Search.** While the query is non-empty, a **live inactive Ghostty tab** is displayed even if the ordinary filters
  hide it (grouped tabs, other Space, other screen, one window per app). It must be a member of a group that still has
  a claim to the screen, AX-verified, alive, and not phantom. Raw inventory surfaces, closing windows and what a dead
  group leaves behind are never listed. `Search.matches` and ranking are unchanged, so the app name also matches.
  The shown tab is its group's ordinary result and gets no second entry. With an empty query nothing changes.
- **Pictures.** A tab is captured only while it is the one shown: not an inactive tab, ordered in by the WindowServer,
  on a Space the user sees, with a Space of its own (not borrowed), not minimized, app not hidden, alive and not
  phantom. Anything else is not requested, so the tab keeps the last picture it had while shown (or the icon).
  Selecting an inactive result starts no capture.
- **No borrowing.** A group's representative with no picture of its own does not copy a sibling's.
- **Late work.** A request records the tab's current *run* in the capture gate (an unbroken stretch of being shown).
  Both capture backends and the full-resolution Preview fetch check the gate right before calling the OS, where the
  queues cannot read the model; on delivery, on main, the pixels are filed only if the same tracked window is still in
  that run. A tab hidden, closed, replaced or minimized in between keeps its previous picture; one hidden and shown
  again is a new run, so work requested before is still refused. Exiting Ghostty removes its windows and ends every run.
- **Exceptions.** The Exceptions list is not consulted for search candidates (as for Orca tabs).

## Test scenarios

### Search candidates
- **testALiveInactiveGhosttyTabIsSearchable** — the baseline.
- **testOnlyGhosttyIsSupplemented** — another app's, or an unnamed app's, inactive tab is not.
- **testTheShownTabAndStandaloneWindowsAreNotSupplemented** — no second entry for the active tab.
- **testOnlyAVerifiedLivingMemberOfALiveGroupIsSearchable** — phantom, closing/replaced/unverified, no AX
  verification, placeholder, dead group.

### The shown tab
- **testAnOrderedInTabOnAVisibleSpaceIsShown** — including a fullscreen Space the user is on.
- **testEveryPhysicalFactIsRequired** — inactive, ordered out, borrowed Space, other Space, no Space, minimized, hidden
  app, phantom, not alive, placeholder: each alone makes a window not shown.

### The capture gate
- **testARunIsStableWhileTheTabStaysShown** — repeated reconciliation keeps the run.
- **testAHiddenThenShownTabRefusesWorkRequestedBeforeItWasHidden** — a new run per return.
- **testTabsAreGatedIndependently** · **testAWindowTheGateNeverSawHoldsNothing**

Not covered offline: `CaptureClaim` (it reads the live `Window`), the OS capture calls, and the requirement that both
backends consult it. Those need the runtime checks in the acceptance list.
