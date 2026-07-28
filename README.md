# MV Player

MV Player is a native SwiftUI macOS video player backed by Homebrew's
`libmpv`. It targets macOS 14 or newer on Apple silicon.

## Requirements

- Xcode 26 or newer
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Homebrew mpv:

  ```sh
  brew install mpv
  ```

The app loads libmpv at runtime from `/opt/homebrew`. If it is unavailable,
MV Player opens a setup screen instead of failing at launch.

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

## Usage

- Drag one or more folders into the lower browser, or use its `+` button.
- Click folders to navigate forward and use the back button to return.
- Click a video to play it.
- Use the subtitle menu to select an embedded track, turn subtitles off, or
  load an external subtitle.
- Playback shortcuts: Space, arrow keys, and `F`.

Added folders are remembered and monitored for filesystem changes. The queue is
made from the immediate video files in the folder where playback was started.

## Distribution note

This development build intentionally loads Homebrew libraries outside the app
bundle and disables library validation. It is not configured for Mac App Store
distribution.
