# Shared shows

YINA and Glass share a show folder through one hidden `.yina/` folder. Glass owns transfer
snapshots and download selection. YINA owns each player's progress and explicit
download requests. Existing mpv playlists, local watch-later data, and manual
subtitle selection keep their behavior.

## Using it

Open a local or mounted SMB episode normally. Use **File → Shared Show**,
the Playlist pane's **Shared Show** footer, or the current episode's context
menu. A valid Glass descriptor or legacy inventory is discovered automatically,
within 12 ancestors and the volume boundary. **Enable for This Show** uses the
nearest existing show identity. If none exists, it creates one in the open
file's containing folder. Opening an ordinary file alone never creates a descriptor.

Progress is saved while playing or paused. Another player's saved position is an
explicit **Resume at…** action for the episode already open. It does not replace
local resume automatically, open another file, or choose the furthest position.

Opening media from an enabled show starts an ephemeral Watch Together room on the local network. Another Mac sees the host and movie in its Welcome window without opening local history or scanning SMB. Clicking the room explicitly joins. Both Macs can then pause, seek, change speed, and switch episodes in the same show; the host serializes commands and broadcasts the result. Volume and subtitles remain local. **Leave Watch Together** disconnects that player. If the host disappears, the guest keeps its current file without replaying it. See [Watch Together](shared-show-watch-together.md).

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
| `.yina/receipts/<glassWriterUUID>/<requestUUID>.json` | Glass's durable outcome for one request revision |

The participant UUID persists in the local app profile; each player gets a new
writer UUID. Positions from different writers remain separate, including older
sessions. This is a set of current/last session positions, not a complete history
of every episode watched. Progress never authorizes cache eviction.

A progress record has `schemaVersion: 1`, `showID`, `participantID`, `writerID`, monotonic `revision`, ISO-8601 `updatedAt`, `relativePath`, `position`, `duration`, and `activity` (`playing`, `paused`, or `stopped`). YINA adds an optional playback rate. These records are an archive and do not advertise live presence or authorize automatic playback. The current Glass decoder ignores the extension and can still read the progress record. YINA accepts Glass's optional coverage field without interpreting it as watched or changing another writer's file.

Recognized old root `.yina.json` files migrate into `.yina/`, preserving their
identity and original bytes. Version-one inventories become `legacy-index.json`
and retain Glass's deterministic SHA-256 show ID. Unknown, conflicting, or malformed
metadata is preserved. See [storage and migration](shared-show-storage.md). No old multiplayer-branch implementation is merged.

Writes use a temporary file, `fsync`, then an atomic rename into the writer's own
path. Metadata ancestors and leaf files are opened without following symlinks.
Request paths are revalidated even beyond the catalog's local-file-check limit.
No credentials, absolute media paths, or network addresses are written.

## Timing and failure behavior

Four bounded utility lanes perform filesystem work. Each root with work in flight keeps its lane and write order; a stalled root leaves other lanes available. Checkpoints coalesce while a share is slow, so UI actions and live LAN playback do not wait for SMB. Progress checks every ten seconds normally and every two seconds while hosting. The host sends live room snapshots directly over Network.framework; Bonjour discovery never reads the share. Frames and peer counts are bounded, and commands are scoped to an ephemeral room and increasing revision.

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
  yina/SharedShowSession.swift yina/SharedShowLAN.swift \
  yina/SharedShowDownloadRequest.swift yina/PlayerState.swift \
  other/tests/shared-show-session-smoke.swift -o /tmp/yina-shared-session-smoke
/tmp/yina-shared-session-smoke
```

`other/tests/shared-show-glass-smoke.swift` additionally compiles with Glass's
actual `Models.swift`, `TorrentNameCleaner.swift`, `ShowEpisodeIndex.swift`, and
`YinaShowStore.swift`. It checks Glass → YINA inventory, YINA → Glass progress and
demand, Glass → YINA progress, and identical
legacy IDs, byte-preserving migration in both directions, and receipts. It passed against the local `/Users/wsb/glass` sources on 2026-10-29.

The session fixture covers progress storage and explicit resume. The separate libmpv fixture uses generated media, two independent processes and two real engines to exercise direct Bonjour playback without video/audio output. Actual two-Mac SMB round trips and installed-app appearance remain runtime checks. Use the [acceptance checklist](multiplayer-testing.md) for both Macs.
