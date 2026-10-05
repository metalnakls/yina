# Cleanup and optimization tracker

Working checklist for the yina cleanup pass: correctness fixes, runtime cost,
bundle size, and XIB removal. Each item is a separate local commit.

Status legend: `TODO` / `WIP` / `DONE` / `DECLINED`

## Committed

| # | Item | Commit | Notes |
|---|---|---|---|
| 1 | Drop all localizations except `Base` | `4240fd6f` | 1092 files, 124582 lines deleted. `yina/` 30 MB -> 21 MB. Fixed three latent regressions: empty `InfoPlist.strings`, 10 subtitle-dissolve keys that only existed in `en.lproj`, 3 `SubChooseViewController` calls with no `value:` fallback. |
| 2 | Notification observer leaks / unowned-self crashes | `22e4cd6e` | `KeyRecordViewController` use-after-free on every key-binding dialog. `PlayerWindowController.addObserver(to:...)` discarded all 8 tokens. `HistoryWindowController` 3 untracked. 6 `fadeableViews` unowned closures. |

## Progress

`yina/` source tree: **30 MB -> 6.1 MB** across three commits. All committed
work is local; nothing has been pushed.

## Bundle size

| # | Item | Status | Notes |
|---|---|---|---|
| 3 | Legacy `AppIcon*.appiconset` PNG dirs | DONE | 4 dirs, ~3 MB, referenced by nothing. Superseded by the `.icon` package. |
| 4 | `AppIconBeta` / `AppIconDebug` / `AppIconNightly` `.icon` packages | DONE | ~68 KB total. All four configs now use `AppIcon`; beta/debug are ephemeral and share the normal icon. |
| 5 | `DocIcons` -> native macOS document icons | DONE | 13 MB, 22 iconsets, no `Contents.json` so `actool` never compiled them and `CFBundleTypeIconFile` cannot resolve them. Committed `86942910`. All 26 entries now use `CFBundleTypeIconSystemGenerated = 1`; `CFBundleTypeIconFile` removed. `doc_plugin.iconset` kept (no system equivalent for a yina plugin package). 13 MB -> 476 KB. |
| 6 | Strip Sparkle / upstream `.lproj` from bundle | TODO | Agent measured 32 `.lproj` dirs, ~6.4 MB, inside the built bundle. yina's own sources now ship `Base` only. Needs a build-time strip step. |
| 7 | Audit remaining `Icons` / `Symbols` assets for SF Symbol replacements | TODO | `Icons` 1.3 MB, `Symbols` 844 KB. Replace bitmap toolbar icons with SF Symbols where an equivalent exists. |
| 8 | Release build settings (strip, LTO, `ONLY_ACTIVE_ARCH`) | TODO | Unverified. Agent could not run a Release build. |

## CPU / RAM

| # | Item | Status | Notes |
|---|---|---|---|
| 9 | Decouple video decode/render from backgrounding | TODO | Agent's top finding. `pauseWhenInactive` defaults to `false`, so a backgrounded window keeps decoding HEVC and keeps the CADisplayLink at 60-120 Hz. User chose: keep background audio, pause only video decode/render. |
| 10 | Stop display link on occlusion | TODO | `windowDidChangeOcclusionState` early-returns unless the window became visible; it never stops the link. Pairs with #9. |
| 11 | Coalesce `syncUITimer` | TODO | Runs at 25 Hz doing ~4 mpv reads + a UserDefaults read + a main-queue hop per tick, serialized on mpv's dispatch lock. Only re-render when the displayed value actually changes. |
| 12 | `readEvents()` re-dispatch churn | TODO | `MPVController` re-enters `queue.async` on every mpv wakeup instead of using one long-lived consumer. |
| 13 | Cache `NumberFormatter` in `FloatingPointByteCountFormatter` | TODO | Allocated per call. Cold path, low impact. |
| 14 | Throttle `AdditionalInfoView.update()` | TODO | `PowerSource.getList()` does IOKit round-trips from the 25 Hz timer. Cold path, low impact. |
| 15 | Reduce `SubtitleDissolve` per-frame cost | TODO | 60 fps timer rebuilds `mpvColorString` per style colour per frame. |
| 16 | Remove stray `print()` in `Preference.Observer.deinit` | TODO | Ships in release builds. |
| 17 | Identify the 658 -> 939 MB growth | TODO | No unbounded accumulator found. Leading theory is IOSurface / Metal residency from decode, not a Swift leak. Needs a runtime `vmmap -summary` diff. |

## Robustness

| # | Item | Status | Notes |
|---|---|---|---|
| 18 | Replace 8 `as!` casts on remote subtitle JSON | TODO | `AssrtSubtitle.swift` 221-278. Malformed API response crashes the app. |
| 19 | Resolve stale `TODO` / `FIXME` markers | TODO | `MainMenuActions.swift:92` "handle stop" may be a no-op button. `WebSocketServer.swift:34` no TLS. `MPVFilter.swift:42,47` vflip/hflip. `KeyMapping.swift:16,35,47` UI logic in a model. |
| 20 | Decide on `LegacyMigration.swift` | TODO | Deprecated `NSUnarchiver` path. Keep with a documented cutoff, or remove. |

## XIB removal

Ordered easiest first. Each is independent.

| # | XIB | Status | Lines | Outlets | Notes |
|---|---|---|---|---|---|
| 21 | `MainWindowController.xib` | TODO | 68 | 2 | Trivial: window + PiP overlay view. |
| 22 | `MiniPlayerWindowController.xib` | TODO | 33 | 1 | Trivial: empty content view. |
| 23 | `KeyRecordViewController.xib` | TODO | 129 | 4 | Small: 4 subviews + Auto Layout. |
| 24 | `InspectorWindowController.xib` | TODO | 1380 | 51 | Large but mechanical: tab view + ~50 text fields + 2 table views. |
| 25 | `FilterWindowController.xib` | TODO | 881 | 23 | Split view + 2 tables + 3 embedded sheets. |
| 26 | `MainMenu.xib` | TODO | 847 | 193 items | Highest risk. Was the app main nib (`INFOPLIST_KEY_NSMainNibFile`). Localization removal cut the risk substantially. |
| 27 | Stale pbxproj refs to 7 already-deleted XIBs | TODO | - | - | `SubChooseViewController`, `AboutWindowController`, `FontPickerWindowController`, `OpenURLWindowController`, `ScreenshotOSDView`, `OSCToolbarSettingsSheetController`, `GuideWindowController`. Builds only because Xcode tolerates missing files. |

## Test checklist

Run after the icon/plist changes (#5) and again at the end of the XIB work.

### Finder document icons
- [ ] Finder shows a **native** icon for `.mkv`, `.mp4`, `.avi`, `.webm`, `.flv`
- [ ] Finder shows a native icon for `.mp3`, `.flac`, `.wav`, `.m4a`, `.aac`, `.ogg`
- [ ] Native icon for `.gif`, `.ts`, `.qt`, `.rm`, `.asf`, `.wmv`, `.3gp`
- [ ] Icons are **not** generic blank document icons
- [ ] `Get Info` on a media file shows the correct `CFBundleTypeName` ("Matroska video" etc.)
- [ ] yina is still the **Default** app for those types
- [ ] **Uninstall/reinstall check**: `lsregister -kill -r /Applications/yina.app`, then relaunch Finder
- [ ] Right-click > Open With still lists yina

### App icon
- [ ] Dock icon is the normal `AppIcon` (not beta/debug/nightly)
- [ ] Finder app icon correct
- [ ] Icon renders correctly on Dock, Launchpad, Finder, Alt-Tab
- [ ] Dark and light mode both fine
- [ ] Beta build shows the **normal** icon, intentionally

### Localization fallout
- [ ] No raw identifiers anywhere in the UI (e.g. literal `general.ok` instead of "OK")
- [ ] About window shows the copyright line
- [ ] Subtitle dissolve settings labels render ("Fade in", "Subtitle dissolve", ...)
- [ ] Subtitle chooser buttons render ("DOWNLOAD", "CANCEL", selection prompt)
- [ ] Settings window: every page/section label has real text
- [ ] Main menu: every item has a real title
- [ ] Playlist pane, history window, inspector, filters, logs all show real text
- [ ] Date/time and number formats are sane

### Correctness (#2)
- [ ] Open Settings > Key Bindings, add a binding, cancel, repeat 10x - **must not crash**
- [ ] Edit a key binding after opening/closing the dialog several times
- [ ] History window opens/closes repeatedly, expand/collapse rows
- [ ] Settings sidebar toggling updates toolbar button states
- [ ] PiP, fullscreen, and sidebar toggles update toolbar highlighting

### Startup / bundle
- [ ] App launches normally
- [ ] No missing-file warnings in Console at launch
- [ ] Bundle size dropped (expect roughly 133 MB -> ~110 MB)
- [ ] Sparkle update check still works (it ships its own `.lproj`)
