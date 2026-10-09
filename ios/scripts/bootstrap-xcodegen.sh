#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
lock_file="$ios_dir/xcodegen.lock"
tool_root="$ios_dir/.build/xcodegen"

lock_value() {
  key="$1"
  value=$(sed -n "s/^${key}=//p" "$lock_file" | head -n 1)
  if [ -z "$value" ]; then
    echo "Missing ${key} in ${lock_file}" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}

version=$(lock_value version)
revision=$(lock_value revision)
install_directory="$tool_root/$revision"
install_bin_directory="$install_directory/bin"
install_settings_directory="$install_directory/share/xcodegen/SettingPresets"
binary="$install_bin_directory/xcodegen"
settings_preset="$install_settings_directory/base.yml"
revision_marker="$install_directory/revision"

if [ -x "$binary" ] && [ -f "$settings_preset" ] && [ -f "$revision_marker" ] &&
  [ "$(sed -n '1p' "$revision_marker")" = "$revision" ]; then
  installed_version=$($binary --version 2>&1 || true)
  case "$installed_version" in
    *"$version"*)
      printf 'Using pinned XcodeGen %s (%s)\n' "$version" "$revision"
      exit 0
      ;;
  esac
fi

if ! command -v git >/dev/null 2>&1; then
  echo "Git is required to bootstrap XcodeGen." >&2
  exit 1
fi

if ! command -v swift >/dev/null 2>&1; then
  echo "Swift from Xcode is required to build the pinned XcodeGen executable." >&2
  exit 1
fi

temporary_directory=$(mktemp -d "${TMPDIR:-/tmp}/zeroone-xcodegen.XXXXXX")
trap 'rm -rf "$temporary_directory"' EXIT HUP INT TERM

source_directory="$temporary_directory/XcodeGen"
git init -q "$source_directory"
git -C "$source_directory" remote add origin https://github.com/yonaskolb/XcodeGen.git
git -C "$source_directory" fetch -q --depth 1 origin "refs/tags/$version"
git -C "$source_directory" checkout -q --detach FETCH_HEAD

resolved_revision=$(git -C "$source_directory" rev-parse HEAD)
if [ "$resolved_revision" != "$revision" ]; then
  echo "XcodeGen revision mismatch: expected $revision, got $resolved_revision." >&2
  exit 1
fi

swift build --package-path "$source_directory" --configuration release --product xcodegen
build_binary_directory=$(swift build --package-path "$source_directory" --configuration release --show-bin-path)
generated_binary="$build_binary_directory/xcodegen"
source_settings_directory="$source_directory/SettingPresets"
source_settings_preset="$source_settings_directory/base.yml"

if [ ! -x "$generated_binary" ]; then
  echo "The pinned XcodeGen build did not produce an executable." >&2
  exit 1
fi

if [ ! -f "$source_settings_preset" ]; then
  echo "The pinned XcodeGen source does not contain SettingPresets/base.yml." >&2
  exit 1
fi

generated_version=$($generated_binary --version 2>&1 || true)
case "$generated_version" in
  *"$version"*) ;;
  *)
    echo "XcodeGen version mismatch: expected $version, got $generated_version." >&2
    exit 1
    ;;
esac

mkdir -p "$install_bin_directory" "$install_settings_directory"
cp -f "$generated_binary" "$binary"
cp -R "$source_settings_directory/." "$install_settings_directory"
chmod +x "$binary"
printf '%s\n' "$resolved_revision" > "$revision_marker"
printf 'Bootstrapped pinned XcodeGen %s (%s)\n' "$version" "$revision"
