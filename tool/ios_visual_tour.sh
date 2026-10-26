#!/usr/bin/env bash
# Runs integration_test/visual_tour_test.dart on a range of iOS simulators,
# one after another, recording the screen of each run. Needs macOS and Xcode.
#
#   tool/ios_visual_tour.sh [device-key,...]
#
# Keys: ipad-mini ipad ipad-air-11 ipad-air-13 ipad-pro-11 ipad-pro-13
# iphone-pro-max iphone-small. Without any, every one that the newest
# installed iOS runtime offers is used. Results go to $OUT (default
# build/visual_tour/ios), one directory per device, with summary.md beside.
set -uo pipefail

OUT="$(mkdir -p "${OUT:-build/visual_tour/ios}" && cd "${OUT:-build/visual_tour/ios}" && pwd)"
WANTED="${1:-}"

# The newest available iOS runtime, then for each device family the newest
# device type that runtime supports, newest meaning the one that needs the
# latest iOS: "key|runtime id|device type id|name".
types_json=$(mktemp)
xcrun simctl list devicetypes --json > "$types_json"
devices=$(xcrun simctl list runtimes --json | WANTED="$WANTED" TYPES="$types_json" python3 -c '
import json, os, re, sys

families = [
    ("ipad-mini", r"^iPad mini"),
    ("ipad", r"^iPad \("),
    ("ipad-air-11", r"^iPad Air 11"),
    ("ipad-air-13", r"^iPad Air 13"),
    ("ipad-pro-11", r"^iPad Pro 11"),
    ("ipad-pro-13", r"^iPad Pro 13"),
    ("iphone-pro-max", r"^iPhone \d+ Pro Max$"),
    ("iphone-small", r"^iPhone (SE|\d+e$)"),
]
wanted = {k for k in os.environ["WANTED"].split(",") if k}
runtimes = [
    r for r in json.load(sys.stdin)["runtimes"]
    if r.get("platform") == "iOS" and r.get("isAvailable")
]
if not runtimes:
    sys.exit("No available iOS simulator runtime")
runtime = max(runtimes, key=lambda r: [int(p) for p in r["version"].split(".")])
types = runtime.get("supportedDeviceTypes", [])
min_runtime = {
    t["identifier"]: t.get("minRuntimeVersion", 0)
    for t in json.load(open(os.environ["TYPES"]))["devicetypes"]
}
for key, pattern in families:
    if wanted and key not in wanted:
        continue
    matches = [
        (min_runtime.get(t["identifier"], 0), i, t)
        for i, t in enumerate(types)
        if re.search(pattern, t["name"])
    ]
    if matches:
        t = max(matches, key=lambda m: m[:2])[2]
        print("|".join([key, runtime["identifier"], t["identifier"], t["name"]]))
')
rm -f "$types_json"
if [ -z "$devices" ]; then
  echo "No matching simulators" >&2
  exit 1
fi

summary="$OUT/summary.md"
{
  echo "| Device | Result | Steps failed | Turned to landscape | Failures |"
  echo "| --- | --- | --- | --- | --- |"
} > "$summary"
failed=0

while IFS='|' read -r key runtime type name; do
  dir="$OUT/$key"
  mkdir -p "$dir"
  echo "::group::$name ($key)"
  udid=$(xcrun simctl create "tour-$key" "$type" "$runtime")
  xcrun simctl boot "$udid"
  xcrun simctl bootstatus "$udid" -b > /dev/null
  xcrun simctl status_bar "$udid" override --time 9:41 \
    --batteryState charged --batteryLevel 100 --wifiBars 3 --cellularBars 4 || true

  # Simulator.app shows the device so it can be turned: iPads ignore the
  # app's own orientation requests. It stays open from device to device.
  open -a Simulator --args -CurrentDeviceUDID "$udid" || true
  sleep 5

  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$dir/raw.mp4" \
    > /dev/null 2>&1 < /dev/null &
  recorder=$!
  sleep 2

  # A launch now and then never reaches the test; give each attempt
  # 15 minutes and retry once.
  for attempt in 1 2; do
    : > "$dir/drive.log"
    TOUR_OUT="$dir" flutter drive \
      --driver=test_driver/visual_tour_driver.dart \
      --target=integration_test/visual_tour_test.dart \
      -d "$udid" > "$dir/drive.log" 2>&1 < /dev/null &
    drive=$!

    # The test prints TOUR_TURN when it wants the device turned; Cmd-Left
    # and Cmd-Right turn the simulator. Needs accessibility access for
    # System Events, which GitHub's macOS runners grant. osascript gets 20
    # seconds, so a permission prompt cannot hang the run.
    handled=0
    started=$SECONDS
    timed_out=0
    while kill -0 "$drive" 2> /dev/null; do
      turns=$(grep -c "TOUR_TURN" "$dir/drive.log" 2> /dev/null || true)
      while [ "$handled" -lt "${turns:-0}" ]; do
        handled=$((handled + 1))
        case "$(grep "TOUR_TURN" "$dir/drive.log" | sed -n "${handled}p")" in
          *landscape*) arrow=123 ;;
          *) arrow=124 ;;
        esac
        perl -e 'alarm 20; exec @ARGV' osascript \
          -e 'tell application "Simulator" to activate' \
          -e "tell application \"System Events\" to key code $arrow using command down" \
          >> "$dir/turn.log" 2>&1 < /dev/null || echo "turn failed" >> "$dir/turn.log"
      done
      if [ $((SECONDS - started)) -gt 900 ]; then
        timed_out=1
        pkill -P "$drive" 2> /dev/null || true
        kill "$drive" 2> /dev/null || true
        echo "Timed out after 15 minutes (attempt $attempt)" >> "$dir/drive.log"
        break
      fi
      sleep 1
    done
    wait "$drive"
    status=$?
    [ "$timed_out" -eq 1 ] && status=124
    [ "$status" -ne 124 ] && break
  done

  kill -INT "$recorder" 2> /dev/null
  wait "$recorder" 2> /dev/null
  xcrun simctl shutdown "$udid" || true
  xcrun simctl delete "$udid" || true

  # Keep the artifact small: a 960x540 recording, JPEG screenshots.
  # avconvert ships with macOS; ffmpeg may not be installed.
  if [ -s "$dir/raw.mp4" ]; then
    if avconvert --source "$dir/raw.mp4" --preset Preset960x540 \
      --output "$dir/recording.mp4" --replace > /dev/null 2>&1; then
      rm "$dir/raw.mp4"
    else
      mv "$dir/raw.mp4" "$dir/recording.mp4"
    fi
  fi
  for png in "$dir"/*.png; do
    [ -e "$png" ] || continue
    sips -Z 1600 -s format jpeg -s formatOptions 85 "$png" \
      --out "${png%.png}.jpg" > /dev/null && rm "$png"
  done

  # "failed count<TAB>turned to landscape<TAB>first failures"
  IFS=$'\t' read -r steps_failed turned detail < <(python3 -c '
import json, sys
try:
    report = json.load(open(sys.argv[1]))
except Exception:
    print("?\t?\t")
    sys.exit()
failures = report["failures"]
turned = report.get("turned", {}).get("landscape")
print(len(failures), "yes" if turned else "no",
      "; ".join(failures)[:300].replace("|", "/"), sep="\t")
' "$dir/report.json")
  if [ "$status" -eq 0 ] && [ "$steps_failed" = "0" ]; then
    result="passed"
  else
    result="FAILED"
    if [ -z "$detail" ]; then
      detail=$(grep -m1 -E "Error|Exception|FAILED|failed" "$dir/drive.log" | cut -c1-160 | tr '|' '/')
    fi
    failed=1
  fi
  echo "| $name | $result | $steps_failed | $turned | $detail |" >> "$summary"
  echo "$name: $result (drive exit $status, steps failed $steps_failed)"
  echo "::endgroup::"
done <<< "$devices"

cat "$summary"
exit "$failed"
