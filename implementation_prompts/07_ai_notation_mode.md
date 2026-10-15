# Implementation Prompt 7: AI Notation Mode

You are extending the existing selection-aware AI assistant in **Greatnote**, a
Flutter tablet application for Android and iPadOS. The editor already supports
low-latency vector ink, erasing, selection and transforms, an in-app vector
clipboard, responsive layouts, and a multimodal Gemma chat about selected ink.
Preserve all of that behavior.

Read the current implementation and tests before changing anything,
especially:

- `lib/features/editor/ai/ai_client.dart`
- `lib/features/editor/ai/ai_config.dart`
- `lib/features/editor/ai/ai_assistant_controller.dart`
- `lib/features/editor/ai/gemini_ai_client.dart`
- `lib/features/editor/ai/selection_image_renderer.dart`
- `lib/features/editor/widgets/ai_assistant_panel.dart`
- `lib/features/editor/editor_screen.dart`
- `lib/features/editor/ink/ink_controller.dart`
- `lib/features/editor/ink/ink_painter.dart`
- `lib/features/editor/ink/ink_palette.dart`
- `lib/features/editor/ink/pen_settings.dart`
- `lib/features/editor/ink/stroke.dart`
- all AI, ink-controller, editor, layout, accessibility, integration, and
  golden tests under `test/` and `integration_test/`

Extend the existing AI and ink pipelines. Do not create a second canvas,
document model, or chat implementation.

## Goal

Add a user-controlled **Notation** mode to the AI chat. It is off by default.
While it is off, the assistant can only answer in the transcript and cannot
change the note. While it is on, the assistant may return structured vector
ink with its answer and Greatnote may draw that ink directly onto the note.

Notation is for visual teaching and editing marks: handwritten labels, short
handwritten notes, arrows, underlines, circles, check marks, correction marks,
and similar annotations. The model is not limited to one pen-down gesture. A
notation may contain several traces so that it can form words and compound
marks. In this prompt, one **trace** means one continuous pen-down stroke: a
dot or polyline with one palette color and logical width.

There is no per-response Add confirmation. Enabling Notation is the user's
explicit authorization for valid notation returned by messages sent while the
mode is enabled. After a response passes every local safety and staleness
check, append all of its traces directly and atomically to the existing vector
note. Never apply notation from a request sent while the mode was off, after
the user has turned it off, or from a stale response.

## Scope

Implement:

- a visible, accessible Notation toggle in the AI panel, defaulting off;
- an unambiguous disclosure that Notation sends the current note image and
  permits the AI to draw directly on it;
- deterministic rendering of the whole current writing surface for notation
  requests, in addition to the existing selected-ink image;
- a versioned, fixed JSON response format containing readable assistant text
  and zero or one multi-trace notation;
- Gemini structured JSON output plus strict local parsing and validation;
- note-normalized coordinates mapped back to page-local logical coordinates;
- automatic, atomic insertion through the existing `InkController` only when
  Notation is authorized and the response is still current;
- visible transcript status explaining what was drawn or why it was not
  applied;
- document revision tracking sufficient to reject notation based on an older
  note image;
- robust limits, typed failures, lifecycle handling, and automated tests.

Do not add a per-response confirmation dialog, an Add to note button, a
preview-only proposal workflow, automatic deletion or editing of existing
ink, pressure/time samples, Bézier commands, fills, text objects, images, SVG,
code execution, arbitrary tool/function calling, cloud persistence,
analytics, or a general undo/redo system. Do not let model output choose a
widget, stroke index, file path, URL, API operation, or executable action. The
only model-authorized mutation is atomically appending validated traces while
Notation remains enabled.

## Notation control and authorization

Add a real Flutter switch or two-state button labelled `Notation` near the
composer. It must expose a semantic checked/selected state, a tooltip or
supporting label, keyboard focus, and at least a 48-logical-pixel target. Do
not use an unexplained sparkle icon.

Use concise supporting text:

```text
When on, the current note is sent to the AI and it may draw directly on it.
```

Behavior:

- Notation is false when a new `EditorScreen` session starts.
- Its state lives in `AiAssistantController`, not the panel widget, so it
  survives closing/reopening the panel, moving it left/right, rotation, and
  responsive rebuilds in that editor session.
- Changing selections or starting a new AI conversation does not silently
  change the toggle. The prominent enabled state and disclosure must remain
  visible whenever the panel is open.
- Toggling it sends nothing by itself.
- A request captures the toggle value at submission. Only a request submitted
  with Notation on is allowed to carry notation context or produce a notation
  mutation.
- Turning Notation off while such a request is in flight immediately revokes
  permission to apply its output. The text answer may still appear, but any
  returned notation receives status `Not applied — Notation was turned off`.
- Turning the mode back on later does not revive or apply old output.
- Missing API configuration continues to disable sending; the toggle itself
  may remain operable and testable.

Do not interpret opening the AI panel, using Explain/Grade, or an old enabled
state from another editor session as authorization.

## Fixed response contract

Introduce immutable typed models such as `AiAssistantResponse`, `AiNotation`,
`AiNotationStroke`, and `AiNotationPoint`. Keep wire parsing out of widgets.

Every successful model response, whether Notation is on or off, must have this
exact versioned envelope:

```json
{
  "version": 1,
  "message": "I labelled the numerator and added an arrow.",
  "notation": {
    "label": "Numerator label and arrow",
    "coordinate_space": "note_normalized",
    "strokes": [
      {
        "ink": "blue",
        "width": 3.0,
        "points": [
          {"x": 0.38, "y": 0.29},
          {"x": 0.34, "y": 0.25},
          {"x": 0.30, "y": 0.23}
        ]
      },
      {
        "ink": "blue",
        "width": 3.0,
        "points": [
          {"x": 0.30, "y": 0.23},
          {"x": 0.32, "y": 0.27}
        ]
      }
    ]
  }
}
```

A response without drawing still uses the envelope:

```json
{
  "version": 1,
  "message": "The selected work is correct.",
  "notation": null
}
```

The contract is exact:

- `version` is the integer `1`. Reject every other value.
- `message` is a non-empty string after trimming. Display it as the assistant
  message with the existing Markdown behavior.
- `notation` is either `null` or exactly one notation object.
- `label` is a trimmed, user-facing description from 1 through 80 Unicode
  scalar values. It is display-only and is never interpreted as a command.
- `coordinate_space` is exactly `note_normalized`.
- `strokes` contains 1 through 96 stroke objects.
- `ink` is exactly one existing `InkPalette` ID: `ink`, `graphite`, `blue`,
  `red`, `green`, `orange`, `purple`, or `teal`. Resolve it through one
  central ID lookup. Never accept a raw integer, hex value, CSS color, or
  closest-color guess.
- `width` is a finite logical-pixel number in the inclusive range `1.0` to
  `20.0`, matching the default `PenConfig` limits. Do not silently clamp it.
- each `points` array contains 1 through 128 points in drawing order. One
  point renders as a dot. Two or more form an open polyline.
- the sum of point counts across all strokes may not exceed 4096. Enforce this
  locally even if the provider schema cannot express the aggregate limit.
- every `x` and `y` is a finite number in the inclusive range `0.0` to `1.0`.
  Normalized `(0, 0)` is the writing surface's top-left and `(1, 1)` its
  bottom-right; x grows right and y grows down.
- JSON booleans, numeric strings, `null`, non-finite values, and missing
  fields are invalid where a number or property is required.
- reject missing, extra, or incorrectly typed fields at every level. Do not
  accept Markdown fences, prose outside the JSON, alternate key casing,
  legacy shapes, or a top-level array.

Define one canonical JSON Schema in the AI layer and keep it aligned with the
Dart parser. It must close every object with `additionalProperties: false` and
express the fixed version, nullable notation, enums, required properties,
numeric bounds, and per-array count limits. Parser-side validation remains
mandatory because model and HTTP output is untrusted.

Use one feature configuration object for label, stroke, point, aggregate,
response-byte, and output-token limits. Set a finite response/output limit
large enough for the allowed notation but small enough to prevent an
unbounded allocation. Reject oversize output before retaining or drawing it.

When Notation is off, a non-null `notation` is a contract violation: keep the
valid text answer if it can be parsed safely, do not apply or retain the
traces, and show `Not applied — Notation is off`. This provider violation is
not permission to mutate and must be covered by tests.

## Whole-note visual context

The existing selected-ink PNG remains the conversation's focused context.
When and only when a message is submitted with Notation enabled, also create
an immutable snapshot of the entire current writing surface and render it to
an in-memory PNG. Add a focused component such as `NoteImageRenderer`; reuse
the existing vector snapshot and painting primitives rather than
screenshotting widgets.

The snapshot contains:

- every completed document stroke in document/paint order;
- each stroke's immutable points, logical width, and color resolved for the
  captured brightness;
- the opaque writing-surface background;
- the exact writing-surface local logical `Size`, whose origin is `(0, 0)`;
- the `InkController.documentRevision` at capture time;
- the selected ink's axis-aligned bounds expressed as normalized note
  coordinates, so the model can locate the chat's focus in the whole note.

Rendering rules:

- Render the full logical writing surface, including blank areas, not merely
  the union of ink bounds.
- Render only document ink. Exclude active strokes, eraser/lasso previews,
  selection frames and handles, action bars, paste prompts, tool palette, app
  bar, AI panel, cursors, and system UI.
- Use the same round caps, joins, dot behavior, widths, colors, and z-order as
  the editor.
- Target `2.0` physical pixels per logical pixel, reducing uniformly when
  needed so neither dimension exceeds `2048` pixels. Never upscale past 2x.
- Reject empty/non-finite surface sizes and absurd geometry before allocating
  a bitmap. Dispose every native image after encoding.
- Keep bytes only for the request lifetime. Never write the image to disk,
  Photos, clipboard, cache, logs, analytics, or the transcript.

The exact note PNG and metadata sent in a request define its notation
coordinate system. Device pixels, screen position, panel side, and later
layout changes are irrelevant.

Update the disclosure from Prompt 6 conditionally:

- with Notation off, preserve `Only the selected ink is sent to the AI
  service`;
- with Notation on, show `The selected ink and current note are sent to the AI
  service, and the AI may draw on the note`.

Do not send the whole note merely because the panel opened or the toggle was
turned on. Capture and send it only on an explicit quick action or Send while
Notation is enabled.

## Gemini request and model instruction

Continue using the configured `generateContent` endpoint, API-key header,
system instruction, and chronological stateless history. Do not add Gemini
tools or function calling.

For a request with Notation off:

- send the selected-ink image and conversation as before;
- instruct the model that `notation` must be `null`;
- do not capture or serialize a note image or notation metadata.

For a request with Notation on:

- require a stable, idle ink controller and finite current surface size before
  submission;
- capture the note snapshot and revision before starting the HTTP request;
- continue attaching the immutable selected-ink PNG to the conversation's
  first user turn on every stateless request, as Prompt 6 requires;
- attach the freshly captured whole-note PNG and its metadata only to the
  latest user turn which triggered this notation-enabled request. If that is
  also the first turn, both images belong to that one turn. Use adjacent short
  text parts that unambiguously identify `selected ink` and `current note`;
- include the current normalized focus bounds and logical aspect ratio as
  data, not as guessed natural-language coordinates;
- state that output coordinates address the whole-note image, not the
  selected crop;
- retain the immutable note context until the response has either been
  applied or rejected.

Update the system instruction so the model knows:

- every answer is only the version-1 JSON envelope;
- `message` is the readable chat answer;
- Notation off requires `notation: null`;
- Notation on allows a notation only when a visual addition is useful for the
  user's request; it may still return `null`;
- notation is drawn directly after validation, so `message` must not claim it
  was drawn unless the response actually includes it;
- use several continuous strokes to create handwritten words or compound
  symbols, while staying within every schema limit;
- prefer short, legible handwritten labels and concise marks rather than
  dense paragraphs;
- preserve nearby ink, place labels in visible blank space when possible, and
  use arrows or leader lines when needed;
- normalized origin, axes, surface bounds, palette IDs, and logical widths
  have their exact meanings from the contract;
- never output deletion, replacement, movement, tap, UI, or executable
  instructions;
- use `notation: null` when visual context is ambiguous or the requested
  drawing cannot be expressed safely as append-only polylines.

Preserve the existing uncertainty, privacy, study-support, and grading rules.
Quick actions and user messages remain user text.

Configure Gemini's `generationConfig` for JSON output using the structured
output fields supported by the repository's existing `generateContent` REST
endpoint: JSON MIME type plus the canonical schema. Do not rely on prose alone
or an SDK-only schema type. Pin the exact request body in serialization tests.

Extract candidate text defensively, enforce the byte limit, decode JSON once,
and parse typed immutable models. Syntax errors, unsupported versions, and
schema/limit violations must never reach the ink controller. Never expose raw
response JSON, point arrays, response bodies, image bytes, or chat content in
logs or error text.

## Conversation history and status

Separate display text from provider wire content:

- user turns retain their original text;
- model turns display `message` in the assistant bubble;
- a model turn owns its typed optional notation and a local application
  status;
- when replaying model history to the stateless API, serialize the canonical
  response envelope, but never include local application status in it;
- the history records what the model returned, while status records what the
  app did with it.

Use explicit status values such as `none`, `applying`, `applied`,
`notAppliedNotationOff`, `notAppliedStale`, `notAppliedBusy`, and
`notAppliedInvalid`. A notation response gets a small transcript row such as:

```text
AI notation: Numerator label and arrow — Added to note
```

or a concise reason it was not added. Do not present an Add/retry-apply action
for stale or unauthorized output. The user can send a new request with
Notation enabled. Normal network Retry remains for failed HTTP requests and
must not duplicate a user turn or apply a response twice.

## Coordinate mapping and local validation

For the immutable note snapshot with logical width `W` and height `H`, map
each normalized point exactly once:

```text
pageX = x * W
pageY = y * H
```

The result is writing-surface-local logical ink geometry. Do not use PNG pixel
dimensions, raster scale, selected-image crop bounds, screen coordinates,
panel position, current viewport origin, or device pixel ratio.

Before mutation, validate again that:

- notation was enabled for the request and is still enabled;
- the response belongs to the current conversation/request token;
- current document revision exactly equals the captured revision;
- current writing-surface logical size equals the captured size;
- the controller has no active stroke, erase, lasso, or transform gesture;
- all schema and aggregate limits still hold;
- every mapped coordinate, width, rendered half-width, stroke bound, and
  combined notation bound is finite and within both the current writing
  surface and `SelectionConfig.maxCoordinate`.

Do not clamp, translate, scale-to-fit, drop invalid points/strokes, smooth,
resample, close paths, join neighboring strokes, or partially apply a
notation. Any failure rejects the entire notation while retaining the valid
assistant text.

Document revision is monotonically increasing and changes once for every
completed document mutation: finishing a user stroke, an erase gesture that
changed ink, cut, paste, committed transform, and an AI notation commit. Pure
selection changes, lasso previews, transform previews, clipboard changes,
theme changes, and panel state do not increment it. Expose it read-only and
test its notification semantics; do not build a history stack.

## Direct atomic drawing

Add a narrow method such as `addAiNotation` to `InkController`. Do not
synthesize pointer events and do not route generated points through
`ActiveStroke` or the One Euro smoother.

The method accepts only provider-independent, already typed page-local
candidates plus the expected document revision. It still validates revision,
busy state, point data, widths, palette identity, count limits, coordinate
limits, and all-or-nothing behavior defensively. Return a typed result rather
than throwing for expected invalid, stale, or busy input.

On success:

1. build every trace with `Stroke.fromPoints` and a `StrokeStyle` using the
   chosen `InkPalette` entry and logical width;
2. append all new strokes, in response order, above existing ink;
3. replace the stroke collection once;
4. increment document revision once;
5. notify `completedStrokesListenable` exactly once;
6. leave the current tool, pen settings, clipboard, existing selection, and
   AI conversation unchanged.

The resulting strokes use `StrokeSource.derived`, contain exact immutable
model points, have cached paths/bounds, and invent no raw input samples. They
are otherwise normal ink: theme-aware, selectable, transformable, copyable,
cuttable, and erasable.

The whole notation response is one controller-level mutation suitable for a
future history layer. There is currently no undo/redo, so do not imply that
the app can undo the notation. The user can erase it like other ink. Do not
extend `Stroke` with provider/chat objects or make the core ink controller
parse JSON.

## Concurrency, lifecycle, and failure behavior

- Assign every request a monotonically increasing token as today. A stale
  result can produce neither a transcript turn nor ink.
- Capture notation authorization, note snapshot, revision, and surface size
  as one immutable request context.
- If the document or surface changes while the request is in flight, retain
  the assistant text but mark its notation stale and append nothing.
- If Notation is turned off in flight, it takes precedence over all other
  application checks and append nothing.
- A response is applied at most once. Guard both controller and UI paths
  against duplicate futures, rebuilds, taps, and Retry completions.
- Do not queue notation to apply at an unknown later revision. A rejected
  notation requires a new message/request.
- Closing or moving the panel does not cancel an authorized request, but
  turning Notation off does revoke its mutation permission.
- Adding notation must not trigger another network request.
- Network, parse, schema, authorization, staleness, layout, or controller
  failure must leave all existing ink untouched.
- Dispose note images, controllers, notifiers, and owned HTTP resources. Never
  notify after disposal.
- Preserve API-key injection and the production-backend security warning.

## Automated tests

Tests must use fake clients and deterministic image renderers. They must not
call Gemini or require a real key.

### Contract and Gemini client tests

- parse exact null and multi-stroke notation envelopes;
- accept dots, polylines, every palette ID, and inclusive numeric/count
  boundaries;
- reject invalid JSON, Markdown fences, surrounding prose, missing/extra
  fields, wrong types, unsupported versions, blank/long labels,
  unknown inks, wrong coordinate spaces, non-finite/out-of-range values,
  widths outside `1..20`, stroke counts outside `1..96`, per-stroke points
  outside `1..128`, aggregate points over 4096, and oversized responses;
- prove malformed output cannot create a partial notation;
- verify JSON response configuration and the exact closed canonical schema;
- verify mode-specific system instructions;
- with Notation off, verify no whole-note image or note metadata is sent;
- with Notation on, verify selected and whole-note PNG parts are identified,
  focus bounds/aspect metadata is present, and the captured revision stays
  local;
- verify model history is canonical envelope JSON while application status is
  omitted;
- preserve endpoint, header, stateless history, timeout, blocked/empty answer,
  malformed response, and non-sensitive error tests from Prompt 6.

### Whole-note renderer tests

- the full surface dimensions and blank margins are represented;
- differently styled strokes retain exact z-order, widths, palette-resolved
  colors, round caps/joins, and dot behavior;
- selection and all editor chrome are absent;
- light/dark backgrounds are opaque and captured at request time;
- output uses at most 2x scale and neither dimension exceeds 2048 pixels;
- invalid geometry and sizes fail before a large allocation;
- repeated snapshots have equivalent output;
- native images are disposed and bytes are retained only for the request.

### Mapping, revision, and ink-controller tests

- `(0, 0)`, `(0.5, 0.5)`, and `(1, 1)` map exactly through non-square logical
  note sizes;
- mapping is independent of PNG size/scale, device pixel ratio, panel side,
  screen origin, selected crop, theme, and breakpoint;
- rendered half-width outside a surface rejects the entire notation without
  clamping;
- dots and polylines become exact unsmoothed derived strokes;
- one response with several traces appends them in order, replaces once,
  increments revision once, and notifies completed ink once;
- palette identity and logical width survive theme changes;
- successful notation preserves tool, pen settings, clipboard, selection, and
  existing stroke order;
- invalid, stale-revision, busy, duplicate, and partially invalid batches
  change nothing and notify nothing;
- every existing document mutation increments revision exactly once, while
  selection-only/UI changes do not.

### Controller, widget, accessibility, and integration tests

- Notation defaults off and toggling it makes no request;
- the toggle, disclosure, enabled state, keyboard operation, focus, tooltip,
  and semantics are clear and accessible;
- toggle state survives panel close/reopen, side changes, orientation, and
  breakpoint changes but not a new editor session;
- ordinary off-mode replies never mutate ink;
- a valid authorized response draws directly without an Add button or second
  confirmation;
- successful multi-trace notation displays `Added to note` and is selectable
  and erasable afterward;
- turning the mode off in flight keeps the answer, rejects the notation, and
  never revives it after re-enabling;
- note mutation, surface resize, context replacement, or a newer request makes
  old notation stale and non-destructive;
- a provider notation returned for an off-mode request is not applied;
- duplicate completion and Retry cannot apply notation twice;
- compact and inline layouts do not overflow and keep the composer usable;
- representative off/on, drawing-status, stale-status, light/dark, inline,
  and compact golden baselines are added or deliberately updated;
- all existing AI, privacy, selection, transform, clipboard, pen, eraser,
  performance, layout, integration, and golden tests continue to pass.

## Acceptance criteria

- The AI panel exposes a clear Notation mode which is off by default.
- Off-mode messages retain the existing selected-ink-only privacy boundary and
  can never change the note.
- A message sent while Notation is on captures and sends a deterministic image
  of the current note plus the existing selected context.
- Every successful answer uses the fixed version-1 JSON envelope.
- Authorized notation can contain several handwritten-style vector traces in
  normalized whole-note coordinates.
- A current, valid response is appended directly and atomically as ordinary
  Greatnote ink without another confirmation step.
- Turning the mode off, changing the note/surface, replacing context, invalid
  output, or a stale/duplicate response prevents all notation mutation.
- Direct drawing never edits or deletes old strokes and never partially
  applies a batch.
- No key, image, raw response, point array, or chat content is logged or
  written to disk.
- Existing editor responsiveness, ink quality, chat behavior, accessibility,
  and API-key behavior are preserved.
- Formatting, static analysis, unit tests, widget tests, integration tests,
  and existing plus updated golden tests pass.

## Completion report

At the end, report:

- files and dependencies changed;
- the Notation control, authorization lifetime, disclosure, and revocation
  behavior;
- the exact JSON envelope and canonical schema;
- how selected and whole-note visual context are captured and serialized;
- every limit and local validation rule;
- normalized-to-page mapping and document/surface staleness checks;
- how direct multi-trace insertion is atomic and how revision/notification
  counts work;
- conversation wire history versus local application status;
- all tests and golden files added or changed;
- commands run and their results;
- emulator/simulator and physical-device verification separately, without
  inventing results;
- deferred work, especially deleting/replacing existing ink, rich shapes,
  persistence, production backend enforcement, and general undo/redo.
