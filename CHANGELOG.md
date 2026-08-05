# Changelog

## [Unreleased]

## [0.2.4] - 2026-08-05
- The mouse cursor now hides automatically after a moment of inactivity in full screen, matching the playback controls

## [0.2.3] - 2026-08-05
- When leaving full screen, a click-to-return prompt now appears immediately instead of waiting for the screen transition to finish

## [0.2.2] - 2026-08-05
- Lower the minimum window width so the player can be resized narrower (480pt instead of 560pt)

## [0.2.1] - 2026-08-04
- The video list now automatically scrolls to keep the currently playing file in view
- Folders in the library root now show a folder icon
- The current folder's path moved from the sidebar into the status bar

## [0.2.0] - 2026-08-04
- Add support for playing audio files
- Automatically advance to the next file when playback ends naturally
- Restart the current video from the beginning instead of only skipping back within the first 3 seconds played
- Fix losing the highlighted selection when navigating back, and simplify the empty-state placeholder text

## [0.1.2] - 2026-08-04
- Fix Previous/Next sometimes not responding and losing the highlighted selection

## [0.1.1] - 2026-08-04
- Add playback speed control, with presets from 0.5x to 2x
- Repeat button in a single-video window now toggles repeat on/off directly,
  instead of cycling through an all/one distinction that didn't apply

## [0.1.0] - 2026-08-04
- First tagged release, distributed as a signed and notarized DMG on GitHub
  Releases with Sparkle auto-update
- Folder-based library with filesystem watching, plus single-file playback
  in its own window
- Playback progress kept per file and shared across windows
- Timeline scrubbing with hover frame previews, generated via AVFoundation,
  Homebrew ffmpeg, or mpv depending on the container
- Embedded subtitle and audio track selection, plus external subtitle loading
- Queue controls: previous, next, shuffle, repeat all, repeat one
- Full screen playback, Now Playing integration, and media-key/remote controls
- Broad local video support through a bundled libmpv/ffmpeg runtime, so the
  app runs without Homebrew installed
