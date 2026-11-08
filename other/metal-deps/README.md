# Metal dependency stack

This directory pins upstream mpv 0.42.0 and libplacebo 7.387.0, with replayable
patches carrying the native Metal integration and YINA's audio/VideoToolbox fixes.
Vulkan is disabled in both libraries; the custom Vulkan render API and backend
are removed from our patch. The existing OpenGL libmpv fallback remains available.
The portable upstream trees still contain other platforms' declarations and
compile-time Vulkan headers/stubs; no Vulkan/MoltenVK runtime is used by YINA.

Run on Apple Silicon with Xcode 27 and the pinned Rust toolchain installed:

```sh
IINA_METAL_BUILD_ROOT="$PWD/build/metal-deps/release-042" other/metal-deps/build.sh
```

Use a fresh root for this migration: the old patched source checkout is retained
and must not be reset over local changes. Repeating the build accepts only clean
or exactly patched pinned sources. The script:

- rejects non-arm64 hosts, SDK drift, and Homebrew version drift;
- checks out exact mpv, libplacebo, libplacebo-submodule, and libdovi commits;
- applies `libplacebo-metal.patch` and `mpv-metal-macos.patch` against the release commits;
- builds arm64/min-macOS-27 libdovi, libplacebo, and libmpv;
- enables both OpenGL and Metal libmpv render APIs plus both VideoToolbox paths;
- runs all libplacebo and mpv tests and a real CAMetalLayer playback smoke; and
- packages the complete transitive dylib closure with `@rpath` install names; and
- verifies every packaged Mach-O is arm64 with a macOS 27 minimum.

The build prefix is `$IINA_METAL_BUILD_ROOT/prefix`; the relocatable dylib closure
is `$IINA_METAL_BUILD_ROOT/package/lib` (the default root is `build/metal-deps`). The script does not overwrite `deps/` or install
an application. `manifest.json` records the primary-source hashes
for FFmpeg, shaderc, and SPIRV-Cross; `homebrew.lock` records the exact bottles
and transitive versions used by the build. The update records the current supporting
FFmpeg 9.0.2, shaderc 2026.4 and SPIRV-Cross 1.4.363.0 inputs. Dependency drift
fails closed. Rust is selected by `target.rustToolchainVersion`; the builder
never installs a toolchain or replaces the caller's HOME.

The pinned cargo-c release emits a shared libdovi that Xcode 27 rejects for a
malformed `LINKEDIT` string pool. The builder links cargo-c's valid arm64 static
archive into libplacebo instead. No libdovi dylib is shipped.

After copying the complete packaged closure into `deps/lib`, regenerate the
Xcode link and Copy Dylibs phases from the package inventory. This excludes
obsolete libraries left by an earlier dependency build without deleting them:

```sh
ruby other/metal-deps/update-xcode-libraries.rb build/metal-deps/package/lib
```

Build the temporary Metal renderer by adding `IINA_ENABLE_METAL_RENDERER` to
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Without that internal condition, YINA
continues to compile its OpenGL fallback.

## Direct VideoToolbox on Metal

The pinned experimental `libmpv_gpu_next` backend originally exposed an empty
hardware-device list and accepted only software image planes. Consequently,
`hwdec=auto` selected `videotoolbox-copy` even without video filters. The local
patch initializes mpv's hardware-decoder interop against the libplacebo RA,
advertises supported hardware formats, and keeps a mapper alive with each queued
frame. CVMetalTextureCache imports the decoder's CVPixelBuffer planes; native
Metal wraps those textures with `pl_metal_wrap` rather than the Vulkan-oriented
`PL_HANDLE_MTL_TEX` import interface. No CPU plane upload is performed for these
hardware frames. Software decoding and explicitly requested copy-back remain
available when needed. Explicit screenshots may still read frames back to CPU.

Mapper cleanup precedes hardware-device/RA teardown. The patch also corrects the
RA wrapper destructor to leave allocation disposal to `ra_free`, avoiding a
double free once the importer uses that lifecycle.

`bash other/tests/metal-videotoolbox-smoke.sh` generates H.264, 10-bit HEVC and
MPEG-2 fixtures. It asserts `hwdec-current=videotoolbox` for the first two and
software fallback for MPEG-2, renders sixty frames per file, checks software and
renderer screenshots, and tears each context down. The direct-decoder assertion
failed with `videotoolbox-copy` before this patch. This establishes the removal of
copy-back for supported playback, not a measured percentage of total app RAM.

## Update validation and source provenance

The original native integration came from lhc70000/mpv `97179bce` and
lhc70000/libplacebo `a9629687`. The patches are now relative to the official
release commits recorded in the manifest. Upstream D3D11 parameter IDs 21/22
remain intact; our Metal initialization parameter is 23. Copy rebuilt headers
and libraries together. See [upstream review](../../docs/dependency-upstream-review-2026-11-08.md)
for porting decisions and validation requirements.

The test scripts accept `YINA_TEST_MPV_LIBRARY` for isolated package validation;
the audio-driver fixture also accepts `YINA_TEST_MPV_SOURCE`. Do not infer real
system PiP behavior from an ordinary replacement NSWindow: the actual PiP host
can report itself occluded while visibly presenting video.
