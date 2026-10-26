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
# device type that runtime supports: "key|runtime id|device type id|name".
devices=$(xcrun simctl list runtimes --json | WANTED="$WANTED" python3 -c '
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
for key, pattern in families:
    if wanted and key not in wanted:
        continue
    matches = [t for t in types if re.search(pattern, t["name"])]
    if matches:
        t = matches[-1]
        print("|".join([key, runtime["identifier"], t["identifier"], t["name"]]))
')
if [ -z "$devices" ]; then
  echo "No matching simulators" >&2
  exit 1
fi

summary="$OUT/summary.md"
{
  echo "| Device | Result | Steps failed | Detail |"
  echo "| --- | --- | --- | --- |"
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

  xcrun simctl io "$udid" recordVideo --codec=h264 --force "$dir/raw.mp4" \
    > /dev/null 2>&1 &
  recorder=$!
  sleep 2

  TOUR_OUT="$dir" flutter drive \
    --driver=test_driver/visual_tour_driver.dart \
    --target=integration_test/visual_tour_test.dart \
    -d "$udid" > "$dir/drive.log" 2>&1
  status=$?

  kill -INT "$recorder" 2> /dev/null
  wait "$recorder" 2> /dev/null
  xcrun simctl shutdown "$udid" || true
  xcrun simctl delete "$udid" || true

  # Keep the artifact small: a half-size recording, JPEG screenshots.
  if [ -s "$dir/raw.mp4" ]; then
    ffmpeg -loglevel error -y -i "$dir/raw.mp4" \
      -vf "scale=trunc(iw/4)*2:trunc(ih/4)*2" \
      -c:v libx264 -crf 28 -preset veryfast -pix_fmt yuv420p -an \
      "$dir/recording.mp4" && rm "$dir/raw.mp4"
  fi
  for png in "$dir"/*.png; do
    [ -e "$png" ] || continue
    sips -Z 1600 -s format jpeg -s formatOptions 85 "$png" \
      --out "${png%.png}.jpg" > /dev/null && rm "$png"
  done

  steps_failed=$(python3 -c '
import json, sys
try:
    print(len(json.load(open(sys.argv[1]))["failures"]))
except Exception:
    print("?")
' "$dir/report.json")
  if [ "$status" -eq 0 ] && [ "$steps_failed" = "0" ]; then
    result="passed"
    detail=""
  else
    result="FAILED"
    detail=$(grep -m1 -E "Error|Exception|FAILED|failed" "$dir/drive.log" | cut -c1-160 | tr '|' '/')
    failed=1
  fi
  echo "| $name | $result | $steps_failed | $detail |" >> "$summary"
  echo "$name: $result (drive exit $status, steps failed $steps_failed)"
  echo "::endgroup::"
done <<< "$devices"

cat "$summary"
exit "$failed"
