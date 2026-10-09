#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
project="$ios_dir/ZeroOne.xcodeproj"

if [ ! -d "$project" ]; then
  echo "Generated project missing. Run ios/scripts/generate-project.sh first." >&2
  exit 1
fi

destination=${IOS_TEST_DESTINATION:-}
if [ -z "$destination" ]; then
  simulator_id=$(xcrun simctl list devices available | awk '
    /^-- iOS / { in_ios_runtime = 1; next }
    /^-- / { in_ios_runtime = 0 }
    in_ios_runtime && /^[[:space:]]*iPhone / {
      if (match($0, /\([0-9A-Fa-f-]+\)/)) {
        print substr($0, RSTART + 1, RLENGTH - 2)
        exit
      }
    }
  ')
  if [ -z "$simulator_id" ]; then
    echo "No available iOS Simulator destination. Set IOS_TEST_DESTINATION explicitly." >&2
    echo "Available simulator devices:" >&2
    xcrun simctl list devices available >&2 || true
    echo "Xcode destinations for ZeroOne:" >&2
    xcodebuild -project "$project" -scheme ZeroOne -showdestinations >&2 || true
    exit 1
  fi
  destination="platform=iOS Simulator,id=$simulator_id"
fi

exec xcodebuild \
  -project "$project" \
  -scheme ZeroOne \
  -configuration Debug \
  -destination "$destination" \
  -derivedDataPath "$ios_dir/.build/DerivedData" \
  CODE_SIGN_IDENTITY="" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  test
