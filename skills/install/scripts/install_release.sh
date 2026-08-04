#!/usr/bin/env bash

set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: install_release.sh [options]

Build and package MVPlayer for Apple-silicon macOS, then install the app locally.

Options:
  --project-dir DIR       MVPlayer repository root (default: current directory)
  --derived-data-dir DIR  Xcode derived data directory (default: project/build)
  --install-dir DIR       Application destination (default: ~/Applications)
  --no-install            Build and package without copying the app to disk
  --no-generate           Use the existing Xcode project without running XcodeGen
  --launch                Open the installed app after copying it
  -h, --help              Show this help
USAGE
}

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

info() {
  printf '\n==> %s\n' "$*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command '$1'."
}

resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$project_dir" "$1" ;;
  esac
}

project_dir="$(pwd -P)"
derived_data_arg=""
install_dir_arg=""
should_install=true
should_generate=true
should_launch=false

while (($# > 0)); do
  case "$1" in
    --project-dir)
      (($# >= 2)) || fail "--project-dir requires a directory."
      project_dir="$2"
      shift 2
      ;;
    --derived-data-dir)
      (($# >= 2)) || fail "--derived-data-dir requires a directory."
      derived_data_arg="$2"
      shift 2
      ;;
    --install-dir)
      (($# >= 2)) || fail "--install-dir requires a directory."
      install_dir_arg="$2"
      shift 2
      ;;
    --no-install)
      should_install=false
      shift
      ;;
    --no-generate)
      should_generate=false
      shift
      ;;
    --launch)
      should_launch=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      fail "Unknown option '$1'. Run with --help for usage."
      ;;
  esac
done

[[ "$(uname -s)" == "Darwin" ]] || fail "This skill requires macOS."
[[ -d "$project_dir" ]] || fail "Project directory does not exist: $project_dir"
project_dir="$(cd "$project_dir" && pwd -P)"

[[ -f "$project_dir/project.yml" ]] || fail "project.yml not found in $project_dir"
[[ -f "$project_dir/MVPlayer.xcodeproj/project.pbxproj" ]] || fail "MVPlayer.xcodeproj not found in $project_dir"

if [[ -n "$derived_data_arg" ]]; then
  derived_data_dir="$(resolve_path "$derived_data_arg")"
else
  derived_data_dir="$project_dir/build"
fi

if [[ -n "$install_dir_arg" ]]; then
  install_dir="$(resolve_path "$install_dir_arg")"
else
  [[ -n "${HOME:-}" ]] || fail "HOME is not set; pass --install-dir explicitly."
  install_dir="$HOME/Applications"
fi

[[ "$should_launch" == false || "$should_install" == true ]] || fail "--launch requires installation; remove --no-install."

require_command xcodebuild
require_command ditto

if [[ "$should_generate" == true ]]; then
  require_command xcodegen
  info "Regenerating MVPlayer.xcodeproj from project.yml"
  (cd "$project_dir" && xcodegen generate)
fi

if command -v brew >/dev/null 2>&1; then
  if brew --prefix mpv >/dev/null 2>&1; then
    info "Found Homebrew mpv"
  else
    printf 'warning: Homebrew mpv is not installed; MVPlayer playback will not work until it is.\n' >&2
  fi
else
  printf 'warning: Homebrew is not installed; MVPlayer playback requires a libmpv installation.\n' >&2
fi

xcode_version_line="$(xcodebuild -version 2>/dev/null | sed -n '1p')"
xcode_version_number="${xcode_version_line#Xcode }"
xcode_major="${xcode_version_number%%.*}"
xcode_minor="${xcode_version_number#*.}"
use_legacy_icon=false
if [[ "$xcode_major" == "26" && "$xcode_minor" =~ ^[0-9]+$ ]] && (( xcode_minor >= 5 )) && [[ -d "$project_dir/Assets/mvplayer.icon" ]]; then
  use_legacy_icon=true
  printf 'warning: %s has an Icon Composer build regression; using a generated legacy .icns fallback.\n' "$xcode_version_line" >&2
fi

info "Building MVPlayer Release for macOS arm64"
xcodebuild_args=(
  -project "$project_dir/MVPlayer.xcodeproj" \
  -scheme MVPlayer \
  -configuration Release \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$derived_data_dir"
)
if [[ "$use_legacy_icon" == true ]]; then
  xcodebuild_args+=(EXCLUDED_SOURCE_FILE_NAMES=mvplayer.icon)
fi
xcodebuild "${xcodebuild_args[@]}" clean build

built_app="$derived_data_dir/Build/Products/Release/MVPlayer.app"
app_executable="$built_app/Contents/MacOS/MVPlayer"
app_info_plist="$built_app/Contents/Info.plist"
[[ -d "$built_app" ]] || fail "Release app was not produced: $built_app"
[[ -x "$app_executable" ]] || fail "Release app executable is missing: $app_executable"
[[ -f "$app_info_plist" ]] || fail "Release app Info.plist is missing: $app_info_plist"

if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$app_info_plist" >/dev/null || fail "Release app Info.plist is invalid."
fi

package_tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/mvplayer-release.XXXXXX")"
trap 'rm -rf "$package_tmp_dir"' EXIT

if [[ "$use_legacy_icon" == true ]]; then
  icon_source_image="$project_dir/Assets/mvplayer.icon/mvplayer.png"
  if [[ -f "$icon_source_image" ]] && command -v sips >/dev/null 2>&1 && command -v iconutil >/dev/null 2>&1; then
    info "Embedding a legacy MVPlayer.icns fallback"
    iconset_dir="$package_tmp_dir/MVPlayer.iconset"
    mkdir -p "$iconset_dir"
    for icon_size in 16 32 128 256 512; do
      double_size=$((icon_size * 2))
      sips -z "$icon_size" "$icon_size" "$icon_source_image" --out "$iconset_dir/icon_${icon_size}x${icon_size}.png" >/dev/null
      sips -z "$double_size" "$double_size" "$icon_source_image" --out "$iconset_dir/icon_${icon_size}x${icon_size}@2x.png" >/dev/null
    done
    mkdir -p "$built_app/Contents/Resources"
    iconutil -c icns "$iconset_dir" -o "$built_app/Contents/Resources/MVPlayer.icns"
    if ! /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string MVPlayer.icns" "$app_info_plist" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile MVPlayer.icns" "$app_info_plist" >/dev/null
    fi
    entitlements_path="$derived_data_dir/Build/Intermediates.noindex/MVPlayer.build/Release/MVPlayer.build/MVPlayer.app.xcent"
    if [[ -f "$entitlements_path" ]]; then
      codesign --force --sign - --options runtime --entitlements "$entitlements_path" "$built_app" >/dev/null
    else
      codesign --force --sign - --options runtime "$built_app" >/dev/null
    fi
  else
    printf 'warning: Could not create MVPlayer.icns; the installed app will use the default macOS icon.\n' >&2
  fi
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --verify --deep --strict "$built_app" >/dev/null 2>&1 || fail "Release app failed code-signature validation."
fi

package_dir="$derived_data_dir/Release"
package_path="$package_dir/MVPlayer.zip"
mkdir -p "$package_dir"

info "Creating Release package"
ditto -c -k --sequesterRsrc --keepParent "$built_app" "$package_tmp_dir/MVPlayer.zip"
mv -f "$package_tmp_dir/MVPlayer.zip" "$package_path"

if [[ "$should_install" == true ]]; then
  mkdir -p "$install_dir" || fail "Cannot create install directory: $install_dir"
  installed_app="$install_dir/MVPlayer.app"
  info "Installing MVPlayer to $installed_app"
  ditto --rsrc --extattr --acl "$built_app" "$installed_app" || \
    fail "Cannot install to $installed_app. Try --install-dir \"$HOME/Applications\"."
  [[ -x "$installed_app/Contents/MacOS/MVPlayer" ]] || fail "Installed app is incomplete: $installed_app"

  if [[ "$should_launch" == true ]]; then
    require_command open
    info "Opening installed MVPlayer"
    open "$installed_app"
  fi
else
  installed_app="(installation skipped)"
fi

printf '\nRelease build complete.\n'
printf 'Built app: %s\n' "$built_app"
printf 'Package: %s\n' "$package_path"
printf 'Installed app: %s\n' "$installed_app"
