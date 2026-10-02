# Progress updates

When sending progress updates during longer tasks, title them with a short level-1 Markdown heading.

# Local Nightly build

For normal implementation work in this checkout, finish with `other/build_install_nightly.sh`. It builds the locked local packages, signs with `919F9538E1E91B7C10FD2556CC9030B76ED39E58`, verifies the final bundle, refreshes the contents of `/Applications/yina.app`, and retains one prior verified build at `/Users/wsb/iinatoo/.build-backups/yina.app`.

Run this build with approved elevated local/keychain access by default. The signing identity's private key belongs in the macOS Keychain, not the workspace. A sandboxed or non-elevated check may report zero valid identities; if that happens, retry the same build in the elevated local context with the exact identity above. Never export the private key into the repository or substitute another signing identity.

For build-script, CI/CD, or local-app-signing changes—or when that script cannot complete—consult `/Users/wsb/.codex/skills/app-build-install-scripts/SKILL.md` and `/Users/wsb/.codex/skills/macos-app-signing/SKILL.md`.

# Explicit cleanup

Only when the user asks to remove local YINA build artifacts, run `other/clean_local_build_artifacts.sh --apply`. It preserves the installed app, the rotating backup, source, locked packages, and registered Git worktrees.
