# Show inventory reader

YINA reads Glass's per-writer transfer snapshots within `.yina/`, identified by
`.yina/show.json`. Recognized old root `.yina.json` inventories and descriptors
migrate into that folder without losing identity or inventory bytes. Discovery and bounded local-file
checks run on a utility operation queue. Results from another loaded file are
discarded. Reading the inventory never changes the mpv playlist or its order.

Each manifest is capped at 10 MiB and the combined catalog at 20,000 records.
Fragment discovery is capped at 4,096 directory entries and 64 MiB. Duplicate
identities, duplicate or unsafe relative paths, invalid numbering, and invalid
byte totals are rejected. Future snapshots and snapshots older than 15 minutes
are uncertain. Conflicting torrent paths remain unknown and cannot be requested.

Only the first 128 catalog records receive local-file checks; unchecked files are
labelled accordingly. Download completeness requires a fresh complete snapshot
and a matching regular-file size. A sparse file's existence or size alone is
never evidence of completeness. Completion is independent of `wanted`; partial
bytes do not imply active downloading.

Unavailable Episodes stays separate from the playable queue. Its native context
menu can save an exact, fresh episode request for Glass. The caption reports that
the request was saved, not that a download started. See [Shared shows](shared-shows.md)
for progress, requests, and explicit watch-together controls.

Run the decoder regression checks without launching an app:

```sh
xcrun swiftc -parse-as-library -module-cache-path /tmp/yina-index-module-cache \
  yina/SharedShowStore.swift yina/ShowEpisodeIndexReader.swift \
  other/tests/show-index-decoding-smoke.swift \
  -o /tmp/yina-index-smoke
/tmp/yina-index-smoke
```
