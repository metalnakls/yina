# Shared show storage

A show has one metadata folder at its selected root: `.yina/`. All paths in
the protocol are relative to that root. The show descriptor is
`.yina/show.json`, an immutable schema 2 record containing `showID` and
`createdAt`. New shows never create a root `.yina.json` file. Each writer keeps
its own records, so an offline participant cannot overwrite another writer's
progress or queue.

| Record | Path within `.yina/` | Purpose |
| --- | --- | --- |
| `show.json` | root of folder | Immutable show identity |
| `legacy-index.json` | root of folder | Byte-identical recognized v1 inventory retained after migration |
| Transfer | `transfers/<writerID>/<hash>.json` | Per-writer Glass inventory snapshot |
| Progress | `progress/<participantID>/<writerID>.json` | Per-writer playback state |
| Demand | `demand/<writerID>.json` | Explicit request for a Glass selection/download |
| Queue | `queues/<writerID>.json` | Host-owned ordered playback paths |
| Receipt | `receipts/<glassWriterID>/<requestID>.json` | Durable Glass acknowledgement of a demand revision |

## Migration and discovery

Discovery recognizes both `.yina/show.json` and the old root `.yina.json`.
The old root file must be a strictly recognized schema 1 inventory or schema 2
descriptor, with no unknown fields. A schema 1 inventory derives its show ID
from the existing `glass-yina-show-v2:<normalized hash>` SHA-256 rule. Its
original bytes move unchanged into `.yina/legacy-index.json`; the derived
descriptor is published at `.yina/show.json`. A schema 2 descriptor moves to
`.yina/show.json` without changing its bytes or show ID.

Migration publishes each destination without replacement, validates the
published bytes, and atomically moves the root file to a unique quarantine
name before removal. A changed source, conflicting destination, unexpected
field, or symlink stops migration and preserves the conflicting bytes. A
matching quarantine file can be finalized after an interrupted run. An
orphaned valid `legacy-index.json` can reconstruct the deterministic
descriptor. If a mounted filesystem cannot complete exclusive publication or
the quarantine move, recognized old metadata stays readable; writes wait
until canonical publication succeeds. No migration deletes a transfer, progress,
demand, or other participant record.

## Host queues

Queue schema 1 fields are `showID`, `participantID`, `writerID`, monotonically
increasing `revision`, `updatedAt`, ordered `items` (relative path strings),
and optional `current`. If present, `current` must be in `items`. A queue has
at most 1,024 paths and 256 KiB of path text. Paths must be unique after
Unicode normalization and case folding; absolute paths, traversal, metadata
paths, backslashes, and NULs are rejected. Queue publication is an atomic
replacement of that writer's file after its identity and revision are checked.
Followers only use a queue from the selected host identity and pair its
`current` with the matching progress target.

`resolvePlayable` uses a no-follow directory walk. An unmanaged regular file
inside the show can play. A path present in a transfer inventory can play only
when the inventory is fresh, unambiguous, marked completely received, and the
regular file's current size exactly matches the declared total. Catalog lookup
uses the same normalized casefold path key as duplicate detection, so a path's
capitalization cannot turn a partial managed file into an unmanaged one. Missing,
partial, stale, truncated, or symlinked managed paths do not play. This check
never deletes media or assumes that a missing share is permanently offline.

## Demand receipts

A receipt has schema version 1, `showID`, `requestID`, `requestWriterID`,
`receiptWriterID`, a receipt-writer `revision`, the originating
`requestRevision`, `updatedAt`, and `outcome` (`accepted`, `failed`, or
`cancelled`). Only failed receipts carry a generic reason:
`selectionFailed`, `priorityFailed`, or `startFailed`. The requesting client
compares both the request writer and request revision with its current demand;
an older receipt cannot acknowledge a newer retry. Receipt timestamps are
informational, so modest clock skew between Macs does not hide a durable
acknowledgement; malformed or foreign receipts fail closed. An accepted receipt reports
that Glass accepted the request, not that the media is already complete or
playable. No credentials, absolute paths, or private filenames belong in
receipts.

YINA polls receipts on the same bounded per-root worker lane and permits only
one read in flight per session. Missing or unreadable receipts do not resend a
demand. After 15 minutes without an answer, the request becomes an explicit
Retry/Withdraw choice. Retry keeps the request ID and publishes a newer
revision after revalidating the transfer. Withdrawing a still-pending request
publishes a newer cancelled revision, even when the earlier publish is waiting
on a slow share. Withdrawal does not claim to stop a download Glass already
accepted.

The filesystem fixtures use temporary local folders and cover fresh creation,
v1/v2 migration, interrupted publication, conflicts, independent writers,
queue revisions, malformed records, symlinks, and partial or stale media. Real
SMB latency, disconnected mounts, and simultaneous YINA/Glass use remain
runtime checks.
