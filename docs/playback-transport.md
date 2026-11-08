# Playback transport

PlayerCore reduces transport inputs on the main queue. PlaybackTransport owns the
media phase, requested and observed pause, temporary scrub holds, seek status,
and EOF. PlaybackInfo publishes the result for the OSC, Now Playing, Sleep
Preventer, and PiP. The transport keeps loading until libmpv has loaded metadata
and the video output has usable geometry, or the file has no selected video.

App transport requests share one reply-driven lane. A manual open or playlist
step waits for the pause write before asking libmpv to change entries. A failed
step restores the prior play intent. A seek queued for the old entry is dropped
when the next entry starts. An EOF replay waits for its rewind command before
unpausing, and the seek indicator follows the engine restart event. Natural
playlist advance stays gapless by default. With pause-on-open enabled, the
libmpv load hook holds the new file until the pause write completes. Explicit
play or pause during loading determines what happens when the output is ready.

The event reader identifies each file start with a serial and the libmpv playlist
entry ID. Transport requests also carry a media generation, so a late reply
cannot settle a replacement. A scrub hold can be released without overriding an
explicit pause. The remote-recovery hook restores file-local start and track
options before continuing, and a successful reconnect leaves the recovered
position paused.

The standalone transport fixture exercises reordered replies, startup readiness,
playlist rejection, natural advance, EOF replay, and stale seek cancellation.
The remote-recovery fixture uses the bundled libmpv with generated media and a
faulting stream. It checks exact reconnect position, playlist retention, and the
pause-on-open barrier before the natural load hook continues. These fixtures
cover engine and state behavior. Native window presentation and PiP animation
require an app runtime check.
