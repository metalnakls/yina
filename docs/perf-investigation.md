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

### What the traces rule OUT

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

## Known latent bug (not the current issue, found while looking)

`Logger.$buffer` is appended to on every log call and is only drained by
`LogWindowController.flushBuffer`, which is reached through `scheduleFlush`:

```swift
guard flushTimer == nil && isWindowVisible else { return }
```

With the Log window closed the buffer is never drained, so if logging is ever
enabled the buffer grows without bound for the lifetime of the process. This
is dormant today because logging is off by default. A cap of roughly 10k
entries inside the existing lock would close it.

## Deliberately not changed

Tone mapping stays enabled. An earlier hypothesis that HDR tone mapping was the
cause of the lag was investigated and rejected: the display is HDR-only, so
this is the normal colour path, and upstream enables it by default. The code
default was aligned to `true` to match upstream `2b2f3c8c`.
