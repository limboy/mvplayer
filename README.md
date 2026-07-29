# MVPlayer

MVPlayer is a native SwiftUI macOS video player backed by Homebrew's
`libmpv`. It targets macOS 14 or newer on Apple silicon.

## Features

- Native macOS interface built with SwiftUI.
- Folder-based video library with drag-and-drop folder importing.
- Persistent folder bookmarks and automatic filesystem change detection.
- Click-to-play browsing with automatic playback when a video is selected.
- Queue controls with previous, next, shuffle, repeat all, and repeat one.
- Responsive playback controls for seeking, volume, mute, and play/pause.
- Embedded subtitle track selection and external subtitle loading.
- Full-screen playback with a dedicated video window.
- Keyboard shortcuts for playback, seeking, volume, and full screen.
- Hardware-accelerated playback through `libmpv` when supported.
- Broad local video support, including MP4, MKV, MOV, AVI, WebM, MPEG,
  M2TS, FLV, WMV, and other formats handled by mpv.

MVPlayer provides its own playback interface and disables mpv's built-in Lua
overlays and online-video hooks. It is designed for local video playback.

## Requirements

- Xcode 26 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Homebrew mpv:

  ```sh
  brew install mpv
  ```

The app loads libmpv at runtime from `/opt/homebrew`. If it is unavailable,
MVPlayer opens a setup screen instead of failing at launch.

## Build

```sh
xcodegen generate
xcodebuild \
  -project MVPlayer.xcodeproj \
  -scheme MVPlayer \
  -destination 'platform=macOS,arch=arm64' \
  build
```

You can also open `MVPlayer.xcodeproj` and run the `MVPlayer` scheme.

## Local optimized Release build

This creates an optimized Apple silicon build for local use. Homebrew `mpv`
must be installed on the Mac running the app.

```sh
xcodegen generate
xcodebuild \
  -project MVPlayer.xcodeproj \
  -scheme MVPlayer \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$PWD/build" \
  clean build
```

The built app is located at:

```text
build/Build/Products/Release/MVPlayer.app
```

Launch it from the command line with:

```sh
open "build/Build/Products/Release/MVPlayer.app"
```

## Usage

- Drag one or more folders into the lower browser, or use its `+` button.
- Click folders to navigate, and use the back button to return.
- Click a video to select it and begin playback automatically.
- Use the subtitle menu to select an embedded track, turn subtitles off, or
  load an external subtitle.
- Use the shuffle and repeat buttons to control queue playback.

Added folders are remembered and monitored for filesystem changes. The queue is
made from the immediate video files in the folder where playback was started.

## Keyboard shortcuts

| Shortcut | Action |
| --- | --- |
| `Space` | Play or pause |
| `Left Arrow` | Seek backward 5 seconds |
| `Right Arrow` | Seek forward 5 seconds |
| `Up Arrow` | Increase volume by 5% |
| `Down Arrow` | Decrease volume by 5% |
| `F` | Toggle full screen |
| `Control-Command-F` | Toggle full screen using the macOS convention |

## Distribution note

This development build intentionally loads Homebrew libraries outside the app
bundle and disables library validation. It is not configured for Mac App Store
distribution.

## License

MVPlayer is available under the [MIT License](LICENSE).
