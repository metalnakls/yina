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
