#!/usr/bin/env sh
# Runs the app with the local dart_defines.json, which Git ignores, so the
# AI assistant has its key. Any arguments are passed on to `flutter run`:
#   ./tool/run.sh -d macos
cd "$(dirname "$0")/.." || exit 1
if [ -f dart_defines.json ]; then
  set -- --dart-define-from-file=dart_defines.json "$@"
else
  echo "dart_defines.json not found; running without it." >&2
fi
if command -v fvm >/dev/null 2>&1; then
  exec fvm flutter run "$@"
else
  exec flutter run "$@"
fi
