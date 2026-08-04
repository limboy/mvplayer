#!/usr/bin/env bash
#
# Xcode "Embed mpv runtime" build phase. Copies the libmpv/ffmpeg bundle
# scripts/bundle-mpv-deps.sh vendored into deps/lib and deps/bin into the
# built app, then code-signs each copy with the same identity as the app
# itself so hardened runtime accepts them at dlopen/exec time.
#
# Runs with SRCROOT missing, so it degrades gracefully: a contributor who
# has not run bundle-mpv-deps.sh still gets a working dev build, just one
# that falls back to Homebrew's libmpv/ffmpeg at runtime like before.

set -euo pipefail

deps_lib_dir="$SRCROOT/deps/lib"
deps_bin_dir="$SRCROOT/deps/bin"

if [[ ! -d "$deps_lib_dir" ]] || [[ -z "$(ls -A "$deps_lib_dir" 2>/dev/null)" ]]; then
  echo "warning: deps/lib is empty; run scripts/bundle-mpv-deps.sh to bundle libmpv so this build doesn't need Homebrew at runtime." >&2
  exit 0
fi

frameworks_dir="$CODESIGNING_FOLDER_PATH/Contents/Frameworks"
bin_dir="$CODESIGNING_FOLDER_PATH/Contents/Resources/bin"
mkdir -p "$frameworks_dir" "$bin_dir"

echo "Embedding $(ls "$deps_lib_dir" | wc -l | tr -d ' ') dylibs into Contents/Frameworks"
cp -p "$deps_lib_dir"/*.dylib "$frameworks_dir/"

if [[ -f "$deps_bin_dir/ffmpeg" && -f "$deps_bin_dir/ffprobe" ]]; then
  echo "Embedding ffmpeg and ffprobe into Contents/Resources/bin"
  cp -p "$deps_bin_dir/ffmpeg" "$deps_bin_dir/ffprobe" "$bin_dir/"
fi

if [[ "${CODE_SIGNING_ALLOWED:-YES}" == "YES" ]]; then
  sign_identity="${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:--}}"
  [[ -n "$sign_identity" ]] || sign_identity="-"

  # Ad-hoc signing (dev builds with no cert) can't carry a secure timestamp.
  # Notarization requires one on every signature made with a real identity,
  # so Release archives need --timestamp, not --timestamp=none.
  timestamp_flag="--timestamp=none"
  if [[ "$sign_identity" != "-" ]]; then
    timestamp_flag="--timestamp"
  fi

  for target in "$frameworks_dir"/*.dylib; do
    [[ -f "$target" ]] || continue
    codesign --force --sign "$sign_identity" --options runtime "$timestamp_flag" "$target"
  done

  # ffmpeg/ffprobe run as their own child processes rather than being
  # dlopen'd into MVPlayer, so it's their own signature — not MVPlayer's
  # disable-library-validation entitlement — that governs whether hardened
  # runtime lets them load the ad-hoc-signed sibling dylibs above. Sign them
  # with the same entitlement MVPlayer itself carries so they can.
  for target in "$bin_dir/ffmpeg" "$bin_dir/ffprobe"; do
    [[ -f "$target" ]] || continue
    codesign --force --sign "$sign_identity" --options runtime "$timestamp_flag" \
      --entitlements "$SRCROOT/MVPlayer/Support/MVPlayer.entitlements" "$target"
  done
fi
