# Native ink bridge

The editor UI and document model remain Flutter. Android and iOS observe only
active-stylus input before Flutter's pointer pipeline, render a temporary native
preview, and send full-rate actual samples to the existing `InkController`.

## Data flow

1. Each visible `InkCanvas` registers its size, screen transform, current pen
   color/width, pressure setting, writing style, and stabilization value
   through `NativeInkBridge`.
2. Native code hit-tests a pen-down against those registered surfaces. Finger
   input is not consumed and continues to drive Flutter scrolling and zoom.
3. Android sends all `MotionEvent` historical samples. iOS sends UIKit
   coalesced Pencil touches. A flat `x, y, timestamp, pressure` array keeps the
   platform-channel payload small.
4. A native overlay immediately previews opaque pen ink. Jetpack Ink owns the
   wet-ink renderer on Android; PencilKit owns it on iOS. Their predicted
   samples are never sent to Dart.
5. Dart feeds actual batches into the same stroke, erase, smoothing,
   hold-to-shape, and persistence code used by the Flutter fallback.
6. On up/cancel (or hold-to-shape conversion), Dart acknowledges the packet and
   native code removes the transient preview.

If the native channel is absent, registration fails quietly and `InkCanvas`
keeps using Flutter pointer events. This is the expected path for desktop, web,
and widget tests.

## Platform files

- `android/app/src/main/kotlin/com/etonia/app/NativeInkChannel.kt`
- `ios/Runner/NativeInkChannel.swift`
- `lib/features/editor/ink/native_ink_bridge.dart`

## Device validation

Use a physical S Pen/USI tablet and iPad with Apple Pencil; emulators do not
reproduce hardware sampling or display latency. Verify pen dots, fast curves,
pressure, palm contact, lift outside the page, zoomed pages, hold-to-shape, and
eraser-end input on Android. Use profile/release mode because debug mode adds
JIT and diagnostics overhead.

The native overlay currently previews opaque pen and pencil strokes.
Highlighter strokes still receive full-rate native samples, but use Flutter
rendering so their transparency is not compounded by two layers. Android also
calls `requestUnbufferedDispatch`.

## Preview rendering

- **Android** uses Jetpack Ink's `InProgressStrokesView` and
  `MotionEventPredictor`. The view is eagerly initialized so loading native Ink
  code does not hitch the first stroke. The stabilization meter selects a
  native `SlidingWindowModel` from 0 to 32 ms; zero selects Jetpack Ink's
  pass-through model. The model upsamples at 240 Hz before native rendering.
- **iOS** uses a pencil-only `PKCanvasView`. PencilKit supplies Apple's native
  prediction, smoothing, and low-latency renderer, and the overlay requests
  120 Hz on ProMotion displays. PencilKit does not expose a stabilization
  strength, so the meter continues to tune the lightweight smoothing used for
  the persisted Flutter stroke while the transient wet ink stays entirely in
  PencilKit.

The native preview is only the latency-critical wet layer. Actual coalesced
samples still feed the shared Dart document model so files, undo, selection,
shape recognition, and cross-platform rendering keep one representation.
