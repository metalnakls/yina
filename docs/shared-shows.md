# Shared shows

YINA and Glass share a show folder through one hidden `.yina/` folder. Glass owns transfer
snapshots and download selection. YINA owns each player's progress and explicit
download requests. Existing mpv playlists, local watch-later data, and manual
subtitle selection keep their behavior.

## Using it

Open a local or mounted SMB episode normally. Use **Shared Show** in the Playlist
pane's footer or the current episode's context menu. A valid Glass descriptor or
legacy inventory is discovered automatically, within 12 ancestors and the volume
boundary. For a folder without a descriptor, **Enable for This Show…** lets you
select its root explicitly. Opening an ordinary file never creates a descriptor
in a guessed folder.

Progress is saved while playing or paused. Another player's saved position is an
explicit **Resume at…** action for the episode already open. It does not replace
local resume automatically, open another file, or choose the furthest position.

For Watch Together, open an episode from the same show on both Macs. On one choose
**Host Watch Together**; on the other choose **Follow** with the matching
six-character code. The follower applies the host's play/pause, position and
speed, and opens the host's current episode once it is safely available. The
host's ordered **Shared Queue** appears separately in the menu. It is read-only
on the follower and does not replace its full mpv playlist.

**Leave Watch Together**, a local open or playlist edit, or a local transport
control takes control back. Volume, subtitles and other presentation choices
remain local. Custom scripts or commands sent directly through mpv IPC are not
classified as local transport actions. A pending remote file preparation is
cancelled on takeover; a load already accepted by mpv may still complete, but no
further remote transport changes apply.

Both machines need the same show ID and relative episode paths. Missing, partial,
truncated, stale or ambiguous managed episodes wait without being enqueued. The
host can advance to the next episode, and followers switch when it is available.
At natural EOF they wait for the next episode rather than reopening the finished
one. An explicit host stop or leave ends following. Stale, future or inaccessible
host records cannot drive playback. See [Watch Together](shared-show-watch-together.md).

Unavailable Episodes shows saved byte progress and snapshot dates. Its **Request
Download in Glass** context action writes an exact torrent/file request. Glass
must be running with its server mapping and that transfer already present.
Status reports saving, waiting, Glass's acceptance or its failure. Acceptance
means selection, priority and start succeeded, not that bytes have arrived. Use
**Retry Download Request** after failure or expiry; it advances the same request's
revision. **Withdraw Download Request** writes a newer cancellation while pending;
an active download may continue in Glass. Old responses cannot acknowledge a
newer action. A newer request from the same player replaces its previous demand;
other players' demands are preserved. No automatic requests or deletion occur.

## Portable format and ownership

The version-two `.yina/show.json` is an immutable identity:

```json
{"schemaVersion":2,"showID":"4B182DAC-5B18-41B9-9AAE-B7709CFCC89A","createdAt":"2026-10-29T12:00:00.000Z"}
```

Each process/window writes only its own fragment:

| Path under the show root | Owner / content |
| --- | --- |
| `.yina/transfers/<writerUUID>/<hash>.json` | Glass's dated episode inventory |
| `.yina/progress/<participantUUID>/<writerUUID>.json` | One YINA player's current episode and position |
| `.yina/demand/<writerUUID>.json` | That player's latest explicit download request |
| `.yina/queues/<writerUUID>.json` | Host-owned ordered paths and current episode |
| `.yina/receipts/<glassWriterUUID>/<requestUUID>.json` | Glass's durable outcome for one request revision |

The participant UUID persists in the local app profile; each player gets a new
writer UUID. Positions from different writers remain separate, including older
sessions. This is a set of current/last session positions, not a complete history
of every episode watched. Progress never authorizes cache eviction.

A progress record has `schemaVersion: 1`, `showID`, `participantID`, `writerID`,
monotonic `revision`, ISO-8601 `updatedAt`, `relativePath`, `position`, `duration`,
and `activity` (`playing`, `paused`, or `stopped`). YINA adds two optional fields
for Watch Together: `watchTogether` (Boolean) and `playbackRate` (positive finite
Double). An absent/false `watchTogether` never advertises a host. The current
Glass decoder ignores these extensions and can still read the progress record.
YINA accepts Glass's optional coverage field without interpreting it as watched
or changing another writer's file.

Recognized old root `.yina.json` files migrate into `.yina/`, preserving their
identity and original bytes. Version-one inventories become `legacy-index.json`
and retain Glass's deterministic SHA-256 show ID. Unknown, conflicting, or malformed
metadata is preserved. See [storage and migration](shared-show-storage.md). No old multiplayer-branch implementation is merged.

Writes use a temporary file, `fsync`, then an atomic rename into the writer's own
path. Metadata ancestors and leaf files are opened without following symlinks.
Request paths are revalidated even beyond the catalog's local-file-check limit.
No credentials, absolute media paths, or network addresses are written.

## Timing and failure behavior

Four bounded utility lanes perform filesystem work. Each root with work in flight
keeps its lane and write order; a stalled root leaves other lanes available.
Checkpoints coalesce while a share is slow; UI actions and layout do not wait for SMB. Normal
progress checks every ten seconds. Hosting or following checks every two seconds,
with host transport changes also requesting a checkpoint. Snapshot time includes
fractional seconds; playing positions are extrapolated by playback rate. Drift
over 0.75 seconds triggers a seek, clamped below EOF. Hosts expire after ten
seconds. This is coarse synchronization over a shared folder, not frame-accurate
streaming or SharePlay, and requires reasonably synchronized computer clocks.

If the share disappears, playback continues locally. The next successful poll
publishes the latest state. Final saves are best effort at stop/quit; YINA does
not hold termination open waiting for a network volume. Missing manifests and
invalid catalog data leave the regular playlist usable.

## Validation

The following fixtures use disposable folders and no personal media:

```sh
xcrun swiftc -parse-as-library -module-cache-path /tmp/yina-shared-modules \
  yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift \
  other/tests/shared-show-smoke.swift -o /tmp/yina-shared-show-smoke
/tmp/yina-shared-show-smoke

xcrun swiftc -parse-as-library -module-cache-path /tmp/yina-shared-modules \
  yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift \
  yina/SharedShowSession.swift yina/SharedShowDownloadRequest.swift yina/PlayerState.swift \
  other/tests/shared-show-session-smoke.swift -o /tmp/yina-shared-session-smoke
/tmp/yina-shared-session-smoke
```

`other/tests/shared-show-glass-smoke.swift` additionally compiles with Glass's
actual `Models.swift`, `TorrentNameCleaner.swift`, `ShowEpisodeIndex.swift`, and
`YinaShowStore.swift`. It checks Glass → YINA inventory, YINA → Glass progress and
demand (including Watch Together extensions), Glass → YINA progress, and identical
legacy IDs, byte-preserving migration in both directions, and receipts. It passed against the local `/Users/wsb/glass` sources on 2026-10-29.

The session fixture replaces only the mpv/UI boundary and exercises the production
queue and disk protocol, rapid file changes, final saves, explicit resume,
play/pause/seek/rate following, local takeover and stale/ended hosts. It does not
prove real two-Mac synchronization. The separate libmpv fixture uses generated
media and two real engines without video/audio output. Actual SMB round trips,
native context-menu accessibility and installed-app appearance remain runtime
checks. Use the [acceptance checklist](multiplayer-testing.md) for both Macs.
