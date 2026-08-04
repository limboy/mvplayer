---
name: install-to-local
description: Build MVPlayer as an optimized Apple-silicon macOS Release app, package the resulting .app as a zip, and install it locally. Use when the user asks to build, package, install, or locally deploy MVPlayer from this repository.
---

# Install MVPlayer

Use this skill from the MVPlayer repository root to produce and install a local
Release build. The workflow regenerates the Xcode project from `project.yml`,
builds the shared `MVPlayer` scheme for `macOS arm64`, validates the app bundle,
creates `build/Release/MVPlayer.zip`, and copies the app into `/Applications`.

## Workflow

1. Confirm that the host is macOS and that `xcodebuild`, `xcodegen`, and
   `ditto` are available. Do not install missing tools automatically.
2. Confirm that Homebrew `mpv` is installed before installing the app. MVPlayer
   loads `libmpv` at runtime; a successful build does not guarantee playback
   works without it. If it is missing, stop and tell the user to run
   `brew install mpv`.
3. Run the bundled script from the repository root:

   ```sh
   bash skills/install-to-local/scripts/install_release.sh
   ```

   By default it installs to `/Applications/MVPlayer.app`. It always writes
   the Release package to `build/Release/MVPlayer.zip` and reports the original
   built app at `build/Build/Products/Release/MVPlayer.app`.
4. If the user asks for a per-user install, pass `--install-dir ~/Applications`.
   For a different local destination, pass an absolute or project-relative path
   with `--install-dir`.
5. Use `--launch` only when the user asks to open the app after installation.
   Use `--no-install` when packaging or validating a build without changing an
   installed copy. Use `--no-generate` only when the checked-in Xcode project
   should be used as-is.
6. Keep one installed copy. The script warns when another `MVPlayer.app` with
   the same bundle identifier sits in the other Applications folder, because
   LaunchServices may open that stale copy instead of the new build. Pass
   `--trash-duplicates` to move those copies to the Trash, but only after the
   user agrees to discard them.
7. Report the package path, built app path, install path, and any prerequisite
   or signing limitation. Do not describe the app as App Store-ready: this
   project intentionally loads Homebrew libraries outside the bundle and
   disables library validation for local use.

## Failure handling

- Treat the first actionable `xcodebuild` error as the build failure to
  investigate; ignore cascaded diagnostics until the root cause is fixed.
- If the default `/Applications` destination is not writable, retry only after
  the user chooses an install destination or grants permission.
  `--install-dir ~/Applications` does not require administrator access.
- If the installed app still behaves like an older build, suspect a second copy
  rather than a bad build. Compare
  `osascript -e 'POSIX path of (path to application id "me.limboy.mvplayer")'`
  with the install path, and check whether an old instance is still running.
  A newly installed copy may stay unbound until it is opened once by full path.
- Do not delete or reset source files. The script only replaces the generated
  Release package and the selected installed app destination, and moves
  duplicate app copies to the Trash when `--trash-duplicates` is passed.

## Bundled resource

Run [`scripts/install_release.sh`](scripts/install_release.sh) for the
deterministic build, packaging, validation, and installation sequence.
