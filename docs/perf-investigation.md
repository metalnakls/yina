# Performance investigation

Working notes for the open CPU / memory issue. Not user documentation.

## Symptom

- Reported: app reaches ~1 GB and pins CPU near 100% after being left running
  for one to two hours in the background.
- Reproduced once as visibly laggy video playback.

## Evidence collected

Two `sample` traces in `yina-traces/` (outside the repo, they are large and
machine-specific):

| File | When | Footprint | Notes |
|---|---|---|---|
| `cpu-sample.txt` | 10 min after launch, idle | 658 MB | fully idle, no busy frames |
| `cpu-sample2.txt` | 1 h after launch, video playing | 939 MB | threads still mostly blocked |

### What was inactive during these samples

These samples did not capture the reported CPU spike and cannot rule out an
intermittent fault in the paths below.

- **No runaway loop or spin.** Every thread is parked in a blocking primitive
  (`__psynch_cvwait`, `__workq_kernreturn`, `__select`, `mach_msg2_trap`).
  The first sample contains zero non-idle frames.
- **Not audio.** `AQConverterThread`, `audioqueue.source` and
  `audio.IOThread.client` are all blocked in `_pthread_cond_wait`, which is
  normal CoreAudio behaviour.
- **Not the EDR path.** `updateOSCExtendedDynamicRange(force:)` was the heaviest
  yina-owned frame in the first trace (15 samples), but it is guarded by a 0.05
  headroom delta and is not a plausible source of sustained load.
- **Not logging or telemetry.** `Logger.enabled` is
  `enableAdvancedSettings && enableLogging`, both defaulting to false, and
  `enableAdvancedSettings` is 0 in the live preferences domain.

### What the traces DO show

- Footprint grows 658 MB -> 939 MB over roughly 50 minutes. This is the real,
  unexplained finding.
- The only sustained non-idle work is AGX GPU colour conversion
  (`agxsTwiddleAddressCommon` in `AGXMetalG13X`, ~1900 samples) plus ffmpeg
  HEVC decode. On an HDR display this is the expected cost of the colour
  pipeline, not a fault. It plausibly explains laggy playback while the CPU
  reads as idle, because the work is on the GPU.
- `PlayerCore.syncUITime` fires from a timer and blocks in
  `mp_dispatch_lock` / `mpv_get_property`. It is waiting on mpv, not spinning.
  It is a plausible *contention* point if mpv is busy, but it is not burning
  CPU on its own.

## Open questions

1. What owns the 658 -> 939 MB growth? A `vmmap -summary` taken while the app
   is up, compared against the 152 MB `Malloc Large` baseline observed at the
   10-minute mark, would separate frame backing stores from a genuine leak.
2. What produces the 100% CPU? Neither trace captured it. The 100% reading
   was not reproduced in any sample so far, so it may be a distinct,
   intermittent condition.

## Slow media opening (2026-10-05)

The user confirmed that the player-window lifecycle fix stops the video-open
crash, but reported a slow opening. Existing system logs show Metal starting
during opening; they do not establish which yina stage accounts for the delay.
No playback or app interaction was performed for this investigation.

`PlayerCore` now records cumulative opening timings in the system log under
subsystem `tsmc.yina`, category `MediaOpening`, independently of the session
logging preference. Stages cover options, renderer/window setup, load request
and return, file-loaded callback, and showing the window. Only the player
number, stage, and elapsed milliseconds are recorded; paths/URLs are omitted.
Separate `mpv initialized` and `core ready` durations cover first-core startup,
including plugin loading. Those durations use their own start points; the
remaining stages measure cumulative time from the main-window open request.

Read the timings after a user opens media:

    /usr/bin/log show --last 10m --style compact --predicate 'subsystem == "tsmc.yina" AND category == "MediaOpening"'

Media still loads after player-window setup. The existing file-opening
architecture check passes; starting earlier could reintroduce callbacks into
uninitialized views. No opening-speed improvement is claimed yet.

## Retention fixes

The logger's pending buffer and visible log list now retain at most 10,000
entries. Pending entries are trimmed in batches, and append notifications are
coalesced before reaching the main queue. The full session still goes to disk;
Save All exports that file when logging is enabled.

Completed JavaScript timeouts now release their timers and callbacks. Pending
timer creation can be cancelled before it reaches the main run loop, and timer
ownership is synchronized across plugin queues.

Thumbnail error paths release their FFmpeg contexts and file descriptors. HDR
preview images own their pixels after conversion. Welcome artwork reads only
the selected cache frame, and cache eviction can run repeatedly under one
serialized budget check. These changes address concrete retention and repeated
work; they do not establish the cause of the intermittent 100% CPU report.

Focused regressions run with `bash other/tests/optimization-smoke.sh`. Recheck
the long-running symptom with hot CPU samples and before/after VM summaries.

Validation on 2026-10-04 passed cache v2/v4 compatibility, malformed-cache
rejection, concurrent cache budgeting, bounded logs with full file export,
plugin timer cancellation and callback release, and FFmpeg error cleanup/HDR
pixel ownership under Address Sanitizer. A synthetic 101-frame cache took
0.485 seconds for 50 single-preview reads before the change and 0.094 seconds
afterward. This benchmark measures the cache reader, not full welcome-window
latency or the reported long-running CPU/memory symptom.

## Deliberately not changed

Tone mapping stays enabled. An earlier hypothesis that HDR tone mapping was the
cause of the lag was investigated and rejected: the display is HDR-only, so
this is the normal colour path, and upstream enables it by default. The code
default was aligned to `true` to match upstream `2b2f3c8c`.

## Black playback investigation (2026-10-05)

- Removing background track suspension did not resolve the user's black-screen report.
- Two stack samples of the user's running playback process showed the mpv play loop,
  Matroska reads, and subtitle processing, with the VO thread waiting. They did not
  capture video rendering or drawable acquisition; this alone does not establish
  why rendering is absent.
- Opening stage logs reached renderer initialization, file loaded, and window shown
  within 186 ms for the traced opening.
- The media contains H.264 video and AC-3 audio. An isolated probe using the installed
  libraries selected video/audio track 1 and obtained 1916 x 1076 video dimensions,
  both with null output and with a Metal render context. It used no window or sound
  and disabled configuration and watch-later persistence.
- macOS denied debugger attachment to the installed app, so live view and track
  state could not be read through the debugger.
- Added system-log snapshots at file loaded and window shown: selected tracks,
  codecs, pause state, video/layer bounds, attachment, and hidden state. mpv warnings
  and errors now reach `PlaybackFailure` even when file logging is disabled; message
  text is private because it can contain media paths or URLs. No preferences changed.
- Fresh diagnostics showed `vid=no`, no video decoder, and zero media dimensions,
  while the attached, visible view and layer both had 640 x 360 bounds. A fatal
  `vo/libmpv` event preceded renderer initialization. The isolated harness reproduced
  "No render context set" when force-window was enabled before context creation,
  although its later load recovered video selection. This distinguishes an observed
  initialization fault from a fully reproduced black-screen sequence.
- Moved force-window activation after programmatic window initialization and its
  render-context setup. Added an opening-order regression check. A user playback
  check is still required.
  Stack samples and temporary probes are outside the repository.

- The user reopened build `202610051120`: the early fatal VO error disappeared,
  but `vid=no` and absent video dimensions persisted. The order fix addresses a
  real initialization error but does not yet resolve black playback.
- Added selection snapshots after mpv initialization, plugin setup, window setup,
  and load stages, plus explicit app video-track requests. These record only
  option values and counts, to locate when video selection becomes disabled.

### Verified outcome

The user selected the video track and confirmed the picture appeared, then quit,
reopened, and confirmed the same video opened normally without selecting a track
again. Fresh logs show `vid=1`, `option_vid=1`, H.264 decoding, and 1916 x 1076 media
dimensions. The blank view was caused by video selection being None, rather than
an incorrectly sized or hidden video view. The exact origin of the earlier disabled
selection is not proven; background suspension previously changed `vid` to `no`,
but no current app track request was logged during the failed openings. That
suspension path remains removed. The separate early VO initialization error is
fixed. No user preferences or watch-later files were edited by the investigation.
