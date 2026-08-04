# Changelog

## [Unreleased]

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
