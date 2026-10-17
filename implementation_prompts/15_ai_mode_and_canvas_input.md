# Implementation Prompt 15: AI Mode Button, Glowy Canvas Input, Context Circling, and On-Device Handwriting-to-Chat

You are extending **Greatnote**, a Flutter tablet note application for Android and iPadOS. The app already supports multi-page notes, low-latency Pen and Highlighter ink, erasing, lasso/rectangle selection and transforms, configurable sticky notes, undo/redo, persisted note storage, PDF/image import and export, a selection-aware multimodal AI assistant (`AiAssistantPanel`), and animated vector AI notations. Preserve all existing behaviors and the responsive tablet UI.

## Product outcome

Replace the current AI-notes visibility button in the floating tool palette with a primary **AI** mode button:

1. **Unified AI button activation:** Pressing the **AI** button in `ToolPalette` turns AI mode **on**. Using the **Select** tool to select content and pressing the contextual **AI** button in `SelectionActionBar` also activates the palette's **AI** button.
2. **Chat interface & glowy canvas strokes when on:** When the AI button is turned **on**, the AI chat interface (`AiAssistantPanel`) comes out, all AI notations on the note become visible, and drawing directly on the canvas renders a **glowy stroke path** instead of permanent document ink.
3. **Circling a spot re-chooses AI context:** While in AI canvas mode, drawing a closed loop (circling a spot on the page) selects and captures that region's content as the new context for the AI assistant (opening or updating the chat interface for the newly circled context).
4. **Writing text on the canvas transfers into words in the chat input:** While in AI canvas mode, writing handwriting strokes directly on the canvas converts those strokes into words using Android and Apple built-in on-device text recognition—**without ever showing system built-in strokes**—and transfers the recognized words into the AI chat composer input.
5. **Independent chat close vs. AI button off:** Closing the chat interface does **not** turn off the AI button (the AI button stays on and AI notations stay visible). When the AI button itself is turned **off**, all AI notations turn hidden (and the chat interface closes if still open).

## Start with the current architecture

Before editing, inspect the existing tool palette, selection action bar, AI controller/panel, ink canvas/controller/painters, and native runner entry points:

- `lib/features/editor/editor_screen.dart`
- `lib/features/editor/widgets/tool_palette.dart`
- `lib/features/editor/widgets/selection_action_bar.dart`
- `lib/features/editor/widgets/ai_assistant_panel.dart`
- `lib/features/editor/ai/ai_assistant_controller.dart`
- `lib/features/editor/ai/ai_config.dart`
- `lib/features/editor/ai/selection_image_renderer.dart`
- `lib/features/editor/ink/eraser_settings.dart` (`EditorTool`)
- `lib/features/editor/ink/ink_canvas.dart`
- `lib/features/editor/ink/ink_controller.dart`
- `lib/features/editor/ink/ink_painter.dart`
- `lib/features/editor/ink/ink_selection.dart` and `selection_geometry.dart`
- `android/app/src/main/kotlin/com/greatnote/app/MainActivity.kt` and `android/app/build.gradle.kts`
- `ios/Runner/AppDelegate.swift`
- existing AI, notation, selection, palette, accessibility, and golden tests under `test/features/editor/` and `integration_test/`

Extend the existing editor, ink, and AI pipelines cleanly. Do not create a second document model or bypass existing selection/snapshot isolation.

## AI button in the tool palette and mode lifecycle

- Replace `_aiNotesControl()` (`ai-notes-visibility-toggle` with the eye icon) in `ToolPalette` with an always-enabled **AI** button.
- Style the button consistently with `ToolPalette` and `SelectionActionBar` (visibly displaying `AI` with clear selected/active styling, a minimum `48 x 48` logical-pixel touch target, keyboard focus, hover/press states, tooltip, and semantic label/toggled state).
- Add `EditorTool.ai` (or an explicit AI mode state coordinated with `EditorTool`) owned by `EditorScreen`:
  - **Initial state:** At editor launch, the AI button is **off** (`false`) unless explicitly initialized otherwise, and any AI notations on the page are hidden while the button is off.
  - **Turning the AI button ON from the palette:** Pressing the AI button in `ToolPalette` when it is off turns the AI button **on**, unhides all AI notations on the current page (`setStrokesHidden(..., false)`), switches the active canvas tool to `EditorTool.ai`, and opens `AiAssistantPanel`. If a non-empty selection is currently active on the page, capture and activate it as the AI context; otherwise keep the current/most recent conversation or show an empty-context prompt in the panel inviting the user to circle a spot on the note.
  - **Turning the AI button ON from Selection:** When the user uses `EditorTool.select` to select content and presses the contextual `AI` button in `SelectionActionBar`, capture the selection snapshot, open `AiAssistantPanel`, **and** activate the palette's AI button (turning the AI button **on**, unhiding all AI notations, and switching the active canvas tool to `EditorTool.ai`).
  - **Closing the chat interface:** Closing `AiAssistantPanel` (via the header close button, `Escape`, or the compact modal barrier) closes only the panel (`isOpen = false`). It **must not** turn off the AI button, hide AI notations, or discard the conversation. While the AI button remains on with the chat closed, drawing on the canvas in `EditorTool.ai` still uses the glowy stroke path, and circling a spot or writing text reopens the chat panel with the new context or recognized chat input.
  - **Switching to other palette tools while AI is on:** If the user explicitly taps `Pen`, `Eraser`, `Select`, or `Sticky note` while the AI button is on, switch the active pointer tool to that tool so the user can write, erase, select, or place sticky notes on the page while the AI button remains on and AI notations remain visible.
  - **Turning the AI button OFF:** Pressing the AI button in `ToolPalette` while it is on turns it **off**:
    - mark the AI button inactive (`selected: false`);
    - hide all AI notations on the page (`setStrokesHidden(..., true)`);
    - close `AiAssistantPanel` if it is open;
    - cancel and clear any in-progress or pending ephemeral AI canvas strokes/timers;
    - if the active canvas tool was `EditorTool.ai`, restore the previously active non-AI tool (defaulting to `EditorTool.pen`).

## Glowy stroke path on the canvas

When `EditorTool.ai` is active, pointer gestures on `InkCanvas` are routed to an ephemeral AI canvas input layer rather than creating permanent document strokes:

- **Ephemeral isolation:** Strokes drawn in `EditorTool.ai` must never be appended to `InkController.strokes`, must not increment `documentRevision`, must not push undo/redo steps, and must not trigger autosave.
- **Glowy visual rendering:** Paint active and pending ephemeral AI strokes in a dedicated clipped `RepaintBoundary` layer (`AiCanvasStrokePainter`) above completed ink and notation playback:
  - Render a multi-layered glowy stroke path: a soft outer glow halo using the theme's accent/AI color with a Gaussian blur (`MaskFilter.blur(BlurStyle.normal, ...)`), a medium translucent accent aura, and a bright high-contrast inner core path with round caps and round joins (`StrokeCap.round`, `StrokeJoin.round`).
  - Smooth the pointer samples using the existing smoothing pipeline so the glowy path feels as responsive and fluid as normal writing.
  - Repaint only the ephemeral AI stroke layer during pointer moves; never rebuild the editor shell, tool palette, or completed-ink layer per sample.
- Respect `stylusOnly` and `isInputBlocked` rules identically to normal canvas writing, and keep inverted-stylus erasing working as expected.

## Circling a spot vs. writing text on the canvas

In `EditorTool.ai`, distinguish between **circling a spot** (to re-choose AI context) and **writing text** (to recognize into the chat composer):

### 1. Circling a spot to re-choose AI context

- Classify a completed single stroke as a **context-circling gesture** when all of the following hold (using named thresholds in `AiCanvasConfig` or `SelectionConfig`):
  - no other pending handwriting strokes are waiting in the current handwriting batch;
  - the stroke has sufficient path length and bounding-box extent (not a tiny dot, punctuation mark, or small letter `'o'` / `'0'`);
  - the stroke forms a closed or nearly closed loop (its end point returns near its start point relative to total stroke length, or its polyline self-intersects to enclose a significant polygon area) whose enclosed region is reasonably compact;
  - the enclosed `LassoRegion` selects at least one page element (completed non-hidden stroke, sticky note, image, or selectable PDF region within `selectablePdfBounds`).
- When a stroke is classified as circling a spot:
  - immediately clear the ephemeral glowy stroke;
  - select the encircled content (`InkSelection`) and capture its `SelectionInkSnapshot` (including any overlapping PDF paper, images, and sticky notes, exactly as `_captureForAi` does);
  - update `AiAssistantController` to use this new selection as the active AI context (resuming a matching remembered conversation or starting a new conversation) and ensure `AiAssistantPanel` is open (`open(...)` / `useSelection(...)`).

### 2. Writing text directly on the canvas into the chat input

- Any stroke in `EditorTool.ai` that is not a standalone context-circling loop is treated as **canvas handwriting for the chat input**:
  - Accumulate consecutive handwriting strokes in a temporary batch on the ephemeral AI layer so the user can write multi-stroke letters, words, and sentences naturally.
  - Start or reset a configurable idle debounce timer (for example `700 ms` in `AiCanvasConfig`) on each `pointerUp`. Pause/cancel the timer whenever a new `pointerDown` begins another stroke in the batch.
  - When the debounce timer fires (or when the user taps Send / closes or switches tools with a non-empty batch):
    1. Snapshot and clear (or smoothly fade out) the ephemeral glowy handwriting strokes from the canvas.
    2. Pass the captured strokes to the handwriting recognizer.
    3. When non-empty recognized text returns, append it to the AI chat composer (`AiAssistantController.draft` and `AiAssistantPanel`'s `TextEditingController`, separating from any existing draft text with a single space, moving the caret to the end, and opening `AiAssistantPanel` if it was closed).

## Built-in Android and Apple text recognition without system strokes

Use the platform's built-in on-device text/handwriting recognition while **strictly preventing the operating system from drawing its own built-in strokes**:

- **No system stroke overlay:**
  - Do **not** place a hidden or transparent `TextField` under the canvas pointer, do **not** enable iPadOS `UIScribbleInteraction` / `UIIndirectScribbleInteraction` on the canvas, and do **not** call Android's `InputMethodManager.startStylusHandwriting`. Greatnote's `InkCanvas` must own all pointer events and render only Greatnote's glowy stroke path.
- **Injectable Dart abstraction (`CanvasTextRecognizer` / `HandwritingRecognizer`):**
  - Define a clean, mockable interface in `lib/features/editor/ai/` that accepts an immutable handwriting batch (both the stroke point/timestamp sequences and a deterministic high-contrast offscreen PNG rendered from those strokes: dark ink on an opaque white background cropped to the union of stroke bounds plus padding).
  - Inject this recognizer into `EditorScreen` so widget and unit tests can supply deterministic fakes without platform channels or network calls.
- **Platform channel (`com.greatnote.app/handwriting_recognizer`):**
  - **iPadOS / iOS (`ios/Runner/AppDelegate.swift`):** Implement the channel using Apple's built-in `Vision` framework (`VNImageRequestHandler` and `VNRecognizeTextRequest` with `recognitionLevel = .accurate` and `usesLanguageCorrection = true`) on the rendered PNG bytes. Join recognized text observations in reading order (top-to-bottom, left-to-right). Because `Vision` operates on the offscreen bitmap, iPadOS never displays system Scribble ink.
  - **Android (`android/app/src/main/kotlin/com/greatnote/app/MainActivity.kt`):** Implement the channel using Google's on-device recognition on Android (ML Kit Text Recognition / Digital Ink Recognition on the offscreen PNG/strokes, catching missing-model or unavailable-service exceptions gracefully and returning an empty/unavailable result rather than crashing).
  - Dispose all temporary native bitmaps/images immediately after recognition and keep all stroke images in memory only for the recognition call.

## Automated tests

Add deterministic unit, widget, accessibility, and golden tests (using fake AI clients and fake handwriting recognizers—never calling the network or requiring platform channels in `flutter test`):

- **Palette AI button & selection integration:**
  - `ToolPalette` shows the `AI` button in place of the old eye-visibility button and is enabled even when the page has no AI notations yet;
  - pressing `AI` in `SelectionActionBar` after selecting with `Select` opens `AiAssistantPanel`, captures the selection context, and activates the palette's `AI` button (`selected: true`, `EditorTool.ai`);
  - pressing the palette's `AI` button when off activates it, opens `AiAssistantPanel`, and unhides any hidden AI notations;
- **Chat close vs. AI button off:**
  - closing `AiAssistantPanel` keeps the palette's `AI` button on and leaves AI notations visible;
  - turning the palette's `AI` button off hides all AI notations on the page, closes `AiAssistantPanel` if open, clears ephemeral AI strokes, and returns to the previous non-AI tool;
  - switching to `Pen`, `Eraser`, `Select`, or `Sticky note` while the AI button is on allows normal use of that tool while keeping AI notations visible until the AI button is turned off;
- **Glowy stroke rendering & isolation:**
  - drawing on the canvas in `EditorTool.ai` paints the glowy stroke path on the ephemeral AI layer and does not add strokes to `InkController.strokes`, increment `documentRevision`, or create undo steps;
- **Circling a spot on the canvas:**
  - drawing a closed loop around strokes, sticky notes, images, or a PDF region in `EditorTool.ai` selects that content, replaces/updates the AI assistant's context snapshot, reopens the chat panel if it was closed, and clears the ephemeral loop;
  - drawing a small letter `'o'` or an open stroke does not falsely trigger context replacement;
- **Direct canvas handwriting to chat input:**
  - writing one or more non-circling strokes on the canvas in `EditorTool.ai` displays the glowy path, waits for the debounce window, invokes `CanvasTextRecognizer` with the rendered stroke bitmap/strokes, clears the glowy strokes, and inserts/appends the recognized words into the chat composer (`AiAssistantController.draft` and the panel's `TextField`);
  - starting a second stroke before the debounce timer expires groups both strokes into a single recognition request;
  - recognition when the chat panel was closed while the AI button was on reopens the chat panel with the recognized text in the composer;
- **Accessibility and goldens:**
  - semantic labels, toggled states, tooltips, and `48 x 48` minimum touch targets for the new `AI` palette button;
  - updated golden baselines for the tool palette and AI mode states in light and dark themes.

Run the smallest relevant tests while iterating, then verify:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```

## Acceptance criteria

- The `AI` button replaces the old AI-notes visibility button in `ToolPalette`.
- Selecting content and pressing `AI` in `SelectionActionBar` activates the palette `AI` button as well.
- When the `AI` button is on, the chat interface opens, AI notations are visible, and drawing on the canvas uses a glowy stroke path.
- Circling a spot on the canvas in AI mode re-chooses the AI context for the encircled content.
- Writing text on the canvas in AI mode converts the strokes into words via the on-device recognizer (without showing system built-in strokes) and transfers them into the chat input.
- Closing the chat panel does not turn off the `AI` button; turning off the `AI` button hides all AI notations.
- All formatting, static analysis, unit, widget, integration, and golden tests pass.

## Completion report

At the end, report:

- files and platform channels added or changed;
- how the `AI` button state, `EditorTool.ai`, chat panel open/close state, and AI notation visibility interact;
- how the glowy stroke path is rendered and isolated from document ink and undo history;
- the heuristic/geometry rules that distinguish circling a spot from handwriting strokes;
- how Android and iPadOS built-in text recognition are invoked offscreen without showing system built-in strokes;
- all tests and golden files added or updated, commands run, and their results.
