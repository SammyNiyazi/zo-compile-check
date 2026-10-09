#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
lock_file="$ios_dir/xcodegen.lock"
revision=$(sed -n 's/^revision=//p' "$lock_file" | head -n 1)

if [ -z "$revision" ]; then
  echo "Missing revision in ${lock_file}" >&2
  exit 1
fi

sh "$script_dir/bootstrap-xcodegen.sh"

binary="$ios_dir/.build/xcodegen/$revision/bin/xcodegen"
"$binary" generate --spec "$ios_dir/project.yml" --project "$ios_dir"

if [ ! -d "$ios_dir/ZeroOne.xcodeproj" ]; then
  echo "XcodeGen did not create ZeroOne.xcodeproj." >&2
  exit 1
fi

echo "Generated ios/ZeroOne.xcodeproj from ios/project.yml."
