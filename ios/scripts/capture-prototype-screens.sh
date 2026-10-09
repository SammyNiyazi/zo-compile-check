#!/bin/bash
set -euo pipefail

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
ios_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
app="$ios_dir/.build/DerivedData/Build/Products/Debug-iphonesimulator/ZeroOne.app"
screens="$ios_dir/.build/prototype-screens"
bundle_id=app.the01.ios

[[ -d "$app" ]] || { echo 'Built Simulator app is missing.' >&2; exit 1; }
mkdir -p "$screens"

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
[[ -n "$simulator_id" ]] || { echo 'No available iPhone Simulator.' >&2; exit 1; }

# The compilation step deliberately skips signing. Let Xcode ad-hoc sign the
# Simulator app and extension, including their correct Keychain identities, before
# real account restoration during capture. No distribution credential is used.
xcodebuild -project "$ios_dir/ZeroOne.xcodeproj" -scheme ZeroOne \
  -configuration Debug -destination "platform=iOS Simulator,id=$simulator_id" \
  -derivedDataPath "$ios_dir/.build/DerivedData" \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=YES CODE_SIGNING_ALLOWED=YES \
  ONLY_ACTIVE_ARCH=YES build
/usr/bin/codesign --verify --strict "$app"

xcrun simctl boot "$simulator_id" 2>/dev/null || true
xcrun simctl bootstatus "$simulator_id" -b

capture_failures=0

capture() {
  local name=$1 tab=$2 route=$3 state=$4 profile=$5 history=$6 appearance=${7:-dark} programme=${8:-} main_action=${9:-} restore=${10:-} setup=${11:-}
  local host_appearance=${12:-$appearance}
  local profile_complete=1
  [[ -z "$setup" ]] || profile_complete=0
  if [[ -n "$restore" ]]; then
    export SIMCTL_CHILD_ZERO_ONE_REVIEW_RESTORE_STATE="$restore"
  else
    unset SIMCTL_CHILD_ZERO_ONE_REVIEW_RESTORE_STATE
  fi
  xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl install "$simulator_id" "$app"
  # Align the host traits before creating the scene, including the first launch.
  xcrun simctl ui "$simulator_id" appearance "$host_appearance"
  local launch_output capture_pid today_ready_count=0 is_today_capture=0 scene_ready=0
  launch_output=$(SIMCTL_CHILD_ZERO_ONE_REVIEW_PROFILE_COMPLETE="$profile_complete" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_ONBOARDING_STEP="$setup" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_SKIP_LAUNCH=1 \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_TAB="$tab" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_WORKOUT_ROUTE="$route" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_WORKOUT_STATE="$state" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_WORKOUT_PROGRAMME="$programme" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_PROFILE_ROUTE="$profile" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_MAIN_ACTION_STATE="$main_action" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_HISTORY_STATE="$history" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_DIETS_STATE="$state" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_HYDRATION_STATE="${SIMCTL_CHILD_ZERO_ONE_REVIEW_HYDRATION_STATE:-sample}" \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_APPEARANCE="$appearance" \
    xcrun simctl launch "$simulator_id" "$bundle_id")
  printf '%s\n' "$launch_output"
  capture_pid=${launch_output##*: }
  [[ "$capture_pid" =~ ^[0-9]+$ ]] || { echo "Cannot identify $name launch process." >&2; exit 1; }
  sleep 3
  xcrun simctl io "$simulator_id" screenshot "$screens/$name.png"
  local first_capture_bytes
  first_capture_bytes=$(stat -f %z "$screens/$name.png")
  echo "$name first capture: $first_capture_bytes bytes"
  if [[ "$name" == today* ]]; then
    is_today_capture=1
    xcrun simctl spawn "$simulator_id" log show --last 20s --style compact \
      --predicate 'subsystem == "app.the01.ios" AND category == "Launch"' \
      > "$screens/$name-launch.log" 2>&1 || true
    today_ready_count=$(grep -F "ZeroOne[$capture_pid:" "$screens/$name-launch.log" | grep -Fc 'TodayView ready' || true)
  fi
  if [[ "$name" == social-share-preview* ]]; then
    xcrun simctl spawn "$simulator_id" log show --last 30s --style compact \
      --predicate 'subsystem == "app.the01.ios" AND category == "Launch"' \
      > "$screens/$name-launch.log" 2>&1 || true
    if ! grep -Fq 'Review social share image rendered' "$screens/$name-launch.log"; then
      echo "$name did not render the actual share image." >&2
      capture_failures=$((capture_failures + 1))
    fi
    local data_container exported_card exported_count=0
    data_container=$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)
    for exported_card in "$data_container"/Documents/ReviewShareCards/card-*.png; do
      [[ -f "$exported_card" ]] || continue
      cp "$exported_card" "$screens/$name-$(basename "$exported_card")"
      exported_count=$((exported_count + 1))
    done
    if (( exported_count == 0 )); then
      echo "$name did not retain its actual share image." >&2
      capture_failures=$((capture_failures + 1))
    fi
  fi
  if (( first_capture_bytes < 120000 || (is_today_capture == 1 && today_ready_count == 0) )); then
    if (( is_today_capture == 1 )); then
      # Run27 retained black pixels while scene activation was delayed.
      # Retain the first image, then wait for this process's actual readiness rather
      # than assuming that a fixed sleep means the destination has appeared.
      local ready_deadline=$((SECONDS + 30)) current_launch
      while (( SECONDS < ready_deadline )); do
        xcrun simctl spawn "$simulator_id" log show --last 45s --style compact \
          --predicate 'subsystem == "app.the01.ios" AND category == "Launch"' \
          > "$screens/$name-launch.log" 2>&1 || true
        current_launch=$(grep -F "ZeroOne[$capture_pid:" "$screens/$name-launch.log" || true)
        if [[ "$current_launch" == *"TodayView ready"* ]] && \
           [[ "$current_launch" == *"scene changed to active"* || "$current_launch" == *"scene=active"* ]]; then
          scene_ready=1
          break
        fi
        sleep 2
      done
      echo "$name current-process scene readiness: $scene_ready"
      # The onAppear marker precedes the next composited frame.
      sleep 1
    else
      sleep 9
    fi
    xcrun simctl io "$simulator_id" screenshot "$screens/$name-delayed.png"
    xcrun simctl spawn "$simulator_id" log show --last 45s --style compact \
      --predicate 'subsystem == "app.the01.ios" AND category == "Launch"' \
      > "$screens/$name-launch.log" 2>&1 || true
    echo "$name launch markers:"
    tail -n 30 "$screens/$name-launch.log" || true
    xcrun simctl spawn "$simulator_id" log show --last 20s --style compact \
      --predicate 'process == "ZeroOne" OR process == "ReportCrash"' 2>&1 | tail -n 40 || true
    local delayed_capture_bytes
    delayed_capture_bytes=$(stat -f %z "$screens/$name-delayed.png")
    echo "$name delayed capture: $delayed_capture_bytes bytes"
    if (( is_today_capture == 1 )); then
      today_ready_count=$(grep -F "ZeroOne[$capture_pid:" "$screens/$name-launch.log" | grep -Fc 'TodayView ready' || true)
    fi
    if (( delayed_capture_bytes < 90000 )) || \
       ! grep -Fq 'AppRootView initialization finished' "$screens/$name-launch.log" || \
       (( is_today_capture == 1 && (today_ready_count == 0 || scene_ready == 0) )); then
      echo "$name still appears blank or did not finish initialization after the delayed retry." >&2
      capture_failures=$((capture_failures + 1))
    else
      echo "$name is a sparse but initialized screen; retaining its screenshot for visual review."
    fi
  fi
  if [[ "$name" == today-steps-bottom* ]]; then
    # Check the actual settled position, not only the requested initial anchor.
    sleep 1
    xcrun simctl io "$simulator_id" screenshot "$screens/$name-settled.png"
    xcrun simctl spawn "$simulator_id" log show --last 45s --style compact \
      --predicate 'subsystem == "app.the01.ios" AND category == "Launch"' \
      > "$screens/$name-launch.log" 2>&1 || true
    local bottom_distance frame_name frame_bounds frame_min frame_max frame_height
    local frame_evidence_valid=1
    local viewport_bottom='' tail_bottom='' movement_bottom='' dock_top=''
    bottom_distance=$(grep -F "ZeroOne[$capture_pid:" "$screens/$name-launch.log" | \
      sed -n 's/.*Today review bottom distance: //p' | tail -n 1 || true)
    echo "$name settled bottom distance: ${bottom_distance:-missing}"
    for frame_name in viewport tail movement dock; do
      frame_bounds=$(grep -F "ZeroOne[$capture_pid:" "$screens/$name-launch.log" | \
        sed -n "s/.*Today review frame: name=$frame_name minY=\([^ ]*\) maxY=\([^ ]*\) height=\([^ ]*\).*/\1 \2 \3/p" | tail -n 1 || true)
      echo "$name $frame_name global bounds: ${frame_bounds:-missing}"
      read -r frame_min frame_max frame_height <<< "$frame_bounds"
      if [[ ! "$frame_min" =~ ^-?[0-9]+([.][0-9]+)?$ ||
            ! "$frame_max" =~ ^-?[0-9]+([.][0-9]+)?$ ||
            ! "$frame_height" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
         ! awk -v height="$frame_height" 'BEGIN { exit !(height > 0) }'; then
        frame_evidence_valid=0
      fi
      case "$frame_name" in
        viewport) viewport_bottom=$frame_max ;;
        tail) tail_bottom=$frame_max ;;
        movement) movement_bottom=$frame_max ;;
        dock) dock_top=$frame_min ;;
      esac
    done
    # Run29's raw96pt equals system insets, while the footer is visibly covered.
    # Keep that diagnostic, but prove actual viewport/card clearance in one space.
    if ! grep -F "ZeroOne[$capture_pid:" "$screens/$name-launch.log" | \
         grep -Fq 'Today review explicit bottom scroll requested' || \
       [[ ! "$bottom_distance" =~ ^-?[0-9]+$ || "$frame_evidence_valid" != 1 ]] || \
       ! awk -v viewport="$viewport_bottom" -v tail="$tail_bottom" \
             -v card="$movement_bottom" -v dock="$dock_top" \
         'BEGIN { exit !(viewport > 0 && dock > 0 && card > 0 && viewport <= dock + 2 && \
                         tail <= viewport + 2 && tail >= viewport - 2 && \
                         card <= tail - 30 && card <= dock - 30) }'; then
      echo "$name did not establish full card clearance at the settled bottom." >&2
      capture_failures=$((capture_failures + 1))
    fi
  fi
  xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
}

# Keep the cold appearance-override case: a saved dark app choice on a light OS
# is a supported configuration, not a failure to hide by matching host traits.
capture today-appearance-override today '' '' '' '' dark '' '' '' '' light
capture today today '' '' '' ''
capture today-light today '' '' '' '' light
capture today-dark-repeat today '' '' '' '' dark
# Build5 phone feedback: inspect the complete populated final card above the dock.
export SIMCTL_CHILD_ZERO_ONE_REVIEW_HEALTH_STATE=connected
export SIMCTL_CHILD_ZERO_ONE_REVIEW_TODAY_SCROLL=bottom
capture today-steps-bottom-dark today '' '' '' '' dark
capture today-steps-bottom-light today '' '' '' '' light
export SIMCTL_CHILD_ZERO_ONE_REVIEW_LARGE_TEXT=1
capture today-steps-bottom-large-dark today '' '' '' '' dark
capture today-steps-bottom-large-light today '' '' '' '' light
unset SIMCTL_CHILD_ZERO_ONE_REVIEW_HEALTH_STATE SIMCTL_CHILD_ZERO_ONE_REVIEW_TODAY_SCROLL SIMCTL_CHILD_ZERO_ONE_REVIEW_LARGE_TEXT
capture workout-library workout '' '' '' ''
capture programme-detail workout detail '' '' ''
capture warm-up workout active '' '' ''
capture active-workout workout active working '' ''
capture rest workout active rest '' ''
capture rest-ready workout active '' '' '' dark '' '' elapsed-rest
capture final-set-review workout active final-review '' ''
capture completion workout active complete '' ''
capture completion-upgrade workout active upgrade '' ''
capture in-session-upgrade workout active upgrade-between '' ''
capture movekit workout '' movekit '' ''
capture history today '' '' history completed
capture history-detail today '' '' session completed
capture social social '' '' '' ''
export SIMCTL_CHILD_ZERO_ONE_REVIEW_SOCIAL_STATE=preview
capture social-share-preview social '' '' '' completed dark
capture social-share-preview-light social '' '' '' completed light
export SIMCTL_CHILD_ZERO_ONE_REVIEW_SHARE_STYLE=Carbon
capture social-share-preview-carbon social '' '' '' completed dark
export SIMCTL_CHILD_ZERO_ONE_REVIEW_SHARE_STYLE=Signal
capture social-share-preview-signal social '' '' '' completed dark
unset SIMCTL_CHILD_ZERO_ONE_REVIEW_SHARE_STYLE
unset SIMCTL_CHILD_ZERO_ONE_REVIEW_SOCIAL_STATE
capture diets diets '' populated '' ''
capture diets-light diets '' populated '' '' light
export SIMCTL_CHILD_ZERO_ONE_REVIEW_HYDRATION_STATE=empty
capture diets-empty diets '' empty '' '' light
export SIMCTL_CHILD_ZERO_ONE_REVIEW_HYDRATION_STATE=unavailable
capture diets-unavailable diets '' populated '' ''
unset SIMCTL_CHILD_ZERO_ONE_REVIEW_HYDRATION_STATE
export SIMCTL_CHILD_ZERO_ONE_REVIEW_ASSISTANT_STATE=open
capture assistant today '' '' '' ''
capture assistant-light today '' '' '' '' light
unset SIMCTL_CHILD_ZERO_ONE_REVIEW_ASSISTANT_STATE
capture setup-goals today '' '' '' '' light '' '' '' 0
capture setup-experience today '' '' '' '' dark '' '' '' 1
capture setup-equipment today '' '' '' '' light '' '' '' 2
capture setup-days today '' '' '' '' dark '' '' '' 3
capture setup-units today '' '' '' '' light '' '' '' 4
capture setup-walkthrough today '' '' '' '' dark '' '' '' 5
capture profile today '' '' overview completed
capture profile-login-dark today '' '' account completed dark
capture profile-login-light today '' '' account completed light
export SIMCTL_CHILD_ZERO_ONE_REVIEW_LARGE_TEXT=1
capture profile-login-large-light today '' '' account completed light
unset SIMCTL_CHILD_ZERO_ONE_REVIEW_LARGE_TEXT
capture notifications-dark today '' '' notifications completed dark
capture notifications-light today '' '' notifications completed light
export SIMCTL_CHILD_ZERO_ONE_REVIEW_LARGE_TEXT=1
capture notifications-large-light today '' '' notifications completed light
unset SIMCTL_CHILD_ZERO_ONE_REVIEW_LARGE_TEXT
capture profile-progress today '' '' progress completed
capture profile-progress-empty today '' '' progress empty
capture profile-progress-unavailable today '' '' progress unavailable
capture profile-body-weight today '' '' body-weight completed
capture main-action-open today '' '' '' '' dark '' open
capture main-action-open-light today '' '' '' '' light '' open
capture active-workout-light workout active working '' '' light
capture rest-ready-light workout active '' '' '' light '' '' elapsed-rest
capture arms-detail workout detail '' '' '' dark arms
capture biceps-detail workout detail '' '' '' dark biceps
capture arms-warm-up workout active '' '' '' dark arms
capture biceps-warm-up workout active '' '' '' dark biceps
capture arms-active workout active working '' '' dark arms
capture biceps-active workout active working '' '' dark biceps

capture_main_action_motion() {
  xcrun simctl uninstall "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  xcrun simctl install "$simulator_id" "$app"
  xcrun simctl ui "$simulator_id" appearance dark
  SIMCTL_CHILD_ZERO_ONE_REVIEW_PROFILE_COMPLETE=1 \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_SKIP_LAUNCH=1 \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_TAB=today \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_APPEARANCE=dark \
  SIMCTL_CHILD_ZERO_ONE_REVIEW_MAIN_ACTION_STATE=animate-cycle \
    xcrun simctl launch "$simulator_id" "$bundle_id"
  local frame frame_name captured_frames=0
  for (( frame = 0; frame < 12; frame++ )); do
    sleep 0.08
    printf -v frame_name 'main-action-motion-%02d' "$frame"
    if xcrun simctl io "$simulator_id" screenshot "$screens/$frame_name.png" >/dev/null 2>&1; then
      captured_frames=$((captured_frames + 1))
    fi
  done
  xcrun simctl spawn "$simulator_id" log show --last 10s --style compact \
    --predicate 'subsystem == "app.the01.ios" AND category == "Launch"' \
    > "$screens/main-action-motion-launch.log" 2>&1 || true
  xcrun simctl terminate "$simulator_id" "$bundle_id" >/dev/null 2>&1 || true
  echo "Main-action motion frames saved: $captured_frames of 12."
  if ! grep -Fq 'Review main-action opening' "$screens/main-action-motion-launch.log" || \
     ! grep -Fq 'Review main-action closing' "$screens/main-action-motion-launch.log"; then
    echo 'Motion cycle markers missing; do not treat this sequence as transition evidence.' >&2
  else
    echo 'Motion cycle markers found; compare frame content with marker timing before drawing conclusions.'
  fi
}

capture_main_action_motion

if (( capture_failures > 0 )); then
  echo "$capture_failures screen capture(s) failed launch diagnostics after the delayed retry." >&2
  exit 1
fi

echo "Captured actual Simulator screens in $screens"
