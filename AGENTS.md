# Progress updates

When sending progress updates during longer tasks, title them with a short level-1 Markdown heading.

# Local Nightly build

For normal implementation work in this checkout, finish with `other/build_install_nightly.sh`. It builds the locked local packages, signs with `2D7A6CBCAA6173CA3FC1904539A19C9800B39B78`, verifies the final bundle, refreshes the contents of `/Applications/Utilities/IINA.app`, and retains one prior verified build at `/Users/wsb/iinatoo/.build-backups/IINA.app`.

For build-script, CI/CD, or local-app-signing changes—or when that script cannot complete—consult `/Users/wsb/.codex/skills/app-build-install-scripts/SKILL.md` and `/Users/wsb/.codex/skills/macos-app-signing/SKILL.md`.

# Explicit cleanup

Only when the user asks to remove local IINA build artifacts, run `other/clean_local_build_artifacts.sh --apply`. It preserves the installed app, the rotating backup, source, locked packages, and registered Git worktrees.
