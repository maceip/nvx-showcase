# NVX Showcase

The macOS Runtime and Snapshots pages use Pie's native SwiftUI/AppKit tab strip.
Build with Xcode 26 or newer (for the macOS 26 glass APIs); the app retains its
macOS 14 deployment target and uses the strip's older-system material fallback.

```sh
cd showcase
swift test
bash assemble.sh
open dist/NVXShowcase.app
```

The first window starts with Runtime, Snapshots, and Diff. The `+` button and Command-T
add an independent Runtime tab. Command-Shift-T adds a Snapshots tab.
Command-Shift-D adds a Diff tab. The tab-list menu offers the same pages. Tab labels stay fixed when clicked or typed into. Rest the pointer over a tab to see its full title and page metadata below it. Right-click for pinning,
closing, and moving to a new window. Command-W closes the current ordinary tab;
pinned tabs stay open. Command-Shift-[ and Command-Shift-] select adjacent tabs.

Drag tabs to reorder, lift them out to make a native window, or drop them into
another NVX window's tab strip. A window with only one tab cannot lift it or use
the tab as a window-drag surface. Add a companion tab before transferring that
page elsewhere. Closing the last tab creates a fresh Runtime page.

The copied Pie native strip installs `TabStripWindowDragGuard` automatically.
Tab pixels, gaps and unused track are excluded from native window dragging even
when the strip overlaps a full-size content view's title bar. Blank title-bar
space still moves the window, and native buttons and resizing remain available.
`TabWindowDragTests` cover guard ownership and restoration; Pie's
`Tools/SmokeTest/verify-tab-window-pointer.py` exercises the assembled app with
real pointer input in the isolated macOS guest.
The [window-drag verification record](validation/tab-window-drag/README.md)
links the failing baseline and the passing assembled-app checks.

The reusable component defaults to `labelMode: .fixed`; browser-style inline
editing requires `.address`. `hoverPreview` defaults to a 0.65-second stationary
pointer delay and a 280-point rounded caption. Its `delay` and `maximumWidth` are
configurable; set it to `nil` to disable it. Each `CompactTabItem` can provide
`hoverContent: .init(title: ..., subtitle: ..., detail: ...)`. NVX supplies its
full title, page type or snapshot root, and a busy-state detail when applicable.
Moving, clicking, editing, dragging, or deactivating the window dismisses the
caption without taking focus. See the
[presentation verification record](validation/tab-presentation/README.md).

Each tab owns its controller/store and retained hosting view. A transfer moves
those objects without restarting a VM. Snapshot selection, manifest output,
sidebar visibility, and runtime output belong to the tab. Page actions live
inside the retained page, so Run/Stop, Save Snapshot, Choose, Verify, and Resume
remain available in detached windows. Closing a tab/window stops its runtime or
restore; changing selection, pinning, or moving it does not. Run directories
have unique identifiers and pruning skips active runs from other tabs.

## Reused component

`Sources/NVXShowcase/Tabs/Pie/` vendors these existing Pie files so NVX builds
independently of a sibling checkout:

- `PiCode/Features/Tabs/CompactTabStrip.swift`
- `PiCode/Features/Tabs/TabStripWindowDragGuard.swift`
- `PiCode/Features/Tabs/TabStripGeometry.swift`
- `PiCode/Features/Tabs/TabPresentation.swift`
- `PiCode/Features/Tabs/TabHoverPreview.swift`
- `PiCode/Features/Root/TitlebarControlLayout.swift`

The drag tracking, liquid glass/refraction, springs, early snap thresholds,
drop settling, tear-off morph, pin geometry, hover, focus, and close-width lock
are reused. Geometry and titlebar measurement are unchanged. The strip adapter
adds configurable refresh text/visibility, an address accessibility label,
and a compressed-title layout fix found by the 16-tab stress pass;
NVX uses fixed titles, and only Snapshots offers refresh. The drag preview comes
from the app's retained page view, with no screen-capture permission request.
Source hashes and the small component delta are recorded in
`Tabs/Pie-source.json` and `Tabs/Pie-adapter.patch` (relative to this directory).

NVX ownership and window creation live in `ShowcaseWorkspace.swift` and
`ShowcaseWindows.swift`; the root composition lives in `ContentView.swift`.
The window drag guard, label configuration and hover caption implementation are
shared with the native Pie checkout. Pie's standalone HTML implementation also
supports fixed titles, opt-in address editing and configurable hover captions.

## Validation

`swift test` exercises controller/hosting-view identity, cross-window ownership,
pin boundaries, single-tab protection, close behavior, snapshot page state,
42-tab model stress, native snap thresholds, and independent real subprocesses
with separate logs. The subprocess fixture does not boot a VM or run a payload.

Actual UI interaction is exercised in the isolated macOS CUA test VM; artifacts
are written under `validation/`. See its verification record for the exact
build, completed checks, and screenshots. The host desktop is not driven during
these checks.

## Console instruments

Runtime and Snapshots share native SwiftUI instrument faces. Amber vector
seven-segment counters show primary results, elapsed time, artifact counts and
archive size. Smaller mint displays and segmented meters show resources. There
is no terminal-rendering dependency, animated noise, or synthetic utilization.

Runtime samples the owned OpenVMM process once per second off the UI thread.
CPU is host process CPU time (100% is one core), memory is host resident bytes,
and disk I/O is cumulative host read + write bytes. These are explicitly labeled
as host VMM readings, not guest Linux utilization. Guest vCPU/RAM configuration
comes from the resolved launch arguments; unknown values remain dashes. Ended
runs retain their last sample and freeze their elapsed clock. Idle reads STANDBY.

Snapshot counters distinguish logical archive and memory-image sizes from the
filesystem's allocated blocks (which may be sparse or shared by APFS clones).
A generation whose RAM allocation is far below its logical size is labeled
sparse or shared. The artifact column lists the version-6 members in order:
manifest, device state, guest RAM, optional scratch, and optional resume claim.
CPU count, architecture, tier, restore policy, hypervisor, boot mode, integrity,
and scratch policy appear only after successful manifest verification. Guest
RAM and device-state bytes stay opaque. Changing the selected generation
invalidates old verification results.

`validation/console/` contains CUA screenshots using an explicitly labeled,
isolated UI fixture for populated states. The fixture launches no guest and
does not represent a real snapshot verification. `InstrumentTests` separately
exercises real libproc sampling, a real cold-boot VMM command, allocation
parsing, quiet process exit, and verification state. The earlier console pass
reported 36 tests, including the cold-boot and warm-restore engine tests; that
historical count does not certify the current full suite. The current tab pass
runs `TabPresentationTests` and `TabWindowDragTests` (10 focused tests).
