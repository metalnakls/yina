# Swift and UI modernization roadmap

This document maps YINA's current UI implementation and identifies sensible
refactoring boundaries. It is intentionally incremental: SwiftUI should own
state-driven presentation where it helps, while AppKit remains the authority
for macOS windowing, menus, media rendering, WebKit, and system integration.

This is a roadmap, not a proposal to rewrite YINA wholesale.

## Implementation status

The first migration wave is now implemented on the `meh` branch:

- Open URL uses SwiftUI content inside an AppKit-owned window.
- Subtitle chooser uses a SwiftUI multi-selection list inside the existing OSD flow.
- Plugin permissions use SwiftUI content inside the existing AppKit list.
- Screenshot OSD uses SwiftUI content while file operations remain system adapters.
- About uses SwiftUI content and contributor layout with a narrow rich-text wrapper.
- Guide uses SwiftUI content with `WKWebView` retained as a narrow WebKit adapter.
- Font picker uses SwiftUI lists, search, preview, and manual entry inside an
  AppKit-owned sheet/window.
- OSC toolbar customization is now fully programmatic AppKit. Its drag/drop,
  pasteboard, item identity, and sheet lifecycle remain AppKit-owned while the
  obsolete settings and available-item XIBs have been removed.
- The Video page's four independent toggle rows (Live Text, dedicated GPU, ICC
  profile, and HDR support) are now SwiftUI-backed. The settings window,
  page/section/list layout, search index, and remaining input, selection, and
  expandable tone-mapping rows remain AppKit-owned.
- The Subtitles page's independent window-scaling, letterbox-placement, and
  automatic-online-search rows now use the same SwiftUI toggle adapter.
  Existing preference keys, descriptions, search registration, and playback
  option observers remain in place. The surrounding page and richer controls
  remain AppKit-owned.
- The programmatic welcome window now uses reusable SwiftUI content for Recent
  rows. AppKit continues to own its window, scroll view, `NSTableView`
  selection, keyboard navigation, availability checks, and open routing.
- The obsolete Base XIBs for these surfaces, plus their nonlocalized helper XIBs,
  have been removed. Existing localized `.strings` tables remain bundled.
- Main and mini-player windows are now constructed in AppKit code, including
  the main window's PiP overlay. Their shared controller explicitly loads and
  initializes the window on first access, preserving the old lazy lifecycle.
  The XIBs are removed; playback/fullscreen/PiP/music-mode runtime checks remain.
- Key recording now builds its existing AppKit content programmatically. Key
  capture, `NSRuleEditor`, command entry, and sheet ownership remain unchanged.
  The recorder delegate is weak so closing the sheet releases the controller.
- Filter Save/Edit sheets now use shared programmatic AppKit content. The
  existing controller owns save/edit/cancel, validation, persistence, and filter
  application. The filter lists and New Filter preset sheet are also now
  programmatic AppKit; the Filters XIB is removed. Initial saved-filter state
  is synchronized before displaying rows, and table edits explicitly commit
  through the existing validation/application path.

The next practical wave is additional settings-page slices, logs, and history.
Inspector now also uses programmatic AppKit. The player window, rendering,
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

### XIB removal complete

All app-owned XIBs are removed. `ApplicationMain.swift` explicitly owns the app
delegate, installs menus before `NSApplicationMain`, and preserves normal launch
events and argument handling. `ApplicationMenus.swift` constructs the former
main and Dock menu trees; `MenuController` still owns dynamic playback menus.
Services, Window, and Help menus are registered through public AppKit APIs.
Open Recent uses native `NSDocumentController` storage with an explicit adapter.
Sparkle starts after preference migration and feed preparation, using its
[programmatic setup](https://sparkle-project.org/documentation/api-reference/Classes/SPUStandardUpdaterController.html).
Isolated checks cover all 193 menu entries, 116 controller connections,
shortcuts/actions, recent-list operations, and the production entry point.
Manual app launch and playback-menu checks remain in the cleanup tracker.

YINA's contribution rules already say not to introduce new XIBs and to use
programmatic views and existing helpers for new UI. Migration work should
therefore remove XIB ownership as a surface is deliberately reworked; it
should not churn every XIB as a standalone cleanup.

The obsolete `Base.lproj/InitialWindowController.xib` and its localized
`.strings` siblings were removed from the project on `meh`. The welcome
window is constructed programmatically and is not part of the XIB inventory
above; it remains the active home for the Recents implementation.

## What should be refactored

Priority is based on user-facing value, dependency risk, and whether the
surface is a good SwiftUI candidate.

### Completed reference migrations

Subtitle chooser, Open URL, Plugin permission view, and Screenshot OSD are
implemented on `meh` with SwiftUI content and AppKit lifecycle adapters. Their
obsolete XIBs are removed; localized string tables remain bundled. Use these
controllers as reference implementations rather than scheduling another
migration of the same surfaces.

### Priority 2: substantial AppKit UI migrations

5. **Settings window and pages** — `SettingsWindow.swift` and
   `SettingsPage*.swift`.
   This is already programmatic AppKit, not XIB. Migrate page content in
   slices, beginning with static preference groups. Keep the settings window,
   toolbar/sidebar selection, preference binding, and plugin page coordination
   behind an AppKit adapter until navigation and state restoration are proven.

6. **Initial/recent-files window** — `InitialWindowController.swift`.
   This window is already programmatic. Recent-row presentation is now
   SwiftUI-backed; `NSTableView` deliberately retains selection, focus,
   keyboard navigation, and scrolling while the controller retains custom
   window behavior, availability checks, drag handling, and open routing.

7. **About window** — completed on `meh`.
   `AboutWindowController.swift` hosts SwiftUI contributor content. AppKit owns
   the window lifecycle and an `NSTextView` wrapper renders rich-text resources.

8. **Log and history windows** — `LogWindowController.swift` and
   `HistoryWindowController.swift`.
   Both are programmatic AppKit surfaces using `NSTableView`/`NSOutlineView`.
   SwiftUI is viable, but preserve keyboard navigation, column sizing,
   contextual menus, copy/export behavior, and large-data performance.

The font picker is also completed on `meh`: SwiftUI owns its search, family
and typeface selection, preview, manual entry, and actions. AppKit continues to
own font enumeration and sheet/window lifecycle, and the existing localized
string tables remain bundled.

### Priority 3: complex controls that need a designed replacement

9. **Inspector** — `InspectorWindowController.swift` and `InspectorWindowViews.swift`.
   The XIB is removed. Programmatic AppKit retains the utility panel, toolbar
   tabs, 45 detail fields, track popup, watch table, and frame persistence key.
   Playback queries and timer/listener ownership remain in the controller.
   Long watch lists scroll the status page so table rows stay below the header.
   Isolated layout/action checks pass; manual playback checks are in the tracker.

10. **Filters** — `FilterWindowController.swift`, `FilterWindowViews.swift`,
    `NewFilterSheetViewController.swift`, and `FilterShortcutSheet.swift`.
    All content is now programmatic AppKit. Isolated checks cover table editing,
    saved row bindings/reuse, resizing, and audio/video preset selection.
    Manual filter application and sheet checks remain in the cleanup tracker.
    A later SwiftUI migration should retain the validation/mpv boundary.

11. **Key recording** — `KeyRecordViewController.swift` and
    its programmatic AppKit view.
    The XIB has been removed while retaining `NSRuleEditor` and key capture.
    A later SwiftUI replacement needs a designed rule editor because there is
    no direct SwiftUI equivalent. Keep the key event recorder and key-binding
    model independent from that replacement view.

12. **OSC toolbar customization** — completed on `meh`.
    `OSCToolbarSettingsSheetController.swift` and its related OSC views now
    construct the sheet programmatically. AppKit deliberately remains the
    owner of pasteboard writing, drag/drop, toolbar-item identity, precise
    mouse interaction, and sheet lifecycle. Existing localized `.strings`
    tables remain bundled.

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

`ApplicationMenus.swift` and `MenuController.swift` own the menu graph:
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
  `yina-Bridging-Header.h`. These are lower priority unless a related feature
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

1. Migrate additional static settings groups using the existing hosting adapters.
2. Establish large-data behavior coverage before changing log/history tables.
3. Move log/history presentation in slices while preserving export, filtering,
   selection, and keyboard navigation.
4. Treat Inspector, Filters, and key recording as separate replacement projects.
5. Keep player windows, rendering, menus, PiP, and WebKit behind their existing
   system adapters.

## Suggested next projects

1. **Remaining settings slices** — migrate independent preference groups while
   retaining the established AppKit window and binding adapters.
2. **Log and history presentation** — preserve bounded storage, large-data
   performance, filtering, keyboard navigation, and full file export.
3. **Inspector SwiftUI content** — the AppKit XIB replacement is complete;
   consider a narrow hosted slice after manual playback and update-lifecycle
   checks confirm the replacement.

The first-wave Open URL, subtitle chooser, About, and welcome migrations are
complete. PiP, player windows, dynamic menus, and the JavaScript runtime remain
system adapters. All standard host configurations now enable the Metal path;
OpenGL source remains isolated behind the renderer compilation condition until
live renderer parity has been verified across playback, PiP, and displays.
