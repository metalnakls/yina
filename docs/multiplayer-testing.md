# Shared-show acceptance checks

Use two Macs with the same show folder mounted and current YINA builds. Glass
must be running with the transfer present and its download folder mapped to that
show folder. Use disposable media for disconnection, truncation and migration
checks. There is no manual Export button: Glass publishes its inventory when it
has the mapped transfer details.

## Setup and storage

1. Open an episode and open **Playlist → Shared Show**. If the show has no Glass
   metadata, use **Enable for This Show…** and select the exact show folder.
2. Check that the root has one hidden `.yina/` folder. Its `show.json` identity
   must match on both Macs. Each player writes its own progress file.
3. With copies of recognized old v1/v2 `.yina.json` fixtures, verify migration
   preserves the show identity, inventory bytes and existing progress. Unknown
   or conflicting old metadata must remain untouched.

## Resume, host and follower

1. Play and pause at different positions on both Macs. Neither saved position
   should move the other player. Use **Resume at…** explicitly to adopt one.
2. Choose **Host Watch Together** on Mac A. On Mac B, open any episode in that
   show and choose **Follow** with A's displayed code. B should open A's episode.
3. Pause, resume, seek and change speed on A. B should follow within the polling
   interval. Volume, audio tracks and subtitle choices remain independent.
4. Reorder A's playlist and advance to another episode. B's **Shared Queue**
   should reflect the order and current episode. B must not receive a duplicate
   full playlist or automatically load unrelated files from its folder.
5. Let A reach natural EOF and then continue. B should wait and follow the next
   episode, without repeatedly reopening the completed one. Explicit Stop or
   Leave on A ends the session.
6. While following, choose Leave, pause locally, seek locally, choose another
   file, or edit B's playlist. B takes control immediately. A pending remote file
   preparation is cancelled. A load already accepted by mpv may finish, but
   later host controls must not override B.
7. Change A rapidly between episodes while B is preparing one. The latest target
   wins. Leave and rejoin the same host; old work must not act as the new session.

## Availability and Glass requests

1. Use a transfer with complete, partial and unselected files. Unavailable
   Episodes should show saved bytes and a snapshot date. A sparse file's presence
   or apparent size does not establish completion. A complete snapshot paired
   with a truncated local file must remain unavailable.
2. Follow a host into a missing/partial episode. B should wait without loading
   the file. Once Glass publishes fresh completion and the file matches its
   declared size, B can open it.
3. Request an unavailable episode. Check saving, waiting and Glass's accepted
   response. Accepted means the selection, priority and start commands succeeded;
   it does not mean all bytes are present.
4. With Glass offline, the request should remain pending without repeated writes.
   Reopen Glass and check its durable response. Where an RPC fails, use the
   explicit Retry action; an old failed response must not acknowledge that retry.
5. Withdraw a pending request. This withdraws the request and does not promise to
   stop a transfer Glass already started. Verify old responses cannot replace
   the current request's status.

## Disconnection and recovery

Disconnect/reconnect only through your normal network controls. During a lost
share, local controls must remain responsive. Stale host records must not seek
or reopen media. Reconnect and verify recovery without duplicate queue entries,
lost independent progress, or unexpected automatic requests. Restart each app
and confirm show identity and saved progress survive. After a host restart,
explicitly follow its new session code.

## HDR and previous playback changes

On an HDR-capable display, enable HDR and pause HDR media. Compare the pause/seek
OSD, time preview, floating and docked controls, buffering/info overlays and
playback sidebars. Check light/dark appearance, then disable HDR or move the
window to an SDR display: colors must return to SDR without accumulating exposure.
Watched progress stays white. Settings and system menus retain native appearance.

For the earlier playback work, test repeated Play after pausing (including a long
pause), fullscreen/windowed transitions at the same video size, primary and
secondary subtitle selection, PiP subtitles beneath the video, PiP hide/restore,
and return from PiP to the original fullscreen Space. See [the performance audit](performance-audit-2026-10-29.md),
[subtitle scaling](subtitle-scaling.md), [track controls](track-controls.md),
[PiP subtitles](pip-subtitles.md), and [PiP lifecycle](pip-window-lifecycle.md).

## Evidence boundary

Local filesystem and production-code fixtures exercise protocol validation,
migration, queue and transport state, and request outcomes. A successful build
or fixture does not verify two physical Macs over SMB, perceived HDR brightness,
macOS Space placement, or native menu accessibility. Those remain the runtime
checks above until observed with the actual setup. Watch Together synchronizes
through shared files and polling; it is not frame-accurate streaming.
