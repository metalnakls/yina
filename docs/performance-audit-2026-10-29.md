# Performance audit — 29 October 2026

Baseline: YINA **2.36**, commit `d1cadce7bfbf861beb1440619f5759485c81b853`.

The reported beachball happens when **pressing Play after pausing**, rather than reopening a file or waking the Mac. The strongest confirmed exposure is that the Play action and subsequent pause-state callback synchronously wait on mpv from the UI thread. This audit did **not** reproduce the beachball or establish which dependency stalled during it.

The prioritized findings and measurements below record the **pre-change baseline**. The implementation appendix at the end records subsequent code changes and local verification. It does not establish that the reported beachball is fixed; the final signed install is verified below, while the user's original stall and live SMB workload remain unverified.

## Coverage and evidence

The structural scan covered **243 owned source files, 71,068 lines**, across `yina`, `OpenInYINA`, `yina-cli`, `yina-plugin`, and the browser extensions. This includes generated option definitions; it is not a claim that every line received equal review. Targeted call-path review covered playback controls, pause/resume, Metal rendering, previews, Live Text, history, file opening and dragging, welcome artwork, settings, Inspector, menus, subtitles, shared shows, caches, logging, plugins, and helper processes. The pinned mpv client/render/audio implementations were inspected where they affect those paths.

Evidence labels used below:

- **Confirmed structure:** a blocking call, repeated operation, or retained owner is visible in the baseline source. Runtime cost remains workload dependent.
- **Measured:** observed in the isolated probe described below.
- **Hypothesis:** a plausible explanation or optimization requiring a trace or benchmark before changing behavior.

No YINA process was available during the initial process check. A read of the preceding six hours of `PlaybackResume` logging produced no stage records. There is therefore no current main-thread stack from the user's hang. Real SMB behavior remains untested, as requested. No personal media was opened and no desktop control was used for this audit.

### Isolated pause/resume probe

An instrumented copy of [the existing AVFoundation smoke test](../other/tests/mpv-avfoundation-smoke.c) played a generated, silent, 20-second WAV through the bundled libmpv with `ao=avfoundation`, `vo=null`, `mute=yes`, configuration loading disabled, and scripts disabled. It completed **30 pause/resume cycles**, including **two seven-second pauses**, followed by EOF, reopen, and stop checks. Audio position advanced after each unpause.

| Synchronous call | Median | 95th percentile* | Maximum |
| --- | ---: | ---: | ---: |
| Read `eof-reached` | 0.010 ms | 0.128 ms | 1.523 ms |
| Set `pause=false` | 0.506 ms | 5.546 ms | 7.567 ms |

\* Nearest-rank percentile across 30 samples; too few samples to characterize a rare hang.

The probe library and installed library share Mach-O UUID `17B9BBA3-AD83-35B1-9222-FEFED023D29E` and identical 1,283,156-byte executable `__text` sections, SHA-256 `d851fdb3f4c377ac04e2d2ea04e875d752c3be1b3740bb290f9eee793de69b52`. Their whole-file hashes differ, so this is executable-code correspondence, not byte-for-byte bundle identity.

Temporary reproduction artifacts are `/tmp/yina-resume-audit/probe.c`, `silence.wav`, `probe`, and `result.log`. The instrumentation times `eof-reached` and `pause=false` separately with a monotonic clock. Temporary files are not release assets and may disappear.

**Limits:** this exercised audio only, with no app UI, video renderer, preview worker, Live Text, SMB, or induced device changes. It does not show that the application hang is fixed, nor exclude an intermittent AVFoundation race. YINA can also select Core Audio through its audio-driver preference; the probe explicitly selected AVFoundation.

## Prioritized findings

### 1. Stop making the UI wait for the playback engine

**Priority: first implementation target. Evidence: confirmed structure; relationship to the reported stall is plausible but unproven.**

The [Play button](../yina/PlayerWindowController.swift#L742) calls [PlayerCore.resume](../yina/PlayerCore.swift#L898) directly. Resume activates the display link, synchronously reads `eof-reached`, may synchronously seek at EOF, and synchronously sets `pause=false`. [MPVController's property wrappers](../yina/MPVController.swift#L914) call blocking libmpv APIs. The pinned `player/client.c` implements property changes through `run_locked`; synchronous commands can also wait for completion.

The next [pause-state callback](../yina/PlayerCore.swift#L2519) runs UI time synchronization and timer setup. Timer setup can perform another immediate synchronization when the timer was stopped. Moving only the initial unpause call would leave these subsequent UI waits intact.

The same exposure appears during ordinary playback: [syncUI(.time)](../yina/PlayerCore.swift#L2975) calls `syncPosition()` **before** checking whether the displayed time bucket changed. Thus the existing label coalescing does not eliminate engine queries. [Intervals](../yina/AppData.swift#L14) are 10 Hz normally or 25 Hz at higher precision while the UI timer is needed; paused playback normally stops this timer.

**Change:** establish one ordered, asynchronous control path with reply/error handling and lifecycle generations. Observe or asynchronously refresh engine state, then publish an immutable UI snapshot. Use cached state for labels, menus, settings, shared-progress sampling, and Inspector. Keep AppKit/display-link work on the main thread. Preserve EOF restart, rapid Play/Pause ordering, seeking, shutdown, and stale-event rejection. Do not move every call independently onto unrelated global queues or put blocking client calls on the render queue.

**Verify:** stress rapid toggles, long pauses, EOF, seeking, file replacement, device changes, and shutdown. Capture both time from click to return and click to first advancing playback position/frame. A responsive button alone must not conceal a stuck engine. Retain stage timing and capture a main-thread/engine stack if any stage stalls. Apple's guidance supports removing blocking dependencies from interaction handling, rather than optimizing only the visible drawing. [Apple: Improving app responsiveness](https://developer.apple.com/documentation/xcode/improving-app-responsiveness).

### 2. Remove synchronous preview settings reads and separate preview rendering from engine control

**Priority: high. Evidence: confirmed structure and a conflict with the bundled render API's threading requirements.**

Every [renderPreview request](../yina/ThumbnailPeekView.swift#L31) reads **57 options** synchronously from the main playback core before submitting work. [Timeline mouse movement](../yina/MainWindowController.swift#L3029) invokes this path. The worker coalesces requests, but that happens after the main thread has already paid for those reads.

The [preview worker](../yina/ThumbnailPeekView.swift#L283) also performs synchronous property writes and position/FPS reads on the same serial queue that calls `mpv_render_context_render`. The [bundled render header](../deps/include/mpv/render.h#L55) explicitly prohibits waiting on unsafe libmpv client APIs from the render thread because it can produce render timeouts or deadlocks. Load/seek commands are already asynchronous; the remaining property calls still need attention.

**Change:** cache the rendering-settings snapshot and update it when the file, track, or relevant setting changes. Carry only changed options into a request. Separate normal client work from render work, using asynchronous property replies and generation checks. Preserve the latest-request coalescer and the actual playback color pipeline.

**Verify:** fast timeline scrubbing while changing HDR, equalizer, filters, and tracks; file replacement during a pending preview; preview teardown; and matching SDR/PQ/HLG output. Count main-thread mpv calls per mouse movement and look for render timeout messages. Existing [generated-media preview tests](../other/tests/mpv-preview-smoke.py) provide a starting point, but are not evidence that this threading pattern is safe under contention.

### 3. Investigate AVFoundation queue ownership before blaming ordinary unpause latency

**Priority: high diagnostic follow-up for resume. Evidence: source-level race/deadlock candidates; isolated ordinary unpause passed.**

In the pinned `build/metal-deps/sources/mpv/audio/out/ao_avfoundation.m`, `set_pause` changes the synchronizer and renderer request state outside the feed queue. `stop` synchronously dispatches onto that queue. The restart-notification handler directly calls `stop` then `start`, and `uninit` removes the observer only after releasing renderer/synchronizer/queue resources.

These are concrete ownership and ordering concerns. They do **not** prove that a notification arrived on the feed queue, that teardown raced a notification, or that this caused the user's beachball. The ordinary audio-only probe showed no stall. The existing zero-sample/EOF feed guard is present and should be preserved.

**Change only after targeted review/reproduction:** serialize renderer state transitions, invalidate notification ownership before resource teardown, avoid synchronous self-dispatch, and preserve paused/running state through resets. Keep the custom Metal dependency build rather than substituting stock mpv. The earlier [upstream-port review](upstream-port-review-2026-10-14.md) also identifies this area; its upstream status was not revalidated in this audit.

**Verify:** controlled output-device changes and renderer flush/reset notifications while paused, unpausing, stopping, and closing. Capture queue stacks, notification thread, and active audio driver. Test Core Audio separately if that is the selected driver.

### 4. Remove filesystem work from History's UI and shared lock

**Priority: high. Evidence: confirmed structure.**

[History preparation](../yina/HistoryWindowController.swift#L199) resolves every entry's URL during view construction, reload, and search. [Bookmark resolution](../yina/PlaybackHistory.swift#L149) includes filesystem checks and possible bookmark refresh. The `withoutMounting`/`withoutUI` flags do not make these operations asynchronous. [Row construction](../yina/HistoryWindowController.swift#L314) separately checks file existence for each column; the progress column opens a watch-later file through [Utility](../yina/Utility.swift#L552). An unavailable mounted share can therefore stall History without any media decoding.

[HistoryController.save](../yina/HistoryController.swift#L75) holds the history lock through full-archive encoding and atomic disk replacement. Even background saves can block a main-thread reader of that lock. Creating a history entry, including its bookmark, also occurs under the history lock. Remove/Clear call save synchronously.

**Change:** give History background-resolved immutable row snapshots and cached availability/progress; refresh visible rows with generation checks. Keep bookmark creation and disk access outside the shared lock. Serialize/coalesce persistence on one writer queue after making detached snapshots. Preserve the generation logic that prevents queued additions from undoing Clear History; never trim user history as a shortcut.

**Verify:** large synthetic archives, moved files, unavailable roots, search while loading, concurrent playback additions and Clear/Remove, quit with pending saves, and archive compatibility. Measure main-thread wait time and archive duration separately.

### 5. Make shared-show work opt-in by discovered membership, and make paused writes event-driven

**Priority: next, with a direct connection to paused idle behavior. Evidence: confirmed structure.**

[SharedShowSession.start](../yina/SharedShowSession.swift#L57) schedules checkpoints after file load. The [timer](../yina/SharedShowSession.swift#L81) runs every ten seconds normally, or every two seconds for hosting/following. A local file does not have to belong to a shared show for the timer to run. [Checkpoint](../yina/SharedShowSession.swift#L107) asks the player to synchronize its position; when paused, the normal UI timer is stopped, so this can query mpv synchronously on the main thread.

Each submitted sample repeats discovery. For a valid shared show it reads other writers and atomically publishes a new revision, even when a paused non-host's position has not changed. The I/O is off-main and coalesced, which is good, but unnecessary polling and durability work remain.

**Change:** cache positive and bounded negative membership results, invalidate on media/root/mount changes, and use a conservative rediscovery interval where filesystem notifications cannot be trusted. Sample from the asynchronous playback snapshot. Write paused non-host progress on meaningful state changes and final flush; retain the heartbeat cadence required for Watch Together and explicit freshness rules. Do not make offline records disappear or infer availability from file size alone.

**Verify:** count engine calls, metadata operations, and writes during idle pause for ordinary local files versus shared shows. Verify that a newly created manifest is eventually discovered and that host liveness, follow behavior, final saves, and offline recovery remain correct. Real SMB validation is still pending.

### 6. Avoid one slow share blocking every shared session; avoid rereading all writers

**Priority: next. Evidence: confirmed structure; network latency unmeasured.**

[All sessions use one serial operation queue](../yina/SharedShowSession.swift#L11). A blocked filesystem read or `fsync` on one mount can delay unrelated sessions and their final saves. Existing byte/entry caps and per-session request coalescing bound data and queued work, not filesystem latency.

[Progress reads](../yina/SharedShowStore.swift#L257) enumerate participant/writer files, decode each valid record, and sort them each checkpoint. The cap is 4,096 directory entries and 64 MiB aggregate data. Writer identities are retained across sessions on disk, so cost grows with recorded writers. [Date decoding](../yina/SharedShowStore.swift#L113) constructs a formatter for each decoded date. Follow mode currently pays for the broad scan rather than just the selected writer.

**Change:** use bounded independent work lanes by root/mount, with a limit that prevents unlimited blocked workers. Cache stable descriptors and unchanged records, reuse formatters within an isolated worker, and read the selected host directly for frequent follow updates while refreshing the wider list less often. Preserve per-writer ordering and atomic writes. Do not automatically delete other participants' records or pretend that cancelling a Swift task interrupts a blocking SMB syscall.

**Verify:** one deliberately delayed test root alongside a healthy root, many writer records, malformed records, repeated superseded checkpoints, and final-save behavior. Confirm bounded concurrency and continued service to the healthy root before claiming improvement.

### 7. Release preview resources and retire excess idle players

**Priority: next. Evidence: confirmed ownership; current memory cost unmeasured.**

[Hiding a preview](../yina/ThumbnailPeekView.swift#L23) cancels its request, but [cancel](../yina/ThumbnailPeekView.swift#L378) only invalidates generations and pending work. It does not unload the last file or close the second mpv/render context. Closing happens at deinitialization. Separately, [PlayerCore.playerCores](../yina/PlayerCore.swift#L75) retains the player pool and reuses idle cores without a retirement policy.

This retains warm capacity based on the historical number of concurrently created players. It is **not** a claim that every sequential file creates another leaked player. A retained player's preview can keep a decoder and media handle around after the preview is hidden.

**Change:** asynchronously unload preview media on file close and release preview resources after an inactivity grace period or memory pressure. Retain a small measured number of warm idle players and retire surplus ones after orderly engine, render, plugin, and observer shutdown.

**Verify:** repeated hover/hide and open/close of multiple windows, file handles, active decoder/core counts, memory pressure, reopen latency, and no callback-after-teardown errors. Compare memory plateau after equivalent workloads; do not label intentional warm caches as leaks solely because they remain allocated.

### 8. Keep subtitle animation from issuing hundreds of blocking engine mutations

**Priority: next. Evidence: confirmed structure.**

[SubtitleDissolve](../yina/SubtitleDissolve.swift#L120) runs a main-run-loop timer at 60 Hz during a fade. [Each frame](../yina/SubtitleDissolve.swift#L161) synchronously sets blur and up to three colors: up to **240 property mutations per second** during the animation. Color-space component caching already avoids redundant conversions; the remaining expense is the engine handoff and repeated invalidation. The timer is correctly invalidated on completion/abandonment, so this is not an always-running timer leak.

**Change:** submit an ordered, coalesced batch through the asynchronous control path, skipping unchanged values; assess a renderer-owned animation if the engine supports equivalent results. Preserve the chosen fade/blur appearance and exact final subtitle state.

**Verify:** rapid reversal, style/track changes mid-fade, seek/stop/shutdown, and callback ordering. Measure main-thread time and engine reconfiguration work while fading. Do not reduce animation quality merely to lower a call count.

### 9. Avoid full-frame Live Text work for pauses that immediately end

**Priority: profile before changing user-visible behavior. Evidence: confirmed work path; contribution to resume unproven.**

[Pause handling](../yina/PlayerCore.swift#L2545) requests Live Text when enabled and available. [Analysis](../yina/LiveTextSupport.swift#L110) captures a rendered frame and passes it to ImageAnalyzer. Previous tasks are cancelled and cancellation is checked after awaits; those protections already exist. However, [snapshot capture](../yina/ViewLayer.swift#L134) is continuation-based with a timeout and no task-cancellation handler, so cancellation does not immediately remove pending capture/conversion work.

**Change:** make snapshot cancellation release pending work promptly, check cancellation before capture, and benchmark a small pause dwell threshold or OCR-specific downsampling. Preserve full-resolution playback and deliberate text selection.

**Verify:** frequent brief pauses in high-resolution HDR video, cancellations before/after presentation, no double-resumed continuation, and recognition quality. Compare capture, conversion, and analysis durations independently of the unpause command.

### 10. Make cache accounting incremental

**Priority: next for large caches. Evidence: confirmed structure.**

[CacheManager.write](../yina/CacheManager.swift#L51) holds its lock while checking the directory's total size, possibly sorting/evicting entries, and writing the new file. Each successful write invalidates the cached directory listing. A burst of artwork writes therefore repeatedly enumerates/stat-checks an expanding cache. [Legacy Utilities](../yina/SettingsPageUtilities.swift#L85) also requests size synchronously; that is conditional on reaching that legacy page, not the newly unified settings' normal path.

**Change:** maintain sizes and access metadata on one cache writer, adjust totals after successful replacement/removal, periodically reconcile external changes, and serve cached size to UI. Keep actual disk-budget enforcement and conservative accounting when deletion fails.

**Verify:** a large temporary cache, concurrent artwork jobs, external deletion, replacement, budget changes, and failed eviction. Measure directory/stat counts per successful write and UI waits on the cache lock.

### 11. Bound plugin downloads/output and own their cancellation

**Priority: workload dependent. Evidence: confirmed structure.**

[Plugin downloads](../yina/JavascriptAPIHttp.swift#L54) buffer the entire HTTP response before writing it. General HTTP conversion builds both JSON and text representations when available. The HTTP API does not implement request cleanup on plugin unload. [Process execution](../yina/JavascriptAPIUtils.swift#L151) accumulates stdout/stderr into strings even when streaming hooks are present, and waits for process exit on the plugin instance's serial queue. A long process can delay later work on that same instance; the queue is per instance, not one global queue for all plugins.

**Change:** use streamed/download-to-file transfers, owner-tracked cancellation, and documented optional output limits or file-backed output for large subprocess results. Use process completion notifications rather than occupying the instance queue until exit. Preserve existing response semantics or make limits explicit; do not silently truncate plugin data.

**Verify:** large synthetic responses, noisy/long-running processes, plugin unload mid-operation, proper pipe EOF drainage, and bounded resource growth. Existing plugin timer/WebSocket cleanup is present and should be retained.

## Smaller opportunities and profiling targets

| Area | Current evidence | Next useful action |
| --- | --- | --- |
| Playback Settings | `show(for:)` refreshes devices after `bind(to:)`, which already refreshes them when the player changes ([source](../yina/PlaybackSettingsWindowController.swift#L51)). Device queries are synchronous. | Remove the duplicate first-bind query; feed device and selection snapshots through the asynchronous bridge. Coalesce slider writes while preserving the final value. |
| Inspector and menus | Inspector has a one-second timer with tolerance and correct close cleanup, but property reads occur on main ([source](../yina/InspectorWindowController.swift#L254)). Menu audio/filter queries also wait on mpv. | Use the same cached snapshots; avoid periodic Inspector work when it cannot be seen. Preserve explicit refresh for custom watched properties. |
| Hidden/occluded rendering | Metal's [presentation check](../yina/ViewLayer.swift#L119) considers layer visibility, bounds, and window existence, not window occlusion. Minimize can pause playback by preference, so impact depends on configuration/PiP. | Measure GPU/frame submissions with covered/minimized windows. If material, skip presentation while still servicing mpv render updates and honoring PiP/snapshots. Do not blindly stop the swap clock or reduce HDR fidelity. |
| Folder drag/open | [Drag acceptance](../yina/DraggingDetect.swift#L131) resolves aliases and may recursively inspect directories before drop. Generic [openURLs](../yina/PlayerCore.swift#L470) also resolves and enumerates synchronously. Welcome opening already has background preparation. | Accept plausible file drags cheaply; validate/expand asynchronously after drop with cancellation and ordered results. Apply the existing prepared-open approach to other entry points. Test large local trees and unavailable mounts separately from resume. |
| Subtitle matching | [Series matching](../yina/AutoFileMatcher.swift#L156) compares each subtitle prefix against video prefixes and stores distances. The later force-match stage already caps pair count below 10,000; generation checks already cancel stale work. | Profile large mixed directories, cache filename normalization/lengths, and narrow candidate series before edit-distance work. Keep existing matching semantics and the fallback cap. No claim that this background work caused the resume hang. |
| First player startup | [HardwareDecodeCapabilities](../yina/HardwareDecodeCapabilities.swift#L62) can wait for its asynchronous initialization. Initialization starts early, reducing normal impact. | Measure a cold launch with immediate open before considering an asynchronous readiness path. This is not the reported already-loaded pause/resume scenario. |
| Recent Documents | Eager startup population was removed; opening the native menu still resolves recent-document URLs. | Measure menu-open latency with unavailable entries; avoid reintroducing eager startup work. |

## Existing controls worth preserving

- Main Metal rendering already has a dedicated queue. Frame updates check whether rendering is required, and snapshot requests have supersession and a two-second timeout.
- The normal playback UI timer stops while paused/inactive and has tolerance. The display link is stopped after the existing six-second pause grace period. Shared-show polling is a separate exception described above.
- Welcome shows a bounded set of cards/recents, does availability/open preparation off-main, cancels stale artwork requests, and shares a two-decoder artwork budget ([FFmpegController](../yina/FFmpegController.m#L31)).
- Preview generation is lazy and coalesces to the latest request. The current Metal path does not eagerly build the old full decoded-thumbnail array, so that older audit finding should not be repeated as current behavior.
- Shared-show reads have traversal/size/entry validation, and submissions coalesce pending current progress while retaining a final save. Improvements must retain these guarantees.
- Logging is bounded/coalesced and file writing is asynchronous. Inspector's timer and observers are removed on close. Plugin timer and WebSocket cleanup exists. Singleton/long-lived controllers are not automatically leaks.
- Safari/browser helpers are action-driven, with no persistent media-processing loop identified. CLI/plugin-tool process waits are in standalone command-line programs; they are not evidence of an AppKit main-thread hang.
- No continuous location workload or background URL-session polling service was found in the owned app source. System/vendor internals were not exhaustively audited.

## Implementation order and acceptance evidence

1. **Make engine interaction nonblocking for UI:** resume and its callback first; then share the state bridge with timer updates, settings, menus, Inspector, and progress sampling. Prove command ordering and responsiveness under a deliberately delayed engine response.
2. **Repair preview control/render separation and cache its 57-option snapshot.** Validate actual generated HDR/SDR frames and stressed cancellation, not just source-pattern tests.
3. **Investigate the audio reset/notification race with stacks.** Keep this distinct from the UI resilience fix: a responsive interface does not prove audio is healthy.
4. **Remove History UI/lock I/O and unnecessary paused/shared-show work.** Benchmark local fixtures now; defer claims about real SMB until it is available.
5. **Measure and address retained resources, cache accounting, subtitle animation, and plugins.** Compare steady-state and peak memory, file handles, decoder count, CPU/GPU time, and idle wakeups for the same workload.

No battery-life percentage, memory saving, or whole-app speedup is claimed without a before/after measurement. The immediate objective is that Play/Pause cannot block AppKit while waiting for mpv, followed by establishing the engine-side cause of any remaining stall.

## Implementation appendix — 29 October 2026

The audit above describes the **pre-change 2.36 baseline** at commit `d1cadce7bfbf861beb1440619f5759485c81b853`. Its source references and performance measurements are historical evidence, not a description or measurement of this working tree. The changes below were made after that baseline. This appendix records implementation and local verification; it does not claim that the original beachball has been reproduced or eliminated.

| Audit area | Implementation in this working tree | Local evidence and remaining checks |
| --- | --- | --- |
| 1. Playback engine waits | `MPVAsyncClient`, `MPVController`, and `PlayerCore` now route transport and observed state through asynchronous, ordered control and cached UI values. EOF, seek, rapid transport, and teardown paths were changed together. | Production async-bridge fixture passes foreign replies, final restore, flush, and shutdown cancellation; transport, EOF, resume logging, and attachment fixtures pass. A live click-to-return and click-to-first-frame trace, device-change stress, and a stack from the original stall remain necessary. |
| 2. Preview settings/render separation | `ThumbnailPeekView` caches option snapshots, uses nonblocking client operations on its render queue, coalesces requests, and has generation checks. | Generated SDR/PQ/HLG Metal preview tests pass with cancellation and idle reopen using the matching rebuilt dependency bundle. Fast scrubbing with simultaneous settings changes and visual comparison in the installed app remain runtime checks. |
| 3. AVFoundation ownership | The pinned Metal mpv patch includes queue and teardown changes; AVFoundation state and underrun smoke fixtures were added. | The rebuilt mpv must be paired with its matching 49-library dependency set: mixing it with the older FFmpeg library caused `check_library_versions` to exit during initialization. With the matching set, C initialization, the production async bridge, and an elevated AVFoundation smoke test pass five pause/resume cycles, a seven-second pause, paused seek/reset, EOF, reopen, and stop. Induced output-device resets, queue stacks from the user's stall, and live app playback remain unverified. |
| 4. History | `HistoryWindowController` resolves detached entries and watch-later progress on a bounded background queue, caches row availability, and discards stale search/reload results. `HistoryController` creates entries outside its lock and coalesces ordered saves after detached copies. | `history-clear-smoke.swift` passes Clear/Add generation, detached removal, and a 5,000-entry archive reload. Unavailable SMB roots, moved-file bookmarks, and main-thread timing remain unmeasured. |
| 5. Shared-show idle work | `SharedShowSession` samples cached player state, caches positive/negative membership with retry, and skips unchanged paused non-host writes while retaining host cadence and final saves. | `shared-show-session-smoke.swift` passes rapid file changes, final save, host follow, and unchanged paused revision. Real paused SMB traffic and newly appearing manifests after retry need runtime measurement. |
| 6. Shared-show isolation/reads | Four bounded serial lanes are reserved by active root. `SharedShowStore` reads a selected host directly between broad refreshes, caches unchanged progress by file identity/metadata with expiry and a size cap, and reuses date formatters within a decoder. | `shared-show-smoke.swift` passes revisions, malformed records, protocol validation, and symlink checks. A deliberately blocked root beside a healthy root and real SMB latency remain untested. |
| 7. Preview and idle-player lifetime | Preview workers release their mpv/render resources after idle use. Surplus non-first idle players retire after a grace period, with explicit observer and plugin cleanup when shutdown completes. Welcome and direct opens now share a stale-request token. | Lifecycle source review identified and repaired a cross-entrypoint stale-open gap and an observer retain-cycle risk. `media-preparation-smoke.py` executes the production reservation methods against delayed welcome/direct completions, old failure, close cancellation, and shutdown. Repeated hover/window-open memory plateaus, handle counts, and callback-after-teardown stress still need runtime validation. |
| 8. Subtitle dissolve | `SubtitleDissolve` sends coalesced asynchronous style values and discards pending style writes on finish or shutdown. | The production dissolve fixture passes duration, overshoot, reversal, cancellation, and exact restoration; the async bridge separately checks final-write ordering. HDR appearance and engine reconfiguration cost remain runtime checks. |
| 9. Live Text and snapshots | `ViewLayer` cancels pending snapshot requests promptly; `LiveTextSupport` checks cancellation before analysis work. | Production snapshot cancellation tests pass cancellation before/after continuation installation, 200 concurrent completion/cancellation races, and replacement. Short-pause OCR timing and quality have not been measured. |
| 10. Cache accounting | `CacheManager` serializes writes/eviction, keeps an incremental size snapshot, reconciles external changes, and serves the Utilities label asynchronously with loading/error states. | `cache-regression-smoke.swift` passes concurrent budget, eviction, failed-write accounting, and external add/remove cases. Large-cache enumeration counts and UI wait times remain unmeasured. |
| 11. Plugin I/O | HTTP and subprocess paths have bounded/owned work and cancellation hooks in `JavascriptAPIHttp`, `JavascriptAPIUtils`, and `JavascriptPluginInstance`. | Plugin output, subtitle-matcher, and queue-full quit fixtures pass. The local HTTP fixture passes a 5 MiB POST, destination replacement, request options, response JSON/text, owner task cleanup, and Promise completion. Large live transfers, noisy long processes, and unload under real plugin activity still need resource measurements. |

Other opportunities: Playback Settings device queries, Inspector updates, folder drag/open preparation, subtitle matching, and cold hardware-decoder readiness have implementation changes in this working tree. Transport, attachment, short fullscreen, Finder deferred callback, resume logger, subtitle dissolve, PiP visibility state, and OSC geometry fixtures pass. The fourth integrated build exits successfully after earlier Swift errors were fixed. The final signed install is verified below. Hidden/occluded Metal presentation, unavailable Recent Documents menu entries, and the user's actual stalled AVFoundation or SMB workload still require targeted profiling. No battery-life, memory-saving, or whole-app speedup percentage has been measured.


## Installed artifact

The 17 implementation features are separate local commits, ending at
`ba03e127162556573e3b11607ec5cfc77f7b33dd`. No push or public release was performed.
The repository release counter is 2.53; this local Nightly uses the normal
date-based bundle version **202610291743**.

`other/build_install_nightly.sh /tmp/yina-performance-20261029` completed from a
fresh build directory and was rerun after the final PiP control-visibility guard.
The final bundle is installed at `/Applications/yina.app`, signed with the
configured Apple Development identity, hardened runtime enabled, and verified
with `codesign --verify --deep --strict`. Its recorded source commit matches
`ba03e127` and its executable SHA-256 matches the built artifact:
`6e445729653f6b9899ba213267eccffc6a17febf375c2beeabf58c194e87658f`.

Post-install validation confirms exactly the matching 49 packaged dylibs, all
non-system dependencies resolved inside the bundle, and no Homebrew linkage.
A newly compiled probe linked against the **installed** libmpv passed five
AVFoundation pause/resume cycles, a seven-second pause with a paused seek/reset,
EOF, reopen, and stop. This is generated silent media, not the user's SMB file.

The subtitle pixel regression, asynchronous bridge, queue-full quit handling,
preview SDR/PQ/HLG, snapshot cancellation, file-opening races, storage, plugin,
track-policy, OSC geometry, and PiP suppression/restore fixtures pass. PiP visual
appearance, live fullscreen/Spaces movement, output-device reset stress, and the
original occasional resume beachball still need the user's real playback test.
Preserving an existing fullscreen Space does not provide arbitrary Space
placement or persistence across application restarts.
