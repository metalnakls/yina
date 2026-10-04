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
