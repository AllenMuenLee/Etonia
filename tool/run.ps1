# Runs the app with the local dart_defines.json, which Git ignores, so the
# AI assistant has its key. Any arguments are passed on to `flutter run`:
#   .\tool\run.ps1 -d windows
$root = Split-Path -Parent $PSScriptRoot
$defines = Join-Path $root 'dart_defines.json'
$flutterArgs = @('run')
if (Test-Path $defines) {
  $flutterArgs += "--dart-define-from-file=$defines"
} else {
  Write-Warning 'dart_defines.json not found; running without it.'
}
$flutterArgs += $args
Push-Location $root
try {
  if (Get-Command fvm -ErrorAction SilentlyContinue) {
    fvm flutter @flutterArgs
  } else {
    flutter @flutterArgs
  }
} finally {
  Pop-Location
}
