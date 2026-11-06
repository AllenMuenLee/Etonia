# Android PDF callback abort

The reported Xiaomi Android 16 crash aborts on `DartWorker` with
`Cannot invoke native callback from a different isolate`. It is a VM-level
FFI abort, not a catchable Dart exception or an ink-rendering exception.

The installed `pdfrx 2.4.8` / `pdfrx_engine 0.4.7` uses isolate-local native font
callbacks registered with process-global PDFium. Multiple Flutter engines in
one process can replace those callbacks while another worker still uses them.
The upstream Android report matches the abort:
<https://github.com/espresso3389/pdfrx/issues/728>.

Etonia accepts PDF VIEW, SEND, and SEND_MULTIPLE intents. MainActivity used
`singleTop`, allowing a PDF opened from another task to create a second activity
and engine. It now uses `singleTask`, which routes subsequent opens to the
existing `onNewIntent` handler and SharedDocumentChannel. The existing handler
sets the new intent and forwards its documents to Dart.

The device's Android event buffer confirms the duplicate-activity sequence in
the crashing process (PID 12459):

- 21:04:38: launcher creates MainActivity in task 1191; onCreate runs in PID 12459.
- 21:07:20: a PDF SEND intent creates another MainActivity in task 1170;
  onCreate runs again in PID 12459.
- 21:08:20: PID 12459 aborts with the cross-isolate callback error.

MainActivity uses FlutterActivity's default engine creation, so these activities
create separate Flutter engines. This is the upstream failure sequence. If the
abort recurs after rebuilding and starting a fresh process, capture the launch
sequence, build mode, engine creation logs, and whether debug hot restart occurred.

Validation:

- `flutter test test/app/android_pdf_activity_test.dart --no-pub`
- Build an Android APK and inspect the merged manifest for `singleTask`.
- On-device, open a PDF, write, background the app, then repeatedly use another
  app's Open with / Share action. Confirm one MainActivity remains, new files
  reach the existing desk, and returning to an earlier PDF does not abort.

The manifest regression test and debug APK build passed. The generated debug
manifest contains `singleTask`. A post-fix on-device PDF share/write regression
has not been performed as part of this change.

A manifest change requires rebuilding and restarting the app. Hot reload cannot
apply it. Do not use hot restart as the native callback lifecycle regression test;
start with a fresh app process.
