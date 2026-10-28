# Show inventory reader

YINA reads Glass's version-one `.yina.json` inventory without modifying the
manifest, playlist, media, transfer selection, or playback position. Discovery
and bounded local-file checks run on a utility operation queue. Stale results
from another loaded file are discarded.

The reader accepts at most 4 MiB and 20,000 records, rejects duplicate identities,
duplicate or unsafe relative paths, and reports snapshots older than 15 minutes
as uncertain. Only the first 16 records receive local-file checks; unchecked
files are labelled accordingly. An incomplete or missing episode is information,
not a playable placeholder in the MPV playlist.

This is inventory display only. It does not implement shared playback, a
version-two room descriptor, download requests, or shared resume positions.

Run the decoder regression checks without launching an app:

```sh
xcrun swiftc -module-cache-path /tmp/yina-index-module-cache \
  yina/ShowEpisodeIndexReader.swift other/tests/show-index-decoding-smoke.swift \
  -o /tmp/yina-index-smoke
/tmp/yina-index-smoke
```
