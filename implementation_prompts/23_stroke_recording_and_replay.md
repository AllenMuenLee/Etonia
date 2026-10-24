# Implementation Prompt 23: Audio and Stroke Time-Synchronized Recording and Replay

You are working in the **Greatnote** (`Etonia`) Flutter tablet repository. Add **audio recording synchronized with handwriting stroke completion timing and interactive timeline replay** to the editor.

The app already features a multi-page ink canvas, pen/highlighter styles, area/stroke erasers, lasso selection, sticky notes, background PDF/image rendering, undo/redo, document persistence (schema 5), and PDF export. Preserve all existing document integrity, low-latency drawing pipelines, and responsive tablet UI contracts.

---

## Product outcome

1. **Main Bar Integration (EditorAppBar Only):**
   - Place the recording controls **exclusively in the main bar** (`EditorAppBar`), alongside navigation and note settings. Keep the floating tool palette (`ToolPalette`) free of recording controls, preserving its focus as a pure drawing tool surface.
   - The main bar houses:
     - **Idle state:** A clean microphone button (`AppIcons.microphone`) with tooltip "Record audio & strokes".
     - **Recording state:** A pulsing recording indicator, live elapsed time readout (`01:42`), pause/resume toggle, and stop button.
     - **Replay state:** A synchronized audio/stroke playback scrubber bar docking under or within the main bar, featuring play/pause, scrub slider, playback speed multiplier (0.75x, 1.0x, 1.25x, 1.5x, 2.0x), and close replay button.
2. **Stroke Completion Memorization ("Memorize when each stroke complete"):**
   - While recording is active, every completed writing action captures its exact completion timestamp:
     - When a pen or highlighter stroke finishes (`ActiveStroke.finish()`), its completion time relative to the audio start (`completedAtMs`) is memorized on the `Stroke` instance.
     - Individual sample timings (`timeOffsetsMs`) are preserved so strokes can animate organically.
     - Erased strokes record their erasure timestamp (`erasedAtMs`) so ink removal is also faithfully reproduced during replay.
3. **Synchronized Playback & Tap-to-Seek Replay:**
   - **Time-synchronized replay:** Playing the recording synchronizes audio playback with canvas ink revelation: strokes appear dynamically as the audio reaches their completion timestamp.
   - **Interactive stroke tap-to-seek (Audio Karaoke):** Tapping any existing stroke on the page with a finger or stylus automatically jumps the audio playback directly to the exact moment that stroke was written!
   - **Scrubbing:** Dragging the timeline slider instantly updates the audio position and reconstructs the exact visual state of the page at that millisecond.

---

## Scope

### What to build
- Main bar UI controls in `EditorAppBar` for recording lifecycle (start, pause, resume, stop) and replay bar.
- Audio recording service (`NoteAudioRecorder`) using high-quality AAC/M4A format, managing microphone permissions and background recording safety.
- Audio playback engine (`NoteAudioPlayer`) with millisecond-precision position listeners and playback rate controls.
- Extension of `Stroke` and `InkController` to capture `completedAtMs` and link strokes to active `recordingId`.
- Replay synchronization controller (`StrokeReplayController`) that filters and displays page ink according to current playback timestamp.
- Spatial tap-to-seek hit-testing allowing users to tap a stroke on canvas to jump audio to its completion time.
- Storage schema upgrade to **schema 6** in `note_content.dart` and `FileNoteRepository`: serializing audio assets, recording manifests, and stroke completion timestamps.
- High-contrast visual styling for the scrubber bar, timer readouts, and playback controls on light and dark themes.

### What to exclude
- Do not place recording buttons in the floating `ToolPalette` (they reside only in `EditorAppBar`).
- Do not transmit audio to cloud AI or perform speech-to-text transcription in this prompt (audio is recorded locally).
- Do not modify PDF export fidelity (exports render the final static document state).

---

## Architecture and existing code to build on

Inspect and integrate with:
- `lib/features/editor/widgets/editor_app_bar.dart`:
  - `EditorAppBar`: integrate recording action in the middle/trailing section of the top bar.
- `lib/features/editor/editor_screen.dart`:
  - Managing `NoteAudioRecorder`, `StrokeReplayController`, and docking the replay control strip beneath the app bar.
- `lib/features/editor/ink/stroke.dart`:
  - `Stroke`: add optional `int? completedAtMs` and `String? recordingId`.
  - `ActiveStroke.finish`: populate `completedAtMs` from the active recording timeline.
- `lib/features/editor/ink/ink_controller.dart`:
  - Managing stroke lifecycle with recording timestamps.
  - Erase history tracking: recording `erasedAtMs` for strokes deleted during active recording.
- `lib/features/editor/ink/ink_canvas.dart`:
  - Replay mode pointer handling: in replay mode, tapping on strokes triggers tap-to-seek rather than drawing new ink.
- `lib/features/library/note_content.dart`:
  - Bump `storageSchema = 6`.
  - Add `NoteRecordingTrack` model and serialize audio assets in note packages.
- `lib/app/theme/app_icons.dart`:
  - `microphone`, `microphoneActive`, `play`, `pause`, `stop`, `backward15`, `forward15`.
- `lib/app/theme/app_tokens.dart`:
  - High-contrast color tokens for the recording bar and scrubber thumb.

---

## Detailed design specifications

### 1. Main bar UI & replay scrubber layout

- **Microphone button in `EditorAppBar`:**
  - Placed in the trailing actions group of `EditorAppBar`, next to the settings button.
  - Standard touch target: `48 x 48` logical pixels with tooltip "Record audio and strokes".
- **Active recording state:**
  - When recording is active, the app bar expands or displays a compact status bar:
    - Glowing red recording indicator with a soft breathing pulse.
    - Elapsed duration timer (e.g. `03:45`) using fixed-width tabular numbers (`FontFeature.tabularFigures()`) with high contrast:
      - Dark mode: pure white text (`#FFFFFF`) on deep charcoal glass (`#1E1E1E`).
      - Light mode: deep charcoal text (`#121212`) on frosted translucent glass (`#F8F9FA`).
    - Pause / Resume icon button (`AppIcons.pause` / `AppIcons.play`).
    - Stop & Save icon button (`CupertinoIcons.stop_fill`).
- **Synchronized replay bar:**
  - Docked directly beneath `EditorAppBar` across the full width of the editor.
  - Components:
    - Play / Pause button (`44 x 44` px).
    - Current playback time / Total recording duration labels.
    - High-contrast slider track: filled track uses theme accent color, unfilled track uses high-contrast surface line, and large draggable thumb (`20 px`).
    - Speed multiplier selector dropdown: `0.75x`, `1.0x`, `1.25x`, `1.5x`, `2.0x`.
    - Dismiss replay button (`AppIcons.close`).

### 2. Stroke completion memorization model

- **Stroke timing metadata:**
  - Update `Stroke` constructor and factories to carry:
    ```dart
    final int? completedAtMs; // Milliseconds elapsed since recording start
    final String? recordingId;  // Associated audio recording UUID
    final List<int>? sampleDeltasMs; // Optional point-by-point deltas for smooth interpolation
    ```
- **Capture pipeline in `InkController`:**
  - When recording is running, `InkController` receives the active session from `NoteAudioRecorder`.
  - When `onPointerDown` begins, record start offset $t_0$.
  - When `onPointerUp` completes the gesture:
    ```dart
    final int completedAt = audioRecorder.currentElapsedMs;
    final Stroke stroke = activeStroke.finish(
      completedAtMs: completedAt,
      recordingId: audioRecorder.activeRecordingId,
    );
    ```
- **Erased stroke tracking:**
  - When an eraser gesture cuts or removes strokes during recording:
    - Maintain a tombstone entry: `ErasedStrokeRecord(strokeId: stroke.id, erasedAtMs: elapsedMs)`.
    - Allows the replay engine to show the stroke during early playback and remove it precisely when the eraser was used.

### 3. Synchronized replay engine & canvas reconstruction

- **Replay state modes:**
  - `StrokeReplayController` manages the visible time horizon $T_{\text{head}}$.
  - **Stroke Reveal Mode:**
    - Strokes with `completedAtMs <= T_head` are rendered with full opacity.
    - Strokes with `completedAtMs > T_head` are either hidden completely or shown in a semi-transparent "future ghost" mode (configurable: `0.15` opacity).
    - If a stroke was erased at $T_{\text{erase}} \le T_{\text{head}}$, it is hidden.
- **Interactive Tap-to-Seek (Audio Karaoke):**
  - While viewing a note with a recording, users can tap directly on any handwritten stroke or diagram on the canvas.
  - Spatial hit testing (`InkSelection.hitTestStroke`) finds the nearest stroke under the pointer within `16 px`.
  - If the tapped stroke has an associated `completedAtMs`:
    - The audio player seeks immediately to $\max(0, \text{completedAtMs} - 500\text{ms})$ (providing half a second of conversational context).
    - The tapped stroke flashes with a brief, high-contrast glow highlight to provide visual confirmation.
    - Audio playback resumes smoothly without stutter.

### 4. Audio recording & asset management

- **Audio format & compression:**
  - Encode audio as AAC in an MPEG-4 container (`.m4a`) at 64 kbps mono / 44.1 kHz, optimized for voice clarity and minimal file size (approx. 28 MB per hour).
- **Storage & assets:**
  - Store audio files in the note's private asset storage directory: `<note_dir>/recordings/<recording_id>.m4a`.
  - Audio files are managed as first-class document assets alongside images and PDFs.
  - Deleting a note or deleting a recording track safely unlinks and removes the corresponding audio file from disk.
- **Interruption & lifecycle handling:**
  - If the app is sent to the background or the device receives an incoming phone call:
    - Audio recorder flushes buffers and pauses gracefully.
    - On editor exit, unsaved audio is finalized and autosaved to prevent any audio loss.

### 5. Storage schema 6 migration

- Bump `storageSchema = 6` in `lib/features/library/note_content.dart`.
- Schema definition for recording tracks:
  ```json
  {
    "recordings": [
      {
        "id": "rec_uuid_1234",
        "title": "Lecture Recording 1",
        "assetPath": "recordings/rec_uuid_1234.m4a",
        "durationMs": 184500,
        "createdAt": "2026-10-23T15:30:00Z"
      }
    ]
  }
  ```
- Stroke JSON serialization:
  - Add optional keys: `"cAt": completedAtMs`, `"recId": recordingId`.
- **Backward compatibility:**
  - Files saved with schema 5 or earlier load seamlessly with `recordings = const []` and `completedAtMs = null`.
  - Strokes without timestamps are treated as pre-existing base ink and are permanently visible during replay.

---

## Automated tests

1. **Main Bar UI & Exclusivity Tests:**
   - Microphone button renders exclusively in `EditorAppBar`; verified absent from `ToolPalette`.
   - Recording status transitions: idle -> recording -> paused -> stopped.
   - High-contrast text and icon tests across light and dark themes.
2. **Stroke Timing Capture Tests:**
   - Writing strokes while recording captures accurate `completedAtMs` matching `audioRecorder.currentElapsedMs`.
   - Strokes drawn while recording is paused or inactive have null `completedAtMs`.
   - Eraser gestures record accurate `erasedAtMs`.
3. **Replay Synchronization Tests:**
   - Stepping playback time forwards and backwards correctly reconstructs visible stroke set.
   - Tap-to-seek hit testing finds the clicked stroke and invokes `audioPlayer.seek(completedAtMs)`.
   - Ghost mode / reveal mode rendering tests.
4. **Storage & Migration Tests:**
   - Schema 5 notes migrate cleanly to Schema 6 without data loss.
   - Round-trip save and load of notes containing audio recording metadata and timestamped strokes.
   - Deletion of recording tracks purges orphaned audio asset files from disk.
