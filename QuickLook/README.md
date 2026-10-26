# yina Quick Look support

yina embeds QuickLookVideo's format reader, video decoder and Spotlight importer.
Finder keeps its native playable Quick Look, thumbnail and Get Info surfaces;
yina supplies support for additional containers and codecs through AVFoundation.
The extensions use the FFmpeg libraries already bundled with yina.

## Enable

At a normal startup, yina decodes the bundled synthetic `quicklook-probe.webm`
to check the format reader and decoder. If macOS reports a disabled Media
Extension, a native dialog offers **Open System Settings**, focused on Media
Extensions, and **Not Now**. Enable **yina media formats** and **yina video codecs**
once; subsequent launches skip the dialog while decoding succeeds. The check
runs asynchronously, reads no personal media, and defers its dialog while another
modal panel or sheet is open. Command-line and clean-start launches skip it.
Other decoding errors are logged rather than misreported as disabled extensions.
macOS controls discovery and selection; installation does not imply enablement.
You do not need to keep yina running. Another installed QuickLookVideo provider
may compete for the same types; choose the provider in System Settings.

The format reader advertises the upstream containers (MKV, WebM, AVI, WMV/ASF,
Ogg video, FLV, RealMedia, MXF and others), including yina's `io.yina.*` UTIs.
Apple continues reading native MP4/MOV containers. The decoder also advertises
upstream's additional codecs found inside MOV/AVI, such as Sorenson and Cinepak.
This integration does not force an override of Apple's native readers or codecs.
Quick Look does not gain yina's subtitle, audio-track or chapter controls.

## Source and license

Source: https://github.com/Marginal/QuickLookVideo
Pinned revision: `276ee9ee1be40ac58a6184e95ea5a433ca633719`.
Copyright © 2014–2026 Jonathan Harris. GPL-2.0-or-later; see `LICENSE.txt`.
The upstream source headers are retained. yina modifications are distributed
under the repository's GPLv3 license.

Local adaptations:

- Separate yina bundle identifiers, logging subsystem, metadata attributes and
  Spotlight factory UUID; no dependency on an installed QuickLook Video app.
- No shared app-group preferences; keep upstream's default snapshot position.
- Public FFmpeg resampler API with an opaque context, avoiding private headers.
- Close the Spotlight demuxer on every return path.
- Build against yina's existing FFmpeg 9 libraries and embed in the yina bundle.

`include/` supplies the FFmpeg 9.0.1 public headers
missing from the existing dependency header set. Source:
https://github.com/FFmpeg/FFmpeg/tree/n9.0.1 . Their original license notices are
retained. These headers must match the major versions of `deps/lib`.

Apple's MediaExtension API and activation requirements:
https://developer.apple.com/documentation/mediaextension/supporting-custom-media-formats-and-decoders

The format reader and decoder require Apple provisioning profiles carrying their
Media Extension capabilities. A plain `codesign --verify` success does not check
that requirement. The local build script finds matching, unexpired profiles in
Xcode's standard profile stores, verifies the app identifier, capability and exact
signing certificate, embeds them, and signs with their application identifier.
It stops before modifying the installed app when a matching profile is missing.
Profiles and signing keys stay outside the repository.

Temporary Xcode products are unregistered on build exit; only the installed app
should be listed under Media Extensions. This prevents duplicate settings rows.

The release lane requires an explicit `YINA_RELEASE_CODESIGN_IDENTITY` Developer
ID Application certificate and matching profiles. Ad-hoc releases cannot carry
these restricted capabilities. No release identity is selected automatically.

## Runtime checks

`other/tests/quicklook-media-smoke.swift` reads video and audio and seeks for an
image through AVFoundation. Use synthetic MP4, MKV, WebM, AVI and MOV fixtures.
A passing result can come from another enabled provider: confirm yina's bundle
identifier in system logs before attributing playback to yina.

`other/tests/quicklook-metadata-smoke.m` loads the specified metadata importer
directly and checks dimensions and duration for a synthetic 160×90 MKV. This
also catches an incorrect runpath for the nested Spotlight bundle.
