# mpv and libplacebo upstream review — 2026-11-08

## Decision and sequence

Update the dependency pair first, preserving native Metal and direct VideoToolbox;
then restructure playback-state ownership and PiP transitions. This investigation
changes no dependency pins, production source, installed application, or running
player. It does not establish that an upstream change fixes the rare PiP stutter.

## Verified source state

The main repository still has `origin=https://github.com/iina/iina.git` and a
separate `yina` remote. Dependency versions are explicitly pinned in
[`manifest.json`](../other/metal-deps/manifest.json); `build.sh` fetches exact
commits rather than following current branches. Ordinary application builds do
not update these sources.

| Dependency | Current source | Proposed release base | Divergence |
|---|---|---|---|
| mpv | lhc70000/mpv `97179bce7ed980c53647d6344916f632fe689e9e`, branch `libmpv-gpu-next` | 0.42.0, `b0841e8c4d156b8403dc1876c4cbd9011eb583f3`, released Nov 5 | 1 fork-only / 631 upstream-only commits |
| libplacebo | lhc70000/libplacebo `a96296875a067887fc75d7b74a0a4292422c204d`, branch `metal-expr` | 7.387.0, `275f7dea27924cdd34ab2e6c20e448b6bc4fab65`, released Oct 25 | 1 fork-only / 212 upstream-only commits |

These are commit-graph counts, not counts of relevant improvements. Current
branch tips still equal our pins; the fork's default branch is not the branch we
build. Counts exclude YINA's separately applied local patches.

Sources: [mpv release](https://github.com/mpv-player/mpv/releases/tag/v0.42.0),
[libplacebo release](https://github.com/haasn/libplacebo/releases/tag/v7.387.0),
[mpv fork](https://github.com/lhc70000/mpv/tree/libmpv-gpu-next),
[libplacebo fork](https://github.com/lhc70000/libplacebo/tree/metal-expr).
Both release refs were fetched into `refs/research/` in the existing dependency
source repositories; `git rev-list --left-right --count HEAD...refs/research/<tag>`
produced the counts. The dirty patched source checkouts were not switched.

## Why the update is worth evaluating

- **Queue memory reclamation:** libplacebo
  [`ca33bdac`](https://github.com/haasn/libplacebo/commit/ca33bdacfdc96ad1057364aa2faefe1c20c71d72)
  frees recycled textures on `pl_queue_reset`, rather than retaining that GPU
  cache indefinitely. This is relevant to memory after queue reset/end-of-stream;
  it does not imply a measured reduction during steady direct-hardware playback.
- **Queue lifetime and timing:** release history includes init-failure UAF fixes,
  double-precision timing, revised still-frame handling, and explicit queue
  status. These affect infrastructure our custom backend uses. See
  [queue source at 7.387.0](https://github.com/haasn/libplacebo/blob/v7.387.0/src/utils/frame_queue.c)
  and [queue interface](https://github.com/haasn/libplacebo/blob/v7.387.0/src/include/libplacebo/utils/frame_queue.h).
- **HDR/shader correctness:** libplacebo adds tone-mapping and scene-statistics
  changes, black-level/dithering fixes, and shader data-race fixes. These warrant
  image comparisons, because a newer library can intentionally change output.
  [Release notes](https://github.com/haasn/libplacebo/releases/tag/v7.387.0).
- **libmpv correctness:** mpv
  [`7a94ec571`](https://github.com/mpv-player/mpv/commit/7a94ec5719f3c09a6056cc6e5297a29c8ba2efdf)
  uses renderer-backend capabilities for source/destination calculations, fixing
  rotation behavior for backends that lack the VO's advertised capabilities.
  Preserve it when porting our renderer integration.
- **Playback/streaming:** upstream-only history includes transient-EOF restart,
  decoder failure handling, and curl retry/empty-response fixes. Curl work applies
  to URL playback, not automatically to files on mounted SMB shares. The Dolby
  Vision enhancement-layer surface-budget change is specific to that path, not a
  general queue-size reduction. [mpv release](https://github.com/mpv-player/mpv/releases/tag/v0.42.0),
  [surface budget change](https://github.com/mpv-player/mpv/commit/b955aa28f3dc93dc6b21485a0d5b7feb8e6dc10f).

mpv 0.42 requires libplacebo >=7.387.0. Treat the pair as a coordinated update.
Do not describe every release feature as new relative to our June development
base: some already existed there.

## Actual porting work identified

Release source trees were extracted into disposable repositories under
`build/upstream-review/`. `git apply --check` against each fork's single commit
fails in these files (not a compile test):

| Fork patch | Conflicts | Required handling |
|---|---|---|
| mpv gpu-next/libmpv | `include/mpv/render.h`, `video/out/vo_gpu_next.c` | Reconcile render parameters and forward-port shared rendering helpers against newer gpu-next logic |
| libplacebo Metal | `meson.build`, `src/cache.h` | Keep the release API version/cache changes while adding the Metal backend and its own shader-cache key |

**ABI conflict:** the fork allocates Vulkan initialization/FBO parameters 21/22;
mpv 0.42 officially allocates 21/22 to D3D11. Preserve official identifiers and
allocate the custom parameters consistently. Regenerate/copy the matching public
headers and rebuild YINA against the same library. Do not mix old custom headers
with a new library. [Official render.h](https://github.com/mpv-player/mpv/blob/v0.42.0/include/mpv/render.h),
[fork render.h](https://github.com/lhc70000/mpv/blob/97179bce7ed980c53647d6344916f632fe689e9e/include/mpv/render.h).

The official trees have no `render_mtl.h` or libplacebo Metal implementation.
Updating to plain release binaries would lose our render path. Keep the existing
Metal backend for the first migration; assess alternate backends separately.

Our local AVFoundation resume correction and direct VideoToolbox import/cache
changes remain necessary: `audio/out/ao_avfoundation.m` and
`video/out/hwdec/hwdec_vt_pl.m` have no upstream diff between the pinned mpv source
and 0.42. The local patch also owns render-context hardware-device registration,
mapper/frame lifetime, and RA teardown. Carry all of these forward deliberately.
See [local patch](../other/metal-deps/patches/mpv-metal-macos.patch).

## Alternate Metal work: promising, not an adopted upstream backend

- [GitLab MR !858](https://code.videolan.org/videolan/libplacebo/-/merge_requests/858)
  proposes another native Metal backend. The canonical GitLab API reports
  `state=closed`, `merged_at=null`, updated Oct 31; closed does not mean merged.
  Its [GitHub discussion](https://github.com/haasn/libplacebo/issues/370) claims
  later hardening including command-buffer batching and private textures. These
  are author reports, not locally verified results. GitLab notes returned 401,
  so the reason for closure was not established.
- [GitHub issue #380](https://github.com/haasn/libplacebo/issues/380) proposes a
  separate metal-cpp backend, with import and cross-backend tests. It remains an
  open proposal; its own description lists missing thread-safety support and
  lack of waiting for in-flight GPU work at destruction. Do not adopt it solely
  on benchmark/test claims.

These are useful review material, especially for synchronization tests. Replacing
our backend while upgrading the dependency base would combine two substantial
changes and obscure regressions.

## Implementation and acceptance plan

1. Build an isolated 7.387.0 source tree with the existing Metal patch ported;
   run its library/GPU tests. Record exact source hashes and patch series.
2. Port libmpv integration onto 0.42, resolve parameter IDs and newer gpu-next
   interfaces, then reapply YINA's audio/direct-decoding/lifetime fixes.
3. Rebuild the dependency closure and headers together. Update the manifest and
   library inventory only to the versions actually tested.
4. Run generated-media tests for direct H.264/10-bit HEVC and software fallback,
   screenshots, pause/reset/resume, seek/EOF/reopen, hidden playback, paused
   resize/backing-scale changes, and PiP-style reparenting. Existing entry points:
   `metal-videotoolbox-smoke.sh`, `mpv-avfoundation-smoke.sh`,
   `avfoundation-underrun-smoke.py`, `paused-metal-resize-smoke.py`,
   `pip-transition-smoke.py`, `pip-layout-smoke.py`, `pip-backdrop-smoke.py`.
5. Compare matched HDR/SDR output, frame timing, GPU cache creation counts and
   physical footprint. Do not infer rare PiP stability from passing short tests;
   retain the automatic traces. Live SMB and long-run transitions remain separate
   acceptance checks.
6. Commit dependency updates independently; then begin the playback-state module
   and PiP-transition module work using the IINA findings as input.

No dependency update, backend port, new build or release was performed by this
research. The installed/running player was left untouched.
