# Implementation Prompt 6: Selection-Aware AI Assistant

You are adding a multimodal AI assistant to **Greatnote**, a Flutter tablet
application for Android and iPadOS. The editor already supports low-latency
vector ink, erasing, lasso/rectangle selection, transformations, Copy/Cut/Paste,
keyboard shortcuts, responsive layouts, light/dark themes, and accessible
controls. Preserve all of that behavior.

Read the existing implementation and tests before changing anything,
especially:

- `lib/features/editor/editor_screen.dart`
- `lib/features/editor/widgets/selection_action_bar.dart`
- `lib/features/editor/widgets/tool_palette.dart`
- `lib/features/editor/ink/ink_controller.dart`
- `lib/features/editor/ink/ink_selection.dart`
- `lib/features/editor/ink/ink_painter.dart`
- `lib/features/editor/ink/stroke.dart`
- `lib/shared/layout/breakpoints.dart`
- `lib/app/theme/app_tokens.dart`
- the selection, layout, accessibility, and golden tests under
  `test/features/editor/`

Extend the existing selection pipeline. Do not create a second ink document,
selection implementation, or canvas.

## Goal

For every non-empty, stable selection, add an **AI** action to the selection's
contextual controls. It must be the trailing action after Copy and Cut, so it
appears at the top-right of the selected area in the normal left-to-right
layout. The control must visibly contain the text `AI`; do not make it an
unlabelled sparkle icon.

Pressing AI opens a chatbot panel. The user can place that panel on either the
physical left or physical right side of the editor. The assistant receives a
PNG rendering of the selected ink as visual context. It offers quick actions,
including exactly:

- `Explain this`
- `Grade this`

It also supports ordinary typed follow-up messages in the same conversation.

Use Google's hosted **Gemma 4 31B instruction-tuned model** through the Gemini
API. The exact model ID is:

```text
gemma-4-31b-it
```

Use the `generateContent` REST endpoint:

```text
POST https://generativelanguage.googleapis.com/v1beta/models/gemma-4-31b-it:generateContent
```

Authenticate with the `x-goog-api-key` request header. The user supplied the
credential separately. Never put its literal value in Dart source, tests,
fixtures, documentation, logs, screenshots, generated files, or version
control.

Official API references:

- https://ai.google.dev/gemma/docs/core/gemma_on_gemini_api
- https://ai.google.dev/api/generate-content
- https://ai.google.dev/gemini-api/docs/generate-content/image-understanding

## Scope

Implement:

- the visible `AI` selection action;
- deterministic rendering of the selected vector ink to an in-memory PNG;
- a left/right AI panel with a header, selection preview, conversation,
  quick-action buttons, composer, send button, loading state, error state,
  retry, and close action;
- a user-facing left/right side chooser in the panel header;
- an injectable, mockable AI client;
- Gemini `generateContent` requests containing the selection image and chat
  text;
- in-memory conversation state for the current editor session;
- robust networking, parsing, cancellation/stale-response handling, and
  automated tests.

Do not add handwriting recognition, OCR, document-wide AI context, cloud note
storage, user accounts, conversation persistence, audio input, generated
images, tool/function calling, ink editing by the model, or an AI agent that
can mutate the note. Do not send the whole page, app screenshot, selection
handles, contextual action bar, tool palette, app bar, or AI panel to the
model.

## Selection action and interaction

- Extend `SelectionActionBar` with a third real Flutter button labelled `AI`,
  after Copy and Cut.
- Its tooltip and semantic label must both clearly say `AI assistant`.
- Keep the action bar above the selection frame when space allows and below it
  otherwise. Align the bar so the AI action is nearest the frame's top-right
  corner in LTR without allowing any part of the bar to leave the page.
  Preserve correct RTL behavior by treating AI as the trailing action.
- Keep a minimum 48 logical-pixel interactive target and the existing focus,
  hover, pressed, selected, and theme behavior.
- The action is available only for a non-empty selection and while no lasso or
  transform gesture is active. The existing action bar already hides during
  those gestures; preserve that invariant.
- Pressing AI must not start a canvas pointer gesture, change the selected
  tool, mutate ink, clear selection, or repaint completed ink.
- Pressing AI creates a new immutable selection-context snapshot and opens the
  panel. Reopening AI for a different selection starts a new conversation.
- Reopening AI for the same still-current selection restores its in-memory
  conversation and does not make a network request by itself.
- If the selection changes after the panel opens, keep the existing chat and
  snapshot unchanged and show a small `Selection changed` notice with a
  `Use current selection` action. That action captures the new selection and
  starts a new conversation. Never silently switch the image beneath an
  existing conversation.

Wire callbacks into `SelectionActionBar`; do not make that widget own the AI
service or editor-session state.

## Selection image context

Create a focused renderer such as `SelectionImageRenderer`. It accepts an
immutable snapshot of the selected strokes and produces PNG bytes without
mounting or screenshotting a widget.

Rendering rules:

- Snapshot each selected stroke's points, width, color, dot status, and
  document order before starting asynchronous work. Do not retain a live
  mutable dependency on `InkController` or selected indices.
- Crop to the union of the selected strokes' rendered bounds, expanded by
  `12` logical pixels of padding on every side.
- Render only selected strokes, in document order, using the same round caps,
  joins, widths, colors, and dot behavior as the editor.
- Use an opaque background resolved from the current writing-surface theme so
  light ink remains visible in dark mode and dark ink remains visible in light
  mode. Record which brightness was used in the snapshot; a later theme
  change must not change an already-open conversation's image.
- Exclude selection outlines, handles, action buttons, lasso chrome, and every
  unselected stroke, even if their bounds overlap the crop.
- Rasterize through `dart:ui` (`PictureRecorder`, `Canvas`, `Image`, and
  `toByteData(format: ImageByteFormat.png)`) rather than adding a screenshot
  package.
- Preserve aspect ratio. Target `2.0` physical pixels per logical pixel, then
  reduce the scale when necessary so neither dimension exceeds `2048` pixels.
  Never upscale beyond `2.0`.
- Reject non-finite or empty geometry and impossible image sizes with a typed,
  user-presentable error. Do not allocate an unbounded bitmap.
- Dispose native `ui.Image` objects after extracting the bytes.
- Keep PNG bytes only in memory for the conversation lifetime. Do not write
  them to disk, Photos, clipboard, cache, analytics, or logs.

The preview shown in the AI panel must use these exact PNG bytes, not a second
rendering path. Constrain the preview to a compact card without distorting its
aspect ratio.

## Chat panel and responsive layout

Add an `AiAssistantPanel` owned by `EditorScreen` session state.

Header:

- title `AI assistant`;
- a two-state accessible control for physical `Left` and `Right` placement;
- close button;
- model status may say `Gemma 4 31B`, but do not expose the API key.

Body:

- the selection-image preview and a short disclosure such as
  `Only the selected ink is sent to the AI service`;
- the quick actions `Explain this` and `Grade this` before the first user
  message, and keep them available after a response for convenience;
- a scrollable chronological chat transcript with visually and semantically
  distinct user and assistant messages;
- selectable assistant text;
- an indeterminate progress indicator while waiting;
- an inline, non-destructive error message with `Retry`;
- an empty state that invites the user to choose a quick action or enter a
  question.

Composer:

- multiline text field with a useful hint;
- Send button and keyboard submission appropriate to a multiline field;
- trim input and reject an empty message;
- disable duplicate submission while one request is active;
- preserve the unsent draft across a breakpoint or orientation rebuild;
- keep editor Copy/Cut/Paste shortcuts from intercepting commands while the
  text field is focused;
- keep focus and the on-screen keyboard usable when the panel side changes.

Layout:

- On expanded and medium widths, show a fixed-width panel beside the editor
  content, defaulting to the right. Use a width of `360` logical pixels, but
  constrain it to available space. Recompute the page/palette region so the
  panel never covers the writing surface or tool palette: the page fills,
  edge to edge, exactly the width the panel leaves, and the palette floats
  over it as before.
- Opening, closing, or moving the panel resizes the writing area, which
  rescales every page fit to its width. The page column must keep the same
  place of the same page in the middle of the area across the resize: work
  out which page holds the middle, and how far down it, before the resize,
  and scroll so the same page and fraction hold the middle after it (and
  likewise across, as a fraction of the column's width). Never keep the raw
  pixel offset, which lands somewhere else in the note, often on another
  page, and never report this as a page change or jump to a page's top. A
  pinch zoom, which keeps the area's size, is not re-anchored this way.
- Toggling the panel must not make page content reload visibly: anything
  rendered for a page's old size keeps showing, scaled, until its render
  for the new size is ready.
- The Left/Right choice refers to the physical screen edge, independent of
  text direction. Mirror only the internal row ordering for RTL.
- Animate side changes with the existing motion tokens and honor reduced
  motion.
- On compact widths, show the panel as a modal side sheet from the chosen
  physical edge, at most `min(360, 88% of screen width)`. Do not crush the
  writing surface to an unusable size. Add a dismissible semantic barrier and
  restore focus sensibly when it closes.
- Preserve panel-open state, chosen side, chat, draft, and selection snapshot
  through orientation and breakpoint rebuilds in the same `EditorScreen`.
- Closing the panel does not erase the conversation. A newly captured
  selection does.

Use existing theme tokens. Add feature-level AI layout/config values rather
than scattering numbers through widgets.

## Quick-action behavior

Quick actions send normal chat messages and appear in the transcript as user
messages.

`Explain this` uses this instruction:

```text
Explain the selected handwritten content clearly. Identify what is shown,
walk through the reasoning or meaning step by step, and mention any part that
is too ambiguous to read instead of guessing.
```

`Grade this` uses this instruction:

```text
Review the selected handwritten work for correctness. State what is correct,
identify mistakes with specific explanations, and suggest an improved answer.
If no question, answer key, rubric, or point total is visible, say what
assumptions you are making and give formative feedback rather than inventing
an authoritative score.
```

Use a stable system instruction for all conversations:

```text
You are Greatnote's concise, supportive study assistant. The user supplies an
image cropped from their handwritten note. Base your answer on visible
evidence, say when handwriting or intent is uncertain, do not fabricate
missing context, and use readable plain text or Markdown. For grading, explain
the reasoning and assumptions; never claim an official grade without a
provided rubric.
```

Do not run OCR locally and replace the image with guessed text. The image is
the source context.

## AI state and architecture

Keep concerns separated:

- `InkController` continues to own only ink, selection, transforms, and the
  in-app vector clipboard.
- `SelectionImageRenderer` owns deterministic vector-to-PNG rendering.
- `AiClient` is an abstract interface that accepts an immutable request and
  returns assistant text or a typed failure.
- `GeminiAiClient` owns HTTP serialization, authentication, timeout behavior,
  and response parsing.
- An `AiAssistantController` or equivalent owns panel side/open state,
  snapshot, messages, draft, request state, error, and stale-request tokens.
- `EditorScreen` constructs/injects these collaborators and owns their
  lifetimes. Allow tests to inject fakes without network calls or real keys.

Model messages should be immutable. Use explicit roles (`user`, `model`) and
request states (`idle`, `sending`, `failed`). Do not encode state implicitly in
widget presence.

When a request starts, assign it a monotonically increasing request token. If
the panel context is replaced, the controller is disposed, or a newer request
supersedes it, ignore the older response. Closing the panel may let the request
finish and retain the response; replacing the context must invalidate it.

## Gemini request contract

Add `http` as the minimal networking dependency unless the repository gains
an equivalent HTTP abstraction before implementation.

For each request:

- set `Content-Type: application/json`;
- set `x-goog-api-key` from injected runtime configuration;
- never put the key in the URL;
- call the exact `gemma-4-31b-it:generateContent` endpoint above;
- include the PNG as an `inline_data` part with `mime_type: image/png` and
  base64 data in the first user turn;
- include the first user prompt as a text part in that same turn;
- include accepted user/model history in chronological order for follow-ups;
- because `generateContent` is stateless, continue including the original
  image-bearing first turn when sending later turns;
- send the system instruction via the API's `system_instruction` field;
- request plain text/Markdown output, not JSON;
- use a finite timeout (default `45 seconds`), configurable for tests.

Parse assistant text defensively from `candidates[].content.parts[].text`.
Combine multiple text parts in order. Treat missing candidates, empty text,
safety blocks, malformed JSON, non-2xx status, timeout, and connectivity errors
as typed failures. Show a concise user-facing message and retain the failed
user message plus enough request state for an explicit Retry. Never show raw
response bodies that may contain sensitive data.

Do not automatically retry a submitted chat turn: an automatic retry can
produce duplicate billable generations. Retry only after the user presses
Retry. Do not add a user or model message twice when retrying.

## API-key and release safety

The credential supplied with this task is sensitive and has already been
shared in conversation. Do not repeat it in the completion report. Recommend
rotating it before use.

For this client-only prototype:

- read the key from a compile-time/runtime injection point named
  `GEMINI_API_KEY`, such as `--dart-define=GEMINI_API_KEY=...`;
- centralize access behind an `AiApiConfig` injected into `GeminiAiClient`;
- when the key is absent, keep the AI UI testable but disable sending and show
  a clear configuration message;
- never log headers, request JSON, base64 image data, or chat content;
- ensure `.gitignore` covers any optional local environment file used by the
  developer, without deleting or rewriting unrelated ignore rules;
- use fake keys in all tests.

Document clearly that a key embedded in a Flutter mobile binary can be
extracted and is **not production-safe**. Keep `AiClient` replaceable so a
production build can call an authenticated Greatnote backend proxy that owns
the provider key. Do not build that backend in this task, but do not pretend
`--dart-define` makes a mobile secret secure.

Add Android's `android.permission.INTERNET` to the main manifest if it is not
already present. Use HTTPS and do not weaken iOS App Transport Security.

## Lifecycle, privacy, and failure behavior

- Dispose every controller, focus node, scroll controller, HTTP client owned
  by the feature, notifier, and native image resource.
- Do not send anything merely because AI was opened. Send only after the user
  presses a quick action or Send.
- Keep the selection image local until that explicit send.
- A network failure must never change ink, selection, clipboard, tools, or the
  conversation's already-successful messages.
- The user can close the panel, switch tools, draw, erase, transform, or clear
  selection after a snapshot is captured; the open conversation continues to
  reference the immutable captured PNG.
- If the app is disposed during capture or a request, complete safely without
  calling listeners after disposal.
- Avoid printing chat content in debug output and tests.

## Automated tests

Tests must not call the real Gemini API and must never require the real key.

### Selection image renderer tests

- a dot produces a finite non-empty PNG;
- several differently colored and sized strokes preserve z-order and style;
- output bounds include exactly the configured padding;
- unselected strokes and selection chrome are absent;
- dark- and light-theme writing-surface backgrounds are applied correctly;
- a large selection is downscaled so neither dimension exceeds 2048 pixels;
- a small selection is not upscaled beyond 2x;
- empty/non-finite/absurd geometry fails without a large allocation;
- repeated rendering of the same snapshot has the same dimensions and
  visually equivalent pixels;
- native images are released after encoding.

### Gemini client tests

With a fake HTTP client, verify:

- endpoint, method, headers, exact model ID, and timeout;
- the key is in `x-goog-api-key`, not the URL or serialized body;
- PNG bytes are base64 encoded as `image/png` inline data;
- the system instruction, first prompt, and chronological follow-up history
  are serialized correctly;
- multiple response text parts are combined in order;
- empty candidates, safety blocks, malformed JSON, non-2xx responses,
  timeout, and connectivity failures map to the expected typed error;
- no diagnostic string contains the key, base64 image, or full response body.

### Controller tests

- opening AI snapshots the current selection without changing the document;
- opening makes no network request;
- Explain and Grade submit their exact prompt and the captured PNG;
- ordinary typed messages and follow-ups keep correct history;
- empty/whitespace messages are ignored;
- duplicate sends are blocked while a request is active;
- Retry does not duplicate transcript messages;
- a stale response cannot enter a replaced conversation;
- a changed selection shows the notice but does not silently replace context;
- `Use current selection` resets chat and invalidates the old request;
- close/reopen retains state for the same context;
- side, open state, draft, messages, and snapshot survive responsive rebuilds;
- missing API configuration yields a clear disabled state.

### Widget, accessibility, and layout tests

- a non-empty stable selection shows Copy, Cut, and the visible `AI` label in
  that order;
- AI is the trailing/top-right action and the bar remains clamped at page
  edges;
- pressing AI does not leak a pointer event to the canvas;
- the panel defaults right and can be moved left and back right;
- expanded/medium layouts reserve panel space without overlap or overflow,
  and the page fills exactly the width the panel leaves;
- opening and closing the panel repeatedly, scrolled to the middle of a
  later page of a multi-page note, keeps that page and the same place on it
  in view each time;
- compact layout uses a dismissible side sheet from the chosen edge;
- `Explain this` and `Grade this` are visible, focusable, and have correct
  semantics;
- transcript, progress, error, retry, preview disclosure, composer, send,
  side choice, and close controls are accessible by keyboard and screen
  reader;
- editor clipboard shortcuts do not steal focus-field editing shortcuts;
- closing/reopening and orientation changes do not lose the conversation;
- light/dark and representative left/right/compact golden baselines are
  added or deliberately updated;
- existing pen, eraser, selection, transform, clipboard, layout, performance,
  and golden tests continue to pass.

## Acceptance criteria

- Selecting ink shows a contextual `AI` action at the top-right/trailing end
  of the existing selection controls.
- Pressing AI opens a polished chatbot without sending data yet.
- The user can put the chatbot on the left or right.
- Explain this, Grade this, and free-form messages send only the captured
  selected-ink PNG plus the conversation text to `gemma-4-31b-it`.
- The model response appears in the panel, and follow-up conversation works.
- Loading, empty, missing-key, timeout, blocked, server-error, malformed, and
  retry states are understandable and non-destructive.
- No secret or selected image is committed, logged, cached to disk, or exposed
  in error text.
- AI work never mutates or degrades ink, selection, transforms, clipboard,
  smoothing, erasing, or editor responsiveness.
- Formatting, static analysis, unit tests, widget tests, integration tests,
  and existing plus updated golden tests pass.

## Completion report

At the end, report:

- the files and dependencies changed;
- how the selection snapshot is isolated and rendered to PNG;
- the exact crop, padding, scale, size cap, background, and stroke-rendering
  rules;
- panel behavior at each breakpoint and how the side choice is retained;
- the quick-action prompts and chat-history policy;
- the Gemini endpoint/model/request structure and typed error handling;
- how the key was injected without committing or logging it, plus the mobile
  binary security limitation;
- all tests and golden files added or changed;
- commands run and their results;
- emulator/simulator and physical-device verification separately, without
  inventing device results;
- deferred production backend/proxy work and all other out-of-scope items.
