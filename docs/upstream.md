# Upstream adoption ledger

This fork follows upstream selectively. It is not intended to converge on upstream's UI or renderer architecture.

## Fork constraints

- Playback is based on mpv-next and the libmpv render API.
- Video output is Metal/CAMetalLayer. OpenGL-specific patches must be re-expressed at the renderer boundary, not cherry-picked mechanically.
- The fork's HDR/EDR behavior, target-peak handling, inverse tone mapping, and display-profile authority must remain intact.
- The welcome window has been rebuilt. Welcome-window fixes are ported into that model rather than restoring the upstream controller structure.
- AppKit remains authoritative for playback windows, rendering, PiP, dynamic menus, WebKit, and display integration.
- SwiftUI modernization starts after the pre-Swift integration branch documented here. Old Settings/XIB UI work is not a reason to expand the pre-Swift scope.

## Adopted for the pre-Swift branch

Source status was checked on 2026-09-12. Local hashes identify the final commits on `swift`.

| PR | Source status | Local commit | Decision | Fork treatment |
| --- | --- | --- | --- | --- |
| [#6351](https://github.com/iina/iina/pull/6351) | Open | `f9108adc` | Adopt | Honor global multi-window/group-playlist preferences when files are dropped on the refactored welcome window. Keep the fork's welcome architecture. |
| [#6211](https://github.com/iina/iina/pull/6211) | Open | `a19e19d2` | Adopt | Prefer longer media filenames during subtitle matching to avoid prefix collisions. |
| [#6334](https://github.com/iina/iina/pull/6334) by [low-batt](https://github.com/low-batt) | Open | `67f7ad50` | Adapt | Load ColorSync's current display profile through the Metal/libmpv option path. Do not reproduce upstream's `PlayerCore` or OpenGL `ViewLayer` changes, and do not disturb HDR/EDR or target-peak behavior. |
| [#6345](https://github.com/iina/iina/pull/6345) | Open | `b5578665` | Adapt | Reduce default-app UTI prompts and await consent at the service/model boundary. Do not use it to extend the legacy Settings UI. |
| [#6350](https://github.com/iina/iina/pull/6350) | Closed, unmerged | `67fc5b0b` | Adapt | Open allowed plugin `http`/`https` links externally through a narrow policy boundary. The source PR was not merged, but the behavior remains useful to the fork. |
| [#6256](https://github.com/iina/iina/pull/6256) | Open | `513a5ec5` | Adopt | Add frame-precision time display. Keep its model useful to the later multiplayer work. |
| [#5959](https://github.com/iina/iina/pull/5959) | Open | `a17a0c03`, `4b9003ee` | Adapt | Take the timer tolerance, occlusion, visual-effect, asynchronous subtitle-search, thumbnail-write, and dead-timer energy improvements. Map visual-effect changes onto the fork's refactored translucent views; include low-batt's main-thread review correction. |

The verified welcome merge (`1baf64a9`, subject `welcome`) is the base of this stack and is included in the `swift` branch.

## Watch or defer

| PR | Status here | Reason |
| --- | --- | --- |
| [#6190](https://github.com/iina/iina/pull/6190) | Maybe, low priority | Relative paths in saved playlists are portable and useful, but not required for the pre-Swift stack. Re-evaluate after the current integrations settle. |
| [#6214](https://github.com/iina/iina/pull/6214) | Leave for now | Numpad key distinctions are useful but unrelated to the current renderer, welcome, and pre-Swift integration goals. |
| [#6337](https://github.com/iina/iina/pull/6337) | Deep review later | Plugin teardown is high-value, but the draft is too large to mix into this integration stack without a dedicated lifecycle review. |
| [#6176](https://github.com/iina/iina/pull/6176) | Defer | AppKit sidebar scroll forwarding may be replaced or reshaped by the next SwiftUI work. |
| [#6276](https://github.com/iina/iina/pull/6276) and [#6307](https://github.com/iina/iina/pull/6307) | Ideas only | They overlap the fork's OSC and mini-player refactors. Compare behavior, not patches. |

## Already covered or not applicable

| PR | Decision | Reason |
| --- | --- | --- |
| [#6342](https://github.com/iina/iina/pull/6342) | Already covered | The malformed-filter crash fix is already present in the fork baseline. |
| [#5954](https://github.com/iina/iina/pull/5954) | Not applicable | The fork does not expose or use `tone-mapping-param`; revisit only if that option is introduced. |
| [#5744](https://github.com/iina/iina/pull/5744) | Skip | It modernizes the old XIB Settings implementation; the fork's next UI phase is SwiftUI. |
| [#5627](https://github.com/iina/iina/pull/5627) by [low-batt](https://github.com/low-batt) | Defer | Its author deferred the draft because of fullscreen distortion and unresolved geometry. Revisit only narrowly extracted fixes after renderer parity. |

## Permanent exclusion

| PR | Decision | Reason |
| --- | --- | --- |
| [#6265](https://github.com/iina/iina/pull/6265) | **Never adopt** | The draft adds large VR reprojection machinery inside the renderer. The fork does not need VR playback, and the design conflicts with its mpv-next, Metal/CAMetalLayer, subtitle, and timing architecture. Do not surface this PR in future candidate lists. |

## Review rule for future upstream changes

Check behavior against the current fork before proposing a port. Favor small correctness fixes, model/service boundaries, plugin safety, subtitle behavior, and changes that strengthen the future SwiftUI transition. Reject or deeply adapt patches tied to OpenGL, legacy Settings/XIB structure, superseded OSC/window code, or broad renderer rewrites. Record every adopted, deferred, superseded, and permanently excluded PR here.
