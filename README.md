# MVPlayer

MVPlayer is a native SwiftUI macOS video player backed by Homebrew's
`libmpv`. It targets macOS 14 or newer on Apple silicon.

## Features

- A folder-based library: drop folders in or add them from the browser header,
  and they are remembered and watched for filesystem changes.
- Single files opened in a window of their own, from the File menu, the Finder,
  or a drop on the browser, leaving the folder window's queue untouched.
- Playback progress kept per file and shared by every window, so a part-watched
  video resumes on the frame it left off at.
- Timeline scrubbing with hover frame previews for every playable format,
  shaped like the video they preview — AVFoundation where it can read the file,
  Homebrew `ffmpeg` or `mpv` for the containers it cannot, such as MKV, AVI,
  and WebM.
- A status bar under the list describing the selection: running time,
  dimensions, frame rate, and file size for a video, the location for a folder.
- Embedded subtitle and audio track selection, plus external subtitle loading.
- Queue controls with previous, next, shuffle, repeat all, and repeat one.
- Full-screen playback, macOS Now Playing information, and media-key and remote
  playback controls.
- Broad local video support through `libmpv`, hardware accelerated where
  supported: MP4, MKV, MOV, AVI, WebM, MPEG, M2TS, FLV, WMV, and the rest of
  what mpv handles.

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

Scrubber previews use the `ffmpeg` command line tool that Homebrew installs
with mpv, falling back to the `mpv` binary; metadata for containers
AVFoundation will not open uses the `ffprobe` beside that `ffmpeg`, falling
back to `mpv`. Set `MVPLAYER_FFMPEG_PATH` or `MVPLAYER_MPV_PATH` to point at an
installation elsewhere. Without either tool, previews and metadata are limited
to files AVFoundation can decode.

Opening a file starts one background pass that extracts a strip of preview
frames covering the whole timeline, so hovering reads from memory and keeps up
with the pointer. With `ffmpeg` the pass decodes key frames only, which covers
a ten minute file in well under a second; positions it has not reached yet fall
back to extracting a single frame on demand.

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

- Add one or more folders with the `+` (`Add Folder`) button in the browser
  header, or drag them into the lower browser.
- Use File ▸ Open File… to watch a single file. It opens in a window of its
  own, playing only that file, so the folder window keeps its queue and its
  place in it. Opening a video from the Finder, or dropping one on the browser,
  does the same. Only one window plays at a time: starting a video pauses
  whichever window was playing, where it had got to.
- Click folders to navigate, and use the back button to return.
- Click a video to select it and begin playback automatically.
- Move the selection with the arrow keys to read a folder: the status bar under
  the list follows the selection, not the file being played.
- Use the subtitle menu to select an embedded track, turn subtitles off, or
  load an external subtitle.
- Use the audio menu to switch between embedded audio tracks.
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
