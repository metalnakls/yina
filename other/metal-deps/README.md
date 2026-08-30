# Metal dependency stack

This directory pins the experimental libmpv gpu-next/Metal API and its matching
libplacebo Metal backend. It deliberately keeps mpv's OpenGL libmpv backend in
the same build until IINA passes the full playback parity gate.

Run `other/metal-deps/build.sh` on Apple Silicon with Xcode 27. The script:

- rejects non-arm64 hosts, SDK drift, and Homebrew version drift;
- checks out exact mpv, libplacebo, libplacebo-submodule, and libdovi commits;
- applies the two macOS build fixes needed by the pinned experimental mpv commit;
- builds arm64/min-macOS-27 libdovi, libplacebo, and libmpv;
- enables both OpenGL and Metal libmpv render APIs plus both VideoToolbox paths;
- runs all libplacebo and mpv tests and a real CAMetalLayer playback smoke; and
- packages the complete transitive dylib closure with `@rpath` install names; and
- verifies every packaged Mach-O is arm64 with a macOS 27 minimum.

The build prefix is `build/metal-deps/prefix`; the relocatable dylib closure is
`build/metal-deps/package/lib`. The script does not overwrite `deps/` or install
an application. `manifest.json` records the primary-source hashes
for FFmpeg, shaderc, and SPIRV-Cross; `homebrew.lock` records the exact bottles
and transitive versions used by the verified build. This is intentional while
the Metal APIs are experimental: dependency drift fails closed.

The pinned cargo-c release emits a shared libdovi that Xcode 27 rejects for a
malformed `LINKEDIT` string pool. The builder links cargo-c's valid arm64 static
archive into libplacebo instead. No libdovi dylib is shipped.

After replacing `deps/lib` with the packaged closure, regenerate the Xcode link
and Copy Dylibs phases from that exact directory:

```sh
ruby other/metal-deps/update-xcode-libraries.rb
```

Build the temporary Metal renderer by adding `IINA_ENABLE_METAL_RENDERER` to
`SWIFT_ACTIVE_COMPILATION_CONDITIONS`. Without that internal condition, IINA
continues to compile its OpenGL fallback.
