# Cleanup and optimization tracker

Checklist for the yina cleanup pass: correctness, runtime cost, bundle size, and XIB removal.

Status: `DONE` (committed and verified) / `BUILT` (compiles, needs runtime check) /
`TODO` (not started) / `NEEDS DECISION`

Build: `other/build_install_nightly.sh`. Installed at `/Applications/yina.app`.
Verification for this pass means **inspecting the built bundle**, not trusting the exit code
(see "Build verification note" at the bottom).

---

## Done and verified

| Item | Commit | Result |
|---|---|---|
| Drop all localizations except `Base` | `5ce37849` | 1092 files, 124,582 lines deleted. `yina/` 30 MB -> 21 MB. Fixed three latent regressions: empty `InfoPlist.strings` in Base (About would have lost its copyright), 10 subtitle-dissolve keys that only existed in `en.lproj` (would have shown as raw identifiers), 3 `SubChooseViewController` calls with no `value:` fallback. |
| Notification observer leaks and unowned-self crashes | `22e4cd6e`, `58e52e18` | `KeyRecordViewController` used-after-free on every key-binding dialog. `PlayerWindowController.addObserver(to:...)` discarded all 8 tokens so none could be unregistered. `HistoryWindowController` had 3 untracked. 6 `fadeableViews` unowned closures. |
| Restore `Base.lproj` resource build files | `82aac451` | The localization cleanup also deleted the PBXBuildFile entries for the XIBs and strings, so `Base.lproj` shipped empty and the app exited at launch. Bundle now matches the previous build again. |
| Stale project refs to 7 deleted XIBs | `82aac451` | `SubChooseViewController`, `AboutWindowController`, `FontPickerWindowController`, `OpenURLWindowController`, `ScreenshotOSDView`, `OSCToolbarSettingsSheetController`, `GuideWindowController`. All controllers are programmatic now. |
| Single app icon | `86942910` | Four legacy `AppIcon*.appiconset` PNG dirs (~3 MB, referenced by nothing) and three unused `.icon` packages deleted. Beta and Debug now select `AppIcon`. Only `AppIcon.icon` ships. |
| Native document icons | `86942910` | 22 DocIconsets, 13 MB, deleted. They had no `Contents.json` so `actool` never compiled them, and `CFBundleTypeIconFile` looks for a flat `<name>.icns`/`<name>.png` that did not exist, while `CFBundleTypeIconSystemGenerated = 0` suppressed the system icon. All 26 types now use `SystemGenerated = 1`. `doc_plugin` kept: no system equivalent. |

## Built, needs a runtime check

| Item | Commit | What to expect |
|---|---|---|
| Programmatic main and mini-player windows | `f3b55c49`, `33b2a500` | Both XIBs removed. First window access explicitly runs `loadWindow` and `windowDidLoad`; without that, mpv callbacks crashed on uninitialized video/speed-label views. User confirms video opens without crashing, but slowly. Fullscreen, PiP, and music-mode switching still need a user check. |
| Programmatic key recorder | This pass | XIB removed; existing key capture, `NSRuleEditor`, command field, and 480×155 layout retained. Isolated AppKit checks cover pending values, recording, readiness, rule selection, and controller/observer cleanup. Check the real Settings sheet. |
| Filter Save/Edit sheets | This pass | Both sheets now share programmatic AppKit content. Existing save/edit/cancel actions and persistence remain in `FilterWindowController`; name, filter string, shortcut recording, and keyboard button equivalents are preserved. Isolated checks cover layout, focus, input, button targets, and resizing. The Filters tables and preset sheet still use the reduced XIB. |
| Opening diagnostics and video-output ordering | This pass | `MediaOpening` logs opening stages, selected tracks, codecs, and view/layer geometry. Black-screen diagnostics showed `vid=no` and a fatal VO error before renderer creation despite a visible, correctly sized view. Force-window now activates after window/render-context initialization; the ordering check passes. Playback needs a user check. |
| Preserve video while switching apps/windows | This pass | Removed the `b8f7314c` background video suspension after a black-playback report. Losing focus does not mean the video is invisible; setting `vid=no` also survived paused restores and stop/new-file transitions. Focus and occlusion callbacks no longer change track selection. CPU reduction from disabling decoding is withdrawn. |
| Coalesce the `.time` UI sync | `b8f7314c` | The 25 Hz timer now skips the label/formatting/view pass when the rounded position has not moved. All five seek paths invalidate the cache so labels cannot go stale. Network cache state still refreshes because it moves while paused. |
| Long-lived mpv event consumer | `01842aae` | One draining loop instead of re-dispatching to the controller queue on every mpv wakeup. |
| Allocation cleanups | `01842aae` | Cached `NumberFormatter` in `FloatingPointByteCountFormatter`. `AdditionalInfoView` polls IOKit at most every 2s instead of 25x/sec and caches its `DateFormatter`. Subtitle dissolve resolves sRGB components once per animation instead of per frame. Stray `print()` removed from `Preference.Observer.deinit`. |
| Remote subtitle JSON hardening | `01842aae` | Five `as!` casts on network data replaced. A malformed subtitle list skips bad entries; a download response without a usable url is rejected instead of crashing. |
| Strip + LTO for release builds | `4b56d675` | `COPY_PHASE_STRIP = YES` and `ENABLE_LTO = YES` for Release/Nightly/Beta. Debug keeps symbols. `ARCHS = arm64` and `ONLY_ACTIVE_ARCH = NO` were already right, and the 47 vendored dylibs (65 MB) were already stripped. |

## Still to do

| Item | Status | Notes |
|---|---|---|
| `InspectorWindowController.xib` (1380 lines, 51 outlets) | TODO | Large but mechanical: tab view, ~50 text fields, 2 table views. |
| `FilterWindowController.xib` | TODO | Save/Edit sheets moved to code. Split view, 2 tables with cell bindings, and New Filter preset sheet remain. |
| `MainMenu.xib` (847 lines, 193 items) | TODO | Highest risk. Still `INFOPLIST_KEY_NSMainNibFile`. Localization removal cut the risk a lot. |
| Identify the 658 -> 939 MB growth | NEEDS DECISION | **No unbounded accumulator found.** Checked `info.thumbnails`, the Logger buffer, mpv observers, `CacheManager`, `NSCache`; all bounded. Leading theory is IOSurface / Metal residency from decode, not a Swift leak. Needs a `vmmap -summary` diff while idle vs after an hour. No code change will answer this. |
| Strip Sparkle's own `.lproj` (1.4 MB) | TODO | Small. yina's sources ship `Base` only; the rest comes from the Sparkle framework. Needs a build step, not a project edit. |
| SF Symbol replacements for `Icons` / `Symbols` assets | TODO | 1.3 MB + 844 KB of bitmaps. Replace with SF Symbols where an equivalent exists. |
| `libshaderc_shared` (7.2 MB) | NEEDS DECISION | Nothing in yina's source references shaders. May be droppable, but that needs an mpv-side link check, and it may be required for mpv's gpu/libplacebo path. |
| Stale `TODO` / `FIXME` markers | TODO | `MainMenuActions.swift:92` "handle stop" may be a no-op button. `WebSocketServer.swift:34` no TLS. `MPVFilter.swift:42,47` vflip/hflip. `KeyMapping.swift:16,35,47` UI logic in a model. |
| `LegacyMigration.swift` | NEEDS DECISION | Deprecated `NSUnarchiver` path for very old installs. Keep with a documented cutoff, or remove. |

---

## What to check

### 1. Finder document icons — highest priority, genuinely uncertain

All 26 document types now declare `CFBundleTypeIconSystemGenerated = 1`. That is the documented
way to ask for the system icon, but **whether macOS has a good-looking icon for a given format is
unverified**, and for the exotic ones it probably does not.

- [ ] Finder shows a **native** icon for `.mp4`, `.mp3`, `.wav`, `.m4a`, `.gif`, `.avi`
- [ ] Check `.mkv`, `.webm`, `.flv`, `.mka` specifically -- these are the ones macOS most likely
      has no built-in icon for. Note what you actually see.
- [ ] If any format shows a **generic blank page**, that is macOS having no icon for it, not a
      regression. Write down which formats those are.
- [ ] `Get Info` on a media file shows the right description ("Matroska video")
- [ ] yina is still the **Default** app for those types
- [ ] Right-click > Open With still lists yina
- [ ] yina plugin packages still show their own icon (kept deliberately)

Already done for you: Launch Services re-registered via
`lsregister -u` then `-f`. Note `-kill` no longer exists on current macOS.

### 2. Localization fallout — the app is English-only now

Deleting 53 languages means any string table that only existed outside `Base.lproj` would surface
as a raw key like `general.ok` instead of "OK".

- [ ] **Settings window: check every page and section label.** Highest risk of raw keys.
- [ ] Main menu: every item has a real title
- [ ] About window shows the copyright line
- [ ] Subtitle dissolve settings show real labels ("Fade in", "Subtitle dissolve", "Extra blur")
- [ ] Subtitle chooser buttons show "DOWNLOAD" / "CANCEL" and the selection prompt
- [ ] Playlist pane, History, Inspector, Filters, Logs all show real text
- [ ] Playlist filter pane subtitles
- [ ] Date, time and number formats look sane
- [ ] No raw identifiers anywhere, especially first thing after launch

### 3. Video visibility and backgrounding

- [ ] Play a video, switch to another app with yina still visible: video and audio continue
- [ ] Cover the window, then uncover it: video remains present
- [ ] Pause while covered, then return and resume: video remains present
- [ ] Use PiP while the main window is hidden: video continues
- [ ] Stop playback while backgrounded, then open a second file: video remains present

### 4. Time display and seeking

- [x] User confirms opening a video no longer crashes after the lifecycle fix
- [ ] Close the player window, open another video: controls initialize correctly
- [ ] Enter/exit fullscreen and PiP after opening a video
- [ ] OSC time label updates smoothly
- [ ] Set time display precision to **seconds** (not ms): the label should change once per second
- [ ] Seek with the slider, arrow keys, and `J`/`L`: labels must update immediately, not stay stale
- [ ] Seek to the very end / start
- [ ] Switch to the mini player and back
- [ ] Network stream: buffer indicator still updates while paused

### 5. Key binding dialog — the crash fix

- [ ] Settings > Key Bindings, open the key recorder, cancel, repeat **10+ times**. Must not crash.
- [ ] Record a shortcut, select an action, enter a command manually, and save it
- [ ] Open the recorder, then trigger a key-binding change elsewhere; must not crash
- [ ] History window: open, close, expand/collapse rows several times
- [ ] Toggle the settings/playlist/plugins sidebars; toolbar button highlighting stays correct
- [ ] PiP, fullscreen, sidebar toggles all update toolbar state

### 6. Subtitle chooser and online subtitles

- [ ] Open the subtitle chooser (search online for a track): real titles, no crash
- [ ] Cancel the chooser
- [ ] Download a subtitle: succeeds, and a malformed/unavailable response does not crash

### Filter sheets

- [ ] In both Video Filters and Audio Filters, save an active filter with a name and shortcut
- [ ] Edit a saved filter's name, command, and shortcut; saved values and menu shortcuts update
- [ ] Cancel Save/Edit without changing the saved filter
- [ ] Return submits and Escape cancels; Tab moves through the editable fields and shortcut recorder
- [ ] Resize both sheets; fields remain readable and buttons stay visible
- [ ] Enable/disable the saved filter; filter application is unchanged

### 7. Bundle and icons

- [ ] Dock, Launchpad, Finder, Alt-Tab all show the normal app icon
- [ ] Dark and light mode both fine
- [ ] App launches with no missing-file warnings in Console
- [ ] `lsregister -dump | grep -c yina` shows it registered
- [ ] Sparkle update check still functions (it ships its own localizations)

### 8. Memory

- [ ] Launch, leave idle 10 min, note RSS in Activity Monitor
- [ ] Play something for an hour, note RSS again
- [ ] If it grows a lot, capture `vmmap -summary` at both points and compare
      (this is what item "Identify the growth" above needs)

---

## Build verification note

`xcodebuild` reported `** BUILD SUCCEEDED **` while the bundle contained **no nibs and no strings
tables**, because the Resources phase still listed entries whose `PBXBuildFile` declarations had
been deleted. Xcode silently copied nothing and the app exited at launch with
`Unable to load nib file: MainMenu, exiting`.

**Always confirm a build by inspecting the product**, for example:

    ls /Applications/yina.app/Contents/Resources/Base.lproj   # expect 3 .nib + 4 .strings
    ls /Applications/yina.app/Contents/Resources/DefaultPreferences.plist

A green build only means the compiler was satisfied, not that the bundle is correct.
