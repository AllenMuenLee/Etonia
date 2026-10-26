#!/usr/bin/env bash
# Runs integration_test/visual_tour_test.dart on one Android emulator,
# recording its screen, for comparison with tool/ios_visual_tour.sh.
#
#   tool/android_visual_tour.sh <emulator-serial> [name]
#
# The app's data on that device is cleared first, so use an emulator, never
# a device with notes on it. Results go to $OUT/<name> (default
# build/visual_tour/android/<serial>). Set FLUTTER to use another SDK.
set -uo pipefail
export MSYS_NO_PATHCONV=1

SERIAL="${1:?usage: tool/android_visual_tour.sh <emulator-serial> [name]}"
case "$SERIAL" in
  emulator-*) ;;
  *) echo "Refusing to clear app data on $SERIAL: not an emulator" >&2; exit 2 ;;
esac
FLUTTER="${FLUTTER:-flutter}"
dir="${OUT:-build/visual_tour/android}/${2:-$SERIAL}"
rm -rf "$dir"
mkdir -p "$dir"
adb -s "$SERIAL" shell pm clear com.etonia.app > /dev/null 2>&1 || true

TOUR_OUT="$dir" "$FLUTTER" drive \
  --driver=test_driver/visual_tour_driver.dart \
  --target=integration_test/visual_tour_test.dart \
  -d "$SERIAL" > "$dir/drive.log" 2>&1 &
drive=$!

# A tablet keeps its orientation whatever the app asks; the test prints
# TOUR_TURN when it wants the emulator turned.
tail -n +1 -f "$dir/drive.log" 2> /dev/null | while IFS= read -r line; do
  case "$line" in
    *"TOUR_TURN "*) adb -s "$SERIAL" emu rotate > /dev/null 2>&1 ;;
  esac
done &
watcher=$!

# screenrecord stops itself after 180 s, so record in pieces until the
# test is over.
until grep -q "+0: visual tour" "$dir/drive.log" 2> /dev/null; do
  kill -0 "$drive" 2> /dev/null || break
  sleep 0.5
done
part=0
while kill -0 "$drive" 2> /dev/null; do
  part=$((part + 1))
  adb -s "$SERIAL" shell screenrecord --time-limit 170 --bit-rate 6000000 \
    "/sdcard/tour_$part.mp4" &
  recorder=$!
  while kill -0 "$recorder" 2> /dev/null && kill -0 "$drive" 2> /dev/null; do
    sleep 1
  done
  adb -s "$SERIAL" shell pkill -INT screenrecord > /dev/null 2>&1 || true
  wait "$recorder" 2> /dev/null
done
wait "$drive"
status=$?
kill "$watcher" 2> /dev/null
pkill -f "tail -n +1 -f $dir/drive.log" 2> /dev/null || true
sleep 1
for i in $(seq 1 "$part"); do
  adb -s "$SERIAL" pull "/sdcard/tour_$i.mp4" "$dir/recording_$i.mp4" > /dev/null &&
    adb -s "$SERIAL" shell rm "/sdcard/tour_$i.mp4"
done

for py in python3 python; do "$py" -c '' 2> /dev/null && break; done
"$py" - "$dir/report.json" << 'EOF'
import json, sys
report = json.load(open(sys.argv[1]))
for step in report["steps"]:
    print(f"{step['name']:<22} {'ok' if step['ok'] else 'FAILED':<7} {step['error'] or ''}")
EOF
echo "flutter drive exit $status; results in $dir"
exit "$status"
