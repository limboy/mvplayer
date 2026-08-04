#!/usr/bin/env bash
#
# Vendors libmpv and the Homebrew ffmpeg command line tools MVPlayer shells
# out to for thumbnails, together with every Homebrew dylib either one
# depends on, into deps/lib and deps/bin. install_name_tool rewrites every
# Homebrew-prefixed load command to @rpath, the same approach IINA's
# other/change_lib_dependencies.rb uses for its own libmpv bundle.
#
# The project.yml build phase "Embed mpv runtime" copies deps/lib and
# deps/bin into the built app (Contents/Frameworks and
# Contents/Resources/bin) and code-signs them, so run this script whenever
# the Homebrew mpv or ffmpeg version changes and before packaging a release.
# deps/ itself is gitignored: it is regenerated locally, not committed.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
project_dir="$(cd "$script_dir/.." && pwd -P)"

lib_out="$project_dir/deps/lib"
bin_out="$project_dir/deps/bin"

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command '$1'."
}

require_command brew
require_command otool
require_command install_name_tool
require_command realpath

brew_prefix="$(brew --prefix)"

mpv_prefix="$(brew --prefix mpv 2>/dev/null)" || fail "Homebrew mpv is not installed. Run 'brew install mpv'."
ffmpeg_prefix="$(brew --prefix ffmpeg 2>/dev/null)" || fail "Homebrew ffmpeg is not installed. Run 'brew install ffmpeg'."

libmpv_src="$mpv_prefix/lib/libmpv.2.dylib"
[[ -f "$libmpv_src" ]] || libmpv_src="$mpv_prefix/lib/libmpv.dylib"
[[ -f "$libmpv_src" ]] || fail "Could not find libmpv.dylib under $mpv_prefix/lib."

ffmpeg_src="$ffmpeg_prefix/bin/ffmpeg"
ffprobe_src="$ffmpeg_prefix/bin/ffprobe"
[[ -x "$ffmpeg_src" ]] || fail "ffmpeg not found at $ffmpeg_src."
[[ -x "$ffprobe_src" ]] || fail "ffprobe not found at $ffprobe_src."

printf '==> Resetting %s and %s\n' "$lib_out" "$bin_out"
rm -rf "$lib_out" "$bin_out"
mkdir -p "$lib_out" "$bin_out"

# Finds a Homebrew-installed dylib by basename under any formula's opt/lib
# directory, for dependencies already expressed as @rpath/<name> in the
# source file rather than as an absolute Homebrew path.
resolve_homebrew_dylib() {
  local name="$1" candidate
  for candidate in "$brew_prefix"/opt/*/lib/"$name"; do
    if [[ -e "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

# Copies $1 into $2 (following symlinks to the real file), rewrites its own
# install name to @rpath/<basename> if it has one (plain executables don't),
# then walks its Homebrew-prefixed dependencies: each gets rewritten to
# @rpath/<basename> in $1 and is recursively vendored into deps/lib, so a
# dependency shared by libmpv and ffmpeg is only ever copied once.
process() {
  local src="$1" dest_dir="$2"
  local resolved base dest
  resolved="$(realpath "$src")"
  # Named after $src, not the realpath'd file: Homebrew dylibs often carry
  # their full version in the Cellar filename (libavcodec.62.28.101.dylib)
  # while every LC_LOAD_DYLIB reference to them uses the "opt" symlink's
  # shorter compatibility-versioned name (libavcodec.62.dylib). @rpath
  # rewrites below use that referenced name, so the copy must match it.
  base="$(basename "$src")"
  dest="$dest_dir/$base"

  if [[ -f "$dest" ]]; then
    return
  fi
  printf '  vendoring %s\n' "$base"
  cp -p "$resolved" "$dest"
  chmod u+w "$dest"

  local id
  id="$(otool -D "$dest" | sed -n '2p')"
  if [[ -n "$id" ]]; then
    install_name_tool -id "@rpath/$base" "$dest"
  fi

  local dep dep_base resolved_dep
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    if [[ "$dep" == "$brew_prefix"* ]]; then
      dep_base="$(basename "$dep")"
      install_name_tool -change "$dep" "@rpath/$dep_base" "$dest"
      resolved_dep="$dep"
    elif [[ "$dep" == @rpath/* ]]; then
      # Some Homebrew formulae (webp/libsharpyuv, for one) already link their
      # own dylibs together via @rpath. That reference needs no rewrite, but
      # the target it names still has to be found under the Homebrew prefix
      # and vendored, or dyld has nothing to resolve @rpath/<name> to once
      # the file is copied out from under the rpath Homebrew built it with.
      dep_base="${dep#@rpath/}"
      resolved_dep="$(resolve_homebrew_dylib "$dep_base")" || continue
    else
      continue
    fi
    process "$resolved_dep" "$lib_out"
  done < <(otool -L "$dest" | tail -n +2 | awk '{print $1}')
}

process "$libmpv_src" "$lib_out"
process "$ffmpeg_src" "$bin_out"
process "$ffprobe_src" "$bin_out"

# ffmpeg and ffprobe run as their own processes rather than being dlopen'd
# into MVPlayer, so unlike libmpv's dependents they need their own rpath to
# resolve @rpath/libavcodec.dylib and friends: Contents/Resources/bin/ffmpeg
# looks two directories up for Contents/Frameworks.
for exe in "$bin_out/ffmpeg" "$bin_out/ffprobe"; do
  install_name_tool -add_rpath "@executable_path/../../Frameworks" "$exe"
done

lib_count="$(find "$lib_out" -type f | wc -l | tr -d ' ')"
total_size="$(du -ch "$lib_out" "$bin_out" | tail -1 | awk '{print $1}')"
printf '\nVendored %s dylibs into %s\n' "$lib_count" "$lib_out"
printf 'Vendored ffmpeg and ffprobe into %s\n' "$bin_out"
printf 'Total size: %s\n' "$total_size"
