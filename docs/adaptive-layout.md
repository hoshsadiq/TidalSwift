# Adaptive layout, and the iPad and iPhone targets

Two decisions from 2026-10-14:

1. The window layout changes shape at different widths, so the app works on a small screen instead of stopping at a floor.
2. Real iPad and iPhone targets come later, not just phone-shaped layouts in a Mac window.

Both are served by the same rules, which is why the layout work goes first.

## The platform facts that shape this

macOS has no size classes and no breakpoint API. `horizontalSizeClass` and `verticalSizeClass` are always `.regular`, at every OS version, and `NavigationSplitView` never collapses a column on the Mac the way it does on iPad. Apple's adaptive machinery is written for iPadOS. Everything here is therefore app logic reacting to a measured width, which is the approach chosen.

The installed navigation and layout skills show `horizontalSizeClass == .regular` branching for split views. On this target that branch never fires, so those snippets are not usable. The Mac fact wins.

Available at the current macOS 14 target, so nothing here needs a deployment rise:

| mechanism | availability | what it is for here |
|---|---|---|
| `onGeometryChange(for:of:action:)` | back-deployed to 13 | reading the window width without wrapping the view |
| `AnyLayout` + `HStackLayout`/`VStackLayout` | 13 | swapping an arrangement while keeping view identity, so it can animate |
| `Layout` protocol | 13 | only if an arrangement cannot be built from stacks or grids |
| `ViewThatFits` | 13 | local choices only, see below |
| `LazyVGrid` + `GridItem(.adaptive)` | older | card grids that reflow |
| `NavigationSplitView(columnVisibility:)` | 13 | hiding the sidebar from the app |
| `Inspector`, `containerRelativeFrame` | 14 | a trailing panel, sizes relative to a container |
| `windowResizability`, `defaultSize` | 13 | declaring the minimum and the opening size |

Not reachable without a target rise: `ArrangementView` (27.1), `windowResizeAnchor` (26), the Liquid Glass APIs (26).

`ViewThatFits` decides on each candidate's *ideal* size, which does not represent what a flexible view such as a `List`, `ScrollView` or adaptive grid actually needs. It is reliable for a row of controls or a header, not for a whole screen, and it does not animate between candidates. `AnyLayout` is the tool for a swap that should animate.

Apple's own rule for resizing, from the HIG, is that a compact layout should be deferred for as long as possible and that tertiary columns should be hidden before anything else. The modes below follow that: the first thing that goes is the sidebar, not the content.

## The breakpoint system

One type owns the modes, one measured width feeds it, and every screen says what it looks like in each mode. Nothing reads the window width directly.

```
LayoutMode
  compact   width < 800     sidebar hidden, bar compact, dense tables become cards
  regular   800 .. 1140     sidebar shown, full bar, tables with fewer columns
  wide      >= 1140         as regular, plus room to dock the queue
```

The numbers are the measured floors, not round guesses:

- 800 is the sidebar's 220 plus the detail column's 580, where 580 is what the densest table needs.
- The bar has its own threshold at 900, already in the code (`PlayerInfoView.compactWidthThreshold`), for tightening the transport controls. That stays a bar concern rather than a mode.
- 1140 is 840 plus the queue panel's 300. It only matters while the queue is open, and the panel could float instead (see the first small win).

Where it lives: a `LayoutMode` type with the thresholds, the mode for a width, and the mode's rules, in `TidalSwiftLib` so it can be tested and so an iPad or iPhone layout can reuse it. The window measures once and injects the mode through the environment. Screens read the mode, never the width.

A screen's shape belongs with the screen: one property or small view per mode, not a scattering of width checks. Where a swap is a simple arrangement change, `AnyLayout` keeps identity and animates it.

## What has to adapt

Measured today, in the order that a narrow window fights back:

| area | what is fixed today | what adapts |
|---|---|---|
| Player bar | about 710 points of rigid content before the title: transport, volume, four icons, badge, ten gaps | at compact, move the volume slider, the badge and the disabled AirPlay button into an overflow menu, following the tiering the miniplayer already uses |
| Queue panel | a 300 point reserve in the layout, so the window minimum becomes 1140 while it is open | drop the reserve and let it float, which it already knows how to do |
| View-all table | 336 points of fixed columns leaves about 76 per text column | hide BPM and KEY below a width, then collapse the row to a card |
| Collection tracks table | 398 points of fixed columns | same, dropping DATE ADDED after BPM |
| Sidebar | a 220 point floor | lower it and let the rows truncate, which they already do |
| Toolbar | the search field pinned at 200 points | shorten the cap when narrow, which the constraint already allows |
| Two fixed three-column grids | `CompactTrackList` and `PageLinkGrid` never reflow | measured column count like the View-all page, or adaptive columns |
| Album, playlist and artist headers | a 100 point cover beside trailing counts in one row | hide the trailing counts and dates below a width |
| Measured grids | `max(2, ...)` forces two columns at the narrow end | allow one |

## Order of work

Wave 1, the foundation: `LayoutMode` in the library with its tests, the window measuring once, the mode in the environment, and the six small wins above that are useful on their own. Each small win is independently verifiable, so they can land as they are ready.

Wave 2, the shell: the sidebar hides per mode with an animation, the bar gains its compact form, the queue stops reserving space.

Wave 3, the screens: tables become cards, the fixed grids adapt, the headers drop their trailing column, and each screen states its shape per mode.

Every wave is verified the way layout has to be, given the app has no test host: a throw-away `NSHostingView` harness that lays out the real composition at the mode's widths and reports what it measures. That is how the scrolling line bug was found after three passes of reasoning missed it.

## The iPad and iPhone targets

The reconnaissance in `.omo/evidence/` (artifacts `platform.md` and `context.md` from 2026-10-14) gives these facts.

The library is already ready. `TidalSwiftLib/Package.swift` declares `[.macOS(.v14), .iOS(.v16)]`, and no file in it imports AppKit, UIKit or Cocoa. Its one platform assumption is a file location: the offline library resolves through `.musicDirectory`, which on iOS lands inside the app container rather than `~/Music`. That is the behaviour we want, and it needs verifying rather than changing.

The app is where the work is. 119 files, of which about 15 import AppKit and 18 touch an AppKit symbol: window controllers for the auxiliary windows, the application lifecycle and the whole menu tree, the LaunchServices registration for the `tidal://` scheme, local key monitors, the toolbar search-field bridging, `NSImage` and `NSColor` use, the Touch Bar, and two files that already have iOS fallbacks (the pasteboard and the link sounds).

The project skeleton already anticipates iPad: `IPHONEOS_DEPLOYMENT_TARGET: "17"` and `TARGETED_DEVICE_FAMILY: "6"` are set, while `SUPPORTED_PLATFORMS: macosx` is not. There is a prior note in `docs/ios-search-field.md` about the search field on iPad.

Workstreams, in the order they depend on each other:

1. Library verification, small: that the container paths behave, that token persistence survives, and that the test suite runs for an iOS destination.
2. Shared UI, large: the shell and the screens live in the app target today. Either the reusable views move into a shared module, or every AppKit import gains a paired iOS branch.
3. Platform layer, medium: an audio session with a playback category and interruption handling, which the app does not have at all today, the background audio mode, a `UIImage` branch in the Now Playing builder, `VideoPlayer` instead of `AVPlayerView`, and an iOS answer for the miniplayer, the menu commands, the Settings window and the Touch Bar.
4. Project plumbing, medium: a second target or a multi-platform target in `project.yml`, a scheme, the mise tasks that hardcode one macOS product, a CI job with a simulator, and a signing and archive path, since iOS cannot ship unsigned and everything today is unsigned by design.
5. Login, unknown: the desktop-client login registers and needs the `tidal://` scheme, and the `cuk` claim it produces is what unlocks the hi-res HLS route. Whether iOS can be handed that scheme while the TIDAL iOS app also claims it, and whether the same flow still yields the claim, cannot be answered by reading. Both need a live probe on a device or simulator.

That fifth one is a risk rather than a task: if the desktop login does not survive on iOS, the hi-res route does not either, and the device-code flow returns a device-client token that is served lower tiers. Worth measuring before the shared UI work starts, since it decides how much of the app the port is worth.

## What needs a decision

The mode thresholds, in particular whether 1140 is the right wide mark or whether the queue should simply float at every width, in which case there are two modes rather than three.

Whether the reusable views move into a shared module before the iOS work, or the app keeps one source tree with paired platform branches.

Whether the iPad and iPhone targets are worth it given the login question above, which is answerable with a probe.
