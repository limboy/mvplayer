---
name: install
description: Build MVPlayer as an optimized Apple-silicon macOS Release app, package the resulting .app as a zip, and install it locally. Use when the user asks to build, package, install, or locally deploy MVPlayer from this repository.
---

# Install MVPlayer

Use this skill from the MVPlayer repository root to produce and install a local
Release build. The workflow regenerates the Xcode project from `project.yml`,
builds the shared `MVPlayer` scheme for `macOS arm64`, validates the app bundle,
creates `build/Release/MVPlayer.zip`, and copies the app into the local
Applications folder.

## Workflow

1. Confirm that the host is macOS and that `xcodebuild`, `xcodegen`, and
   `ditto` are available. Do not install missing tools automatically.
2. Confirm that Homebrew `mpv` is installed before installing the app. MVPlayer
   loads `libmpv` at runtime; a successful build does not guarantee playback
   works without it. If it is missing, stop and tell the user to run
   `brew install mpv`.
3. Run the bundled script from the repository root:

   ```sh
   bash skills/install/scripts/install_release.sh
   ```

   By default it installs to `~/Applications/MVPlayer.app`. It always writes
   the Release package to `build/Release/MVPlayer.zip` and reports the original
   built app at `build/Build/Products/Release/MVPlayer.app`.
4. If the user explicitly requests the system Applications folder, pass
   `--install-dir /Applications`. For a different local destination, pass an
   absolute or project-relative path with `--install-dir`.
5. Use `--launch` only when the user asks to open the app after installation.
   Use `--no-install` when packaging or validating a build without changing an
   installed copy. Use `--no-generate` only when the checked-in Xcode project
   should be used as-is.
6. Report the package path, built app path, install path, and any prerequisite
   or signing limitation. Do not describe the app as App Store-ready: this
   project intentionally loads Homebrew libraries outside the bundle and
   disables library validation for local use.

## Failure handling

- Treat the first actionable `xcodebuild` error as the build failure to
  investigate; ignore cascaded diagnostics until the root cause is fixed.
- If `/Applications` is not writable, retry only after the user chooses an
  install destination or grants permission. The default `~/Applications`
  destination should not require administrator access.
- Do not delete or reset source files. The script only replaces the generated
  Release package and the selected installed app destination.

## Bundled resource

Run [`scripts/install_release.sh`](scripts/install_release.sh) for the
deterministic build, packaging, validation, and installation sequence.
