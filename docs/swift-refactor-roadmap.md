# Swift and UI modernization roadmap

This document maps IINA's current UI implementation and identifies sensible
refactoring boundaries. It is intentionally incremental: SwiftUI should own
state-driven presentation where it helps, while AppKit remains the authority
for macOS windowing, menus, media rendering, WebKit, and system integration.

This is a roadmap, not a proposal to rewrite IINA wholesale.

## Implementation status

The first migration wave is now implemented on the `swift` branch:

- Open URL uses SwiftUI content inside an AppKit-owned window.
- Subtitle chooser uses a SwiftUI multi-selection list inside the existing OSD flow.
- Plugin permissions use SwiftUI content inside the existing AppKit list.
- Screenshot OSD uses SwiftUI content while file operations remain system adapters.
- About uses SwiftUI content and contributor layout with a narrow rich-text wrapper.
- Guide uses SwiftUI content with `WKWebView` retained as a narrow WebKit adapter.
- The obsolete Base XIBs for these surfaces, plus their nonlocalized helper XIBs,
  have been removed. Existing localized `.strings` tables remain bundled.

The next practical wave is settings-page slices, the initial/recent-files content,
font picker, logs, and history. Inspector, Filters, key recording, and OSC toolbar
customization remain dedicated higher-risk projects. The player window, rendering,
PiP, dynamic menus, WebKit runtime, and display/EDR authority remain AppKit or
system-framework led by design.

## Current implementation split

### SwiftUI-backed surfaces

These are already SwiftUI views hosted inside AppKit windows:

- Plugin store and detail views: `PluginStorePanel.swift`.
- JavaScript developer tool: `JavascriptDevTool.swift`.

They are useful reference implementations for the direction of travel:
SwiftUI content, AppKit window ownership, and explicit callbacks into the
existing application model.

### XIB-backed surfaces

After the first migration wave, the application still contains these app-owned XIBs:

- Main window: `Base.lproj/MainWindowController.xib`.
- Initial/recent-files window: `Base.lproj/InitialWindowController.xib`.
- Mini player: `Base.lproj/MiniPlayerWindowController.xib`.
- Inspector: `Base.lproj/InspectorWindowController.xib`.
- Filters: `Base.lproj/FilterWindowController.xib`.
- Font picker: `Base.lproj/FontPickerWindowController.xib`.
- Key recording: `Base.lproj/KeyRecordViewController.xib`.
- OSC toolbar settings: `Base.lproj/OSCToolbarSettingsSheetController.xib`.
- OSC toolbar drag item: `OSCToolbarDraggingItemViewController.xib`.
- Application menu: `Base.lproj/MainMenu.xib`.

IINA's contribution rules already say not to introduce new XIBs and to use
programmatic views and existing helpers for new UI. Migration work should
therefore remove XIB ownership as a surface is deliberately reworked; it
should not churn every XIB as a standalone cleanup.

## What should be refactored

Priority is based on user-facing value, dependency risk, and whether the
surface is a good SwiftUI candidate.

### Priority 1: small, low-risk XIB migrations

Completed on `swift`: Subtitle chooser, Open URL, Plugin permission view, and
Screenshot OSD. Their localized string tables remain in place.

These are good pilots for establishing an IINA SwiftUI window pattern:

1. **Subtitle chooser** — `SubChooseViewController.swift` and
   `SubChooseViewController.xib`.
   Replace the simple table and selection callbacks with a SwiftUI list,
   retaining an AppKit sheet/window adapter if needed.

2. **Open URL** — `OpenURLWindowController.swift` and
   `OpenURLWindowController.xib`.
   Keep the existing validation and text-field behavior in a small adapter;
   move form layout and button state to SwiftUI.

3. **Plugin permission view** — `PluginPermissionView.swift` and
   `PluginPermissionView.xib`.
   This is mostly static content and permission selection. Keep the plugin
   manager boundary in AppKit, but make the view state-driven.

4. **Screenshot OSD** — `ScreenshootOSDView.swift` and
   `ScreenshootOSDView.xib`.
   A small SwiftUI view is appropriate if its image/lifetime contract remains
   owned by the existing OSD controller.

### Priority 2: substantial AppKit UI migrations

5. **Settings window and pages** — `SettingsWindow.swift` and
   `SettingsPage*.swift`.
   This is already programmatic AppKit, not XIB. Migrate page content in
   slices, beginning with static preference groups. Keep the settings window,
   toolbar/sidebar selection, preference binding, and plugin page coordination
   behind an AppKit adapter until navigation and state restoration are proven.

6. **Initial/recent-files window** — `InitialWindowController.swift` and
   `InitialWindowController.xib`.
   The recent-files table is a good SwiftUI candidate. Keep custom window
   behavior and drag/open handling in the controller.

7. **About window** — `AboutWindowController.swift`,
   `AboutWindowContributorAvatarItem.swift`, and their XIBs.
   The contributor collection can become a SwiftUI `LazyVGrid` or list. The
   window lifecycle and external-link actions can remain AppKit-owned.

   Completed on `swift`; AppKit continues to own the window lifecycle and an
   `NSTextView` wrapper renders the existing rich-text resources.

8. **Log and history windows** — `LogWindowController.swift` and
   `HistoryWindowController.swift`.
   Both are programmatic AppKit surfaces using `NSTableView`/`NSOutlineView`.
   SwiftUI is viable, but preserve keyboard navigation, column sizing,
   contextual menus, copy/export behavior, and large-data performance.

### Priority 3: complex controls that need a designed replacement

9. **Inspector** — `InspectorWindowController.swift` and
   `InspectorWindowController.xib`.
   This is a high-value but high-risk migration because it combines track
   controls, a watch table, color/display information, dynamic sizing, and
   window behavior. Use a SwiftUI content view inside the existing panel first.

10. **Filters** — `FilterWindowController.swift` and
    `FilterWindowController.xib`.
    The filter lists and new-filter sheet can move to SwiftUI, but editing,
    drag/drop, validation, and mpv filter application should stay behind a
    testable model/controller boundary.

11. **Key recording** — `KeyRecordViewController.swift` and
    `KeyRecordViewController.xib`.
    `NSRuleEditor` has no direct SwiftUI equivalent. This requires designing a
    new rule editor, not mechanically translating the XIB. Keep the key event
    recorder and key-binding model independent from the replacement view.

12. **OSC toolbar customization** —
    `OSCToolbarSettingsSheetController.swift`,
    `OSCToolbarDraggingItemViewController.swift`, and related OSC views.
    SwiftUI can render the settings UI, but AppKit is still a good adapter for
    pasteboard writing, drag/drop, toolbar-item identity, and precise mouse
    interaction.

## Surfaces that should remain AppKit-led

These can host SwiftUI content, but should not be targeted for a pure SwiftUI
rewrite.

### Main player window

`MainWindowController.swift`, `MainWindow.swift`, `PlayerWindowController.swift`,
and `VideoView.swift` own fullscreen transitions, titlebar behavior, screen
selection, video placement, black-bar handling, and window lifecycle. SwiftUI
is appropriate for controls and overlays; the window and video host should
remain AppKit-owned.

### Video rendering

`ViewLayer.swift` and `MPVController.swift` contain the Metal path and the
OpenGL compatibility path. `CAMetalLayer`, `CAOpenGLLayer`, CGL context
locking, and libmpv render callbacks cannot be replaced by SwiftUI. The
modernization work here is renderer/API isolation and eventual OpenGL removal,
not a SwiftUI conversion.

### Picture in Picture

PIP is **not currently an XIB surface**. `MainWindowController` creates a
`VideoPIPViewController`, which subclasses the system `PIPViewController` from
the private `PIP.framework`. SwiftUI can provide the PiP content, but the PiP
window, delegate callbacks, lifecycle, and framework integration remain
AppKit/system-framework responsibilities.

### Menus and commands

`MainMenu.xib` and `MenuController.swift` contain a large dynamic menu graph:
track menus, plugin menus, key-binding replacement, validation, and runtime
updates. SwiftUI `Commands` may be useful for isolated commands, but it is not
a drop-in replacement for the current `NSMenu` ownership model. Modernize in
place, or introduce narrow command builders, rather than converting the whole
menu system first.

### Plugin web surfaces

`PluginOverlayView.swift`, `PluginSidebarView.swift`,
`PluginStandaloneWindow.swift`, and `SettingsPagePlugin.swift` use `WKWebView`
and JavaScript message handlers. `WKWebView` is not obsolete, and SwiftUI
cannot replace the web runtime. The useful refactor is to isolate the WebKit
host and JavaScript bridge from layout and plugin state.

### System display and PiP integration

`Display.swift` and `VideoView.swift` use CoreDisplay information for display
color/EDR behavior. These calls belong in a narrow AppKit/system adapter even
if their consumers become SwiftUI views.

## Legacy AppKit controls to target opportunistically

These are not necessarily XIB migrations, but they increase maintenance cost:

- `NSButtonCell` subclasses and direct `button.cell` casts in
  `GuideWindowController.swift`, `SideBar.swift`, and settings code.
- `NSRuleEditor` in `KeyRecordViewController.swift`.
- Delegate-heavy `NSTableView` and `NSOutlineView` surfaces in settings,
  inspector, history, logs, playlist, chapters, and track selection.
- `NSWindowController`/`windowNibName` ownership in the remaining XIB-backed
  controllers.
- Objective-C boundaries in `FFmpegController.m`, `FixedFontManager.m`, and
  `iina-Bridging-Header.h`. These are lower priority unless a related feature
  already needs the boundary changed.

## Recommended architecture

Use three layers rather than choosing one UI framework globally:

```text
Feature model / state
        |
        +-- SwiftUI content views for presentation and local interaction
        |
        +-- AppKit adapters for windows, menus, tables, drag/drop, WebKit,
        |   PiP, display services, and renderer hosting
        |
        +-- PlayerCore / MPVController / system services
```

The adapters should expose intent-based APIs such as `open(url:)`,
`selectTrack(_:)`, `applyFilter(_:)`, and `setSidebarPage(_:)` rather than
letting SwiftUI views reach directly into mpv or window internals.

## Migration sequence

1. Establish one reusable AppKit-to-SwiftUI window/content adapter.
2. Migrate `SubChooseViewController` or `OpenURLWindowController` as the
   reference implementation.
3. Add behavior tests or focused smoke tests before migrating table-heavy
   surfaces.
4. Migrate simple static/content views: plugin permission, screenshot OSD,
   About, and recent files.
5. Migrate settings pages in independent slices; keep the settings window
   AppKit-owned initially.
6. Migrate inspector, filters, history, and logs only after preserving dense
   table behavior and keyboard workflows.
7. Treat `NSRuleEditor`, OSC drag/drop, menus, WebKit, PiP, and rendering as
   dedicated projects, not incidental parts of a XIB cleanup.
8. Remove each XIB only after the replacement has equivalent localization,
   accessibility, keyboard, resizing, and state-restoration behavior.

## Definition of done for each surface

- No new XIB is introduced.
- The replacement has an explicit state/model boundary.
- Window lifecycle remains correct across reopen, close, and app termination.
- Keyboard navigation, focus, accessibility, localization, and Reduce Motion
  behavior are preserved.
- Dense tables retain selection, sorting/sizing, context menus, copy/export,
  and drag/drop behavior where applicable.
- mpv access remains through the existing `PlayerCore`/`MPVController`
  architecture.
- The relevant live surface is manually exercised in the installed build,
  not only compiled or snapshot-tested.

## Suggested first three projects

1. **Open URL → SwiftUI content with AppKit window adapter** — small scope,
   clear validation behavior, and a reusable pattern.
2. **Subtitle chooser → SwiftUI list/sheet** — simple table migration with
   immediate user-visible value.
3. **Settings page slice → SwiftUI page inside existing settings window** —
   establishes how preference binding, navigation, and AppKit presentation
   should coexist.

Do not begin with PIP, the main window, OpenGL removal, or the JavaScriptCore
bridge. They are important modernization targets, but they are framework or
runtime projects rather than ordinary SwiftUI migrations.
