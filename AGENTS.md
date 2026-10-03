# Progress updates

When sending progress updates during longer tasks, title them with a short level-1 Markdown heading.

# Local Nightly build

For normal implementation work in this checkout, finish with `other/build_install_nightly.sh`. It builds the locked local packages, signs with `919F9538E1E91B7C10FD2556CC9030B76ED39E58`, verifies the final bundle, refreshes the contents of `/Applications/yina.app`, and retains one prior verified build at `/Users/wsb/yina/.build-backups/yina.app`.

Run this build with approved elevated local/keychain access by default. The signing identity's private key belongs in the macOS Keychain, not the workspace. A sandboxed or non-elevated check may report zero valid identities; if that happens, retry the same build in the elevated local context with the exact identity above. Never export the private key into the repository or substitute another signing identity.

For build-script, CI/CD, or local-app-signing changes—or when that script cannot complete—consult `/Users/wsb/.codex/skills/app-build-install-scripts/SKILL.md` and `/Users/wsb/.codex/skills/macos-app-signing/SKILL.md`.

# Versioning

yina uses one version number for both `CFBundleVersion` and `CFBundleShortVersionString`, set through the `YINA_VERSION` build setting in `Configs/Deployment.xcconfig`. Sparkle compares `CFBundleVersion`, so it must rise for every release or no update is offered.

The release version lives in the `VERSION` file at the repository root. Local builds derive a date-based version (`YYYYMMDDHHMM`) so debugging never modifies the repository. Releases pass `YINA_VERSION="$(cat VERSION)"` to `other/build_install_nightly.sh`.

Bump `VERSION` in the same commit as the change you want to ship. This is yina's own scheme: it does not track upstream IINA's version numbers. Keep upstream's history and provenance intact, but do not adopt its versioning.

Cut releases from the `swift` branch only: `git tag v<VERSION> && git push yina v<VERSION>`. The repository also carries 66 upstream IINA release tags, and some of them sit on the `swift` line, so the `Appcast` workflow refuses to publish any tag that is not an ancestor of `origin/swift`. Pushing an upstream tag here fails instead of publishing upstream code as yina.

# Signing

`other/build_install_nightly.sh` signs with the Apple Development identity whose SHA-1 is the `DEFAULT_SIGN_IDENTITY` constant. Set `IINA_CODESIGN_IDENTITY` to override it. The private key stays in the macOS Keychain and is never exported into the repository. Never substitute a different identity without asking.

When a signing identity is ambiguous or the invocation is non-interactive, fail loudly rather than guessing. Never silently default to one of several available identities.

# Sparkle updates

`yina/Info.plist` sets `SUFeedURL` and `SUPublicEDKey`. Both must describe yina's own release channel. Do not point `SUFeedURL` at upstream IINA infrastructure: an update served there would install over a yina build. The EdDSA private key used by `sign_update` lives in the macOS Keychain or a CI secret, never in the repository. `yina/dsa_pub.pem` is retained because Sparkle still resolves `SUPublicDSAKeyFile` as a legacy fallback.

# Explicit cleanup

Only when the user asks to remove local YINA build artifacts, run `other/clean_local_build_artifacts.sh --apply`. It preserves the installed app, the rotating backup, source, locked packages, and registered Git worktrees.
