# NAS playback hang after wake

The user reported that YINA was already beachballing after waking the Mac on 2026-10-30, with media open from a NAS. It recovered before a thread sample could be captured. Power logs record wake at 18:42:22 Moscow time. The macOS spindump log records a **101.4-second slow HID response** ending at 18:44:05, followed by `not sampling due to conditions 0x80008002`. No fresh application hang report was found. The captured logs confirm a real UI stall but do not identify the original blocked stack.

Display and color-space notifications call `VideoView.updateDisplayLink()` and `refreshEdrMode()`. These paths synchronously queried source color metadata and set mpv output options on the UI thread. A delayed media engine can therefore stall the interface during display recovery. The original NAS reconnect remains a likely trigger rather than a proven stack-level diagnosis.

Display FPS and HDR/ICC/tone-mapping writes now use the existing asynchronous engine bridge. Source metadata and default option strings are fetched asynchronously. Generation, display, media and player-lifetime checks discard stale replies. AppKit display state stays on the main thread; native HDR transfer, SDR expansion and SDR-display fallback policies are retained.

`python3 other/tests/wake-display-refresh-smoke.py` executes the production display/HDR methods against an engine that deliberately delays synchronous calls. Before the change, the refresh blocked the test UI thread for 207 ms. Afterward it returns within the 50 ms test bound without waiting for a reply; stale-file, previous-display, superseded-request and stopped/released-player callbacks are rejected. This is a controlled engine-stall reproduction, not a reproduction of the user's actual sleep/NAS reconnect.

Additional checks: `hdr-source-policy-smoke.py` verifies source transfer and tone-mapping policy; `mpv-async-client-smoke.py` verifies native async string/default-option replies; `playback-ui-hdr-smoke.py` verifies overlay color and material behavior. An actual NAS sleep/wake pass is still needed to confirm the reported incident is resolved.

All four checks passed. `other/build_install_nightly.sh` then built, signed with the configured Keychain identity, verified and installed the local Nightly bundle in `/Applications/yina.app`. This patch has not been published as a new release.
