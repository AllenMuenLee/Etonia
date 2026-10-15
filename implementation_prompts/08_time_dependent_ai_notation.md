# Implementation Prompt 8: Time-Dependent AI Notation

You are extending the existing AI Notation mode in **Greatnote**, a Flutter
tablet application for Android and iPadOS. The editor already supports
low-latency vector ink, erasing, selection and transforms, a vector clipboard,
a selection-aware Gemini assistant, whole-note visual context, strict
structured notation output, revision-based stale-response protection, and
atomic insertion of AI notation into the normal ink document. Preserve all of
that behavior.

Read the current implementation and tests before changing anything,
especially:

- `implementation_prompts/07_ai_notation_mode.md`
- `lib/features/editor/ai/ai_notation.dart`
- `lib/features/editor/ai/ai_config.dart`
- `lib/features/editor/ai/ai_client.dart`
- `lib/features/editor/ai/ai_assistant_controller.dart`
- `lib/features/editor/ai/gemini_ai_client.dart`
- `lib/features/editor/widgets/ai_assistant_panel.dart`
- `lib/features/editor/editor_screen.dart`
- `lib/features/editor/ink/ink_notation.dart`
- `lib/features/editor/ink/ink_controller.dart`
- `lib/features/editor/ink/ink_canvas.dart`
- `lib/features/editor/ink/ink_painter.dart`
- `lib/features/editor/ink/stroke.dart`
- all AI, ink-controller, editor, accessibility, integration, performance,
  and golden tests under `test/` and `integration_test/`

Extend the existing AI, ink, and painting pipelines. Do not create a second
document model, canvas, chat implementation, or pointer-input simulation.

## Product interpretation

In this iteration, **time-dependent notation** means a timed handwriting
reveal. Every notation point has a time, measured from the start of playback.
At time `T`, Greatnote shows the exact prefix of every trace that exists at
`T`, including linear interpolation through the currently active segment.
Different traces may overlap in time, so the AI can draw in parallel or stage
an explanation.

The animation changes only how newly added notation is presented. Its final
state is the same append-only collection of vector strokes supported today.
Once committed, those strokes remain ordinary Greatnote ink: selectable,
transformable, copyable, cuttable, and erasable.

This is not a general scene graph or video format. Do not add keyframed
movement, morphing, opacity, fades, colors, widths, camera motion, deletion of
existing ink, infinite loops, audio, video, images, text objects, arbitrary
easing, or executable actions. Those require a different document and safety
model.

## Goal

Upgrade AI Notation from an instantaneous drawing to an accessible,
deterministic animation that visibly draws the notation in model-specified
time order, while preserving the existing authorization, privacy, validation,
staleness, and all-or-nothing document guarantees.

When an authorized response is accepted:

1. validate and map the complete timed notation;
2. append its final vector strokes to the document atomically, exactly once;
3. initially suppress those newly appended strokes from the completed-ink
   layer;
4. reveal them on a dedicated animation layer according to their timestamps;
5. expose the complete normal strokes when playback ends or is skipped.

The document commit happens once. Animation ticks are presentation changes,
not document mutations. There must never be a frame in which the completed
strokes flash fully visible before the timed reveal starts.

## Scope

Implement:

- a version-2 structured response contract with an explicit animation
  duration and an integer millisecond timestamp on every notation point;
- strict parsing, schema generation, canonical serialization, and local
  cross-field timing validation;
- immutable provider-independent timed page-local notation models;
- a single atomic ink commit that also establishes the initial hidden
  presentation state before listeners are notified;
- a frame-driven painter that reveals exact partial polylines without
  rebuilding the document or allocating a new full `Path` on every frame;
- deterministic playback controlled by Flutter's frame/ticker system;
- reduced-motion behavior and an accessible `Finish now` action;
- transcript statuses for drawing and completion;
- robust interruption, lifecycle, and concurrent-response behavior;
- automated contract, controller, painter, widget, accessibility,
  integration, performance, and golden tests;
- README updates describing the new contract and playback behavior.

Do not add persistence, background playback, export to GIF/video, arbitrary
scrubbing, user-authored timelines, a new animation dependency, general
undo/redo, or a second confirmation before applying notation.

## Version-2 response contract

Replace the provider response envelope with version 2. A notation-enabled
response may contain this exact shape:

```json
{
  "version": 2,
  "message": "I marked the numerator, then wrote the simplified result.",
  "notation": {
    "label": "Numerator and simplified result",
    "coordinate_space": "note_normalized",
    "duration_ms": 1800,
    "strokes": [
      {
        "ink": "blue",
        "width": 3.0,
        "points": [
          {"x": 0.38, "y": 0.29, "t_ms": 0},
          {"x": 0.34, "y": 0.25, "t_ms": 180},
          {"x": 0.30, "y": 0.23, "t_ms": 360}
        ]
      },
      {
        "ink": "blue",
        "width": 3.0,
        "points": [
          {"x": 0.30, "y": 0.23, "t_ms": 420},
          {"x": 0.32, "y": 0.27, "t_ms": 560}
        ]
      }
    ]
  }
}
```

A response without drawing is still a version-2 envelope:

```json
{
  "version": 2,
  "message": "The selected work is correct.",
  "notation": null
}
```

Keep all version-1 rules that are not explicitly changed below:

- objects are closed and reject missing or extra fields;
- `message`, `label`, `coordinate_space`, palette IDs, widths, coordinates,
  stroke counts, per-stroke point counts, total point counts, response size,
  and authorization behavior retain their existing meanings and limits;
- booleans, numeric strings, `null`, non-finite values, Markdown fences,
  surrounding prose, alternate casing, and top-level arrays are invalid;
- `notation` must be `null` when Notation was off for the request.

The time contract is exact:

- `duration_ms` is a JSON integer from `250` through `12000`, inclusive;
- `t_ms` is a JSON integer from `0` through `duration_ms`, inclusive;
- reject `1.0` where an integer is required even if it has no fractional
  value;
- timestamps within one stroke are strictly increasing;
- timestamps in different strokes are independent and may be equal;
- at least one point across the notation has `t_ms == 0`, so accepted
  playback never begins with an unexplained blank delay;
- the latest timestamp may precede `duration_ms`, but the final hold may be
  no longer than `1000` milliseconds;
- a one-point trace is a dot that becomes visible at its timestamp;
- two or more points form one open polyline revealed over time;
- a multi-point notation must contain at least one timestamp greater than
  zero; reject a purported animation whose entire geometry appears at once;
- time controls visibility only. A trace has one immutable ink and width for
  its entire lifetime.

Add timing limits to the existing `AiNotationConfig`; do not scatter magic
numbers through parser, prompt, controller, and tests. Increase the response
byte/output-token limits only if measured fixtures demonstrate that the
additional integer field requires it. Keep every limit finite.

Define one canonical closed JSON Schema in the AI layer and keep it aligned
with the Dart parser. Express all bounds the provider schema supports, and
enforce strictly increasing timestamps, the global zero timestamp, the final
hold, aggregate point limits, and integer runtime types locally.

Do not accept version 1 from a new provider response and do not silently add
synthetic timing to untrusted output. Conversations are session-local and
unpersisted, so all model turns created after this change can use version 2.
Update fakes and fixtures deliberately rather than maintaining two ambiguous
wire contracts.

## Model instruction and Gemini request

Continue using the existing streaming `generateContent` request, selected
image, notation-only whole-note image, stateless chronological history,
privacy boundary, JSON MIME type, and canonical response schema. Do not add
Gemini tools or function calling.

Update the system instruction so the model understands:

- every answer is a version-2 JSON envelope;
- `t_ms` is absolute time since this notation starts, not a duration from the
  previous point and not wall-clock time;
- timestamps control stroke reveal in ascending order within a trace;
- simultaneous timestamps across different traces are allowed for parallel
  drawing;
- use natural writing speeds and brief pauses to make the explanation easy
  to follow;
- animation is encouraged, but only for moving objects, for what moves or
  changes over time: current or another flow travelling along a path, a
  particle, wave, or body changing position, forces or vectors acting in
  turn, the stages of a mechanism or process, atoms combining, separating,
  or rearranging, a quantity traced along a curve;
- never animate fixed labeling: labels, titles, captions, axes, tick marks,
  legends, worked text and formulas, arrows that only point something out,
  and the figure or diagram the motion happens on are fixed. Fixed items are
  shown whole from the start of the notation (every point at time 0) and
  stay still while the moving items play; when the playback loops they are
  not redrawn. A notation with nothing that moves is static and appears at
  once;
- keep the whole animation concise, normally under four seconds and always
  within the configured maximum;
- every point must still remain safely inside the note after stroke width is
  considered;
- the final frame is append-only ink and cannot move or remove earlier ink;
- return `notation: null` when no useful, safe timed drawing can be made.

When Notation is off, continue to require `notation: null` and do not capture
or send the whole-note image. The presence of timestamps must not weaken any
existing authorization or privacy check.

Pin the updated exact request body, schema, system instruction, selected/note
image placement, metadata, streaming extraction, history serialization, and
safe failure behavior in tests. Streaming still exposes only the readable
`message`; never attempt to play partially received or unvalidated notation.

## Typed models and coordinate mapping

Use immutable typed models. A normalized AI point now carries `x`, `y`, and
`t_ms`. After the complete response passes wire validation, map it once to a
provider-independent page-local timed point containing:

- an `InkVector` in writing-surface logical coordinates; and
- a `Duration` or validated integer millisecond offset.

For a captured surface of logical width `W` and height `H`, preserve the
existing mapping exactly:

```text
pageX = x * W
pageY = y * H
time  = Duration(milliseconds: t_ms)
```

Do not use PNG dimensions, raster scale, device-pixel ratio, selected-image
bounds, panel placement, current screen origin, network timing, response
arrival time, or frame count in this mapping. Do not smooth, resample, clamp,
reorder, merge, or synthesize timestamps or points.

All current response-time checks still happen before mutation: notation
authorization and revocation, request token, captured controller identity,
document revision, logical surface size, idle gesture state, palette identity,
geometry, rendered bounds, count limits, and finite values. One invalid time,
point, trace, or bound rejects the entire notation while preserving the valid
assistant text.

## Atomic commit and presentation state

Extend the existing narrow `InkController` notation API rather than routing
through `ActiveStroke` or pointer events. It must accept fully typed,
provider-independent, already mapped timed traces plus the expected revision
and surface size. It must still validate everything defensively.

On success, in one synchronous operation:

1. build all final immutable `Stroke.fromPoints` instances in response order;
2. install a presentation-only playback record that refers to those exact
   stroke instances and their validated timestamps;
3. append the final strokes to the document above existing ink;
4. replace the stroke collection once;
5. increment `documentRevision` once;
6. notify `completedStrokesListenable` exactly once;
7. return a typed result/handle that distinguishes added-with-playback,
   added-without-motion, stale, busy, and invalid outcomes.

The playback record must be established before the completed-ink notification
so a paint cannot expose the final strokes prematurely. Use identity-safe
references or another design that cannot accidentally hide unrelated strokes
after erasing, cutting, pasting, or transforming. Do not add provider/chat
objects to `Stroke`.

The completed-strokes painter omits only the exact strokes currently owned by
the playback record. A separate animation painter draws their time-dependent
prefix. Existing ink remains on the cached completed layer and must not be
repainted for every animation tick.

Playback progress, starting, pausing because the app is not ticking, skipping,
and completion are presentation state only. They do not increment the
document revision, change the stroke collection, notify completed document
listeners, affect the clipboard or selection, or create undo boundaries.
A small visibility notifier may repaint the completed layer when playback
finishes; do not misreport that as a document mutation.

If reduced motion is active, commit the same final strokes atomically but do
not create a playback record: make them visible immediately and report the
notation as applied. Reduced motion never changes the provider request or wire
contract.

## Deterministic playback and painting

Drive playback from Flutter's ticker/animation system, using elapsed duration
as the source of truth. Do not use one `Timer` per point, depend on an assumed
60 Hz refresh rate, add a third-party animation package, or advance by a fixed
amount per frame.

At elapsed time `T`, paint each trace as follows:

- before its first timestamp, paint nothing;
- at or after a one-point trace's timestamp, paint its normal round dot;
- for a multi-point trace, include every complete vertex whose timestamp is
  at or before `T`;
- when `T` lies strictly between points `A` and `B`, append the point
  `A + (B - A) * ((T - tA) / (tB - tA))` and paint through that interpolated
  point;
- after the final timestamp, paint the exact final stroke;
- use the existing palette resolution, round caps, round joins, logical width,
  dot behavior, z-order, and clipping.

The final animated frame must be pixel-equivalent to normal rendering of the
committed stroke geometry. Avoid rebuilding a full prefix list and full
`Path` for every stroke on every frame. Precompute immutable segment/timing
data and use a cached full path plus an efficient partial-path strategy, or an
equally measured approach. Temporary per-frame work must be bounded by the
configured maximum points and must not grow over the course of playback.

Put the animation in its own clipped `RepaintBoundary` and repaint only that
layer on ordinary ticks. Starting and ending may invalidate completed ink to
switch ownership between the completed and animation layers. The AI panel,
selection preview, app bar, palette, selection chrome, and entire editor must
not rebuild at frame rate.

Golden tests must be able to set an exact elapsed duration. Unit-test the
time-to-visible-geometry calculation separately from the ticker and canvas.

## Interruption and lifecycle behavior

Playback must never make the editor feel locked:

- a pointer down on the writing surface first finishes the current playback
  synchronously, exposing the committed final strokes, and then processes the
  pointer normally; the first tap or stylus sample must not be lost;
- keyboard cut, paste, delete-like document operations, a new AI notation
  commit, and any other mutation path must likewise finish current playback
  before operating on its strokes;
- changing tools, selection-only actions, opening/closing/moving the AI panel,
  or rotating without changing the writing-surface logical size may let
  playback continue;
- if layout replacement makes the relevant controller or surface invalid,
  finish safely without painting against stale geometry;
- turning Notation off after the response has already committed does not
  delete the ink; it finishes the presentation immediately. Turning it off
  before commit retains the existing revocation behavior and appends nothing;
- a second valid AI notation finishes the first animation before committing
  and animating the second, so only one playback owns the overlay at a time;
- app lifecycle or `TickerMode` pauses visual progress without consuming
  elapsed animation time, then resumes consistently;
- disposing the editor, swapping an injected controller, or losing the ticker
  must leave committed strokes normally visible and must never notify a
  disposed object.

Animation completion and skip are idempotent. Duplicate futures, rebuilds,
late frames, or repeated `Finish now` activations cannot append ink twice,
increment revision, or leave strokes hidden.

## Transcript and accessible controls

Keep the existing Notation toggle and privacy disclosure. Do not add another
mode toggle just for animation: a valid version-2 notation animates whenever
motion is allowed.

Add local-only application states sufficient to distinguish:

- no notation;
- drawing/animating;
- applied and fully visible;
- the existing off, revoked, stale, busy, and invalid failures.

While playback is active, show a compact transcript row such as:

```text
AI notation: Numerator and simplified result - Drawing...
```

Provide a nearby `Finish now` button with keyboard focus, a semantic button
role, an explanatory tooltip, and at least a 48-logical-pixel target. It ends
only the presentation and exposes the already committed final strokes. On
natural completion or skip, replace the row with:

```text
AI notation: Numerator and simplified result - Added to note
```

Announce playback start and completion at most once each through a polite live
region. Do not announce every frame or point. With reduced motion, show only
the final applied status and do not briefly expose the drawing status.

The assistant controller must be able to update the exact model turn from
`animating` to `applied` when presentation completes, without changing its
wire text/history, inserting another turn, or applying notation again. A
typed application result with an idempotent completion signal is preferable
to coupling the panel directly to the ink controller. Ignore completion
callbacks after controller disposal or conversation replacement.

Do not claim that animation is still drawing if it has been skipped,
interrupted, reduced, or completed while the panel was closed. Reopening the
panel must show the current final status.

## Concurrency, privacy, and failures

All Prompt 7 guarantees remain in force:

- a request captures notation authorization, note PNG, surface size,
  controller identity, and revision as one immutable context;
- turning Notation off in flight revokes mutation even if it is later turned
  back on;
- a stale response cannot create a transcript turn or any ink;
- a changed document/surface retains the answer but rejects its notation;
- an accepted response commits at most once;
- malformed, oversized, unauthorized, stale, busy, or out-of-bounds output
  changes no ink and starts no ticker;
- animation never triggers a network request;
- note/selection images and response content stay in memory and are never
  logged or written to disk;
- no API key, image bytes, chat text, point arrays, raw response, or animation
  data appears in errors or logs.

The transcript's `animating` and `applied` statuses are local application
state and are never serialized into provider history. Provider history uses
the canonical version-2 response returned by the model.

## Automated tests

Tests must use fake clients, deterministic image renderers, fake/test tickers,
and controlled `WidgetTester.pump` durations. They must not call Gemini,
depend on wall-clock sleeps, or require a real key.

### Contract and Gemini tests

- parse and canonically serialize exact version-2 null and timed-notation
  envelopes;
- accept inclusive duration/timestamp bounds, dots, multiple overlapping
  strokes, every palette ID, and all retained geometry/count boundaries;
- reject version 1, missing/extra timing fields, doubles where integers are
  required, negative or out-of-duration timestamps, equal/decreasing times
  within a stroke, no global zero, excessive final hold, and multi-point
  all-at-zero output;
- retain all Prompt 7 rejection tests for JSON shape, types, geometry, inks,
  widths, counts, aggregate points, labels, coordinate space, and response
  size;
- verify that one invalid timed stroke rejects the complete notation;
- verify the exact closed schema, version, timing bounds, and mode-specific
  instructions;
- verify canonical version-2 model history omits every local playback status;
- verify partial streaming exposes only `message` and never starts playback;
- preserve endpoint, headers, image placement, metadata, timeout, retry,
  blocked/empty response, and non-sensitive error tests.

### Timeline and painter tests

- no geometry is visible before a trace starts;
- a dot appears exactly at its timestamp;
- a segment is linearly interpolated at its start, midpoint, and end;
- completed prefixes and simultaneous strokes paint in response order;
- final animated output matches the normal final stroke rendering;
- in a notation that mixes fixed and moving items, the fixed items are whole
  on every frame, including the first frame after the loop wraps, while the
  moving items are revealed over time; the system instruction tells the
  model to animate only moving objects and never fixed labeling;
- large frame jumps, skipped frames, 60/90/120 Hz schedules, and delayed
  pumps resolve from elapsed time to the same geometry;
- the writing surface clips animation and palette/theme resolution remains
  correct;
- existing completed ink is not repainted on every tick;
- bounded temporary work does not grow frame by frame;
- exact elapsed-time golden states cover start, middle, last point, and
  completed ownership transfer in light and dark themes.

### Ink-controller and revision tests

- one response appends all final strokes in order, increments revision once,
  and emits one completed-document notification;
- the playback record is installed before that notification and prevents a
  full-final-state flash;
- animation ticks and natural/forced completion never change revision or the
  stroke collection and never emit document-change notifications;
- finishing transfers painting ownership without a blank or duplicate frame;
- stale, busy, invalid, unauthorized, partially invalid, and duplicate
  inputs append nothing and start no playback;
- interruption before erase, selection transform, cut, paste, user ink, or a
  second notation exposes the final strokes first and preserves the initiating
  operation;
- exact stroke identity prevents unrelated or replaced strokes from being
  hidden;
- completion and skip are idempotent;
- tool, pen settings, clipboard, selection, existing stroke order, and all
  ordinary ink behavior remain unchanged.

### Controller, widget, accessibility, and integration tests

- Notation still defaults off, toggling sends nothing, and off-mode replies
  cannot animate or mutate ink;
- a valid authorized response transitions once from `Drawing...` to
  `Added to note` while committing only once;
- `Finish now` is keyboard-operable, correctly labelled, has a tooltip and
  48 px target, updates status, and does not duplicate ink;
- reduced motion bypasses playback and never shows the active animation
  status;
- pointer input during playback finishes it and retains the pointer's first
  sample/action;
- closing/reopening or moving the panel preserves accurate playback/status;
- turning Notation off in flight rejects output, while turning it off after
  commit only finishes the reveal;
- rotation, compact/inline layouts, controller replacement, disposal, and
  app lifecycle changes cannot leave committed strokes invisible;
- semantics announce start/completion once and remain quiet per frame;
- representative active, midpoint, completed, reduced-motion, compact,
  light, and dark golden baselines are added or deliberately updated;
- the integration smoke test proves partial timed rendering, natural
  completion, and subsequent selection/erasing of the final ordinary ink;
- all existing AI, privacy, selection, transform, clipboard, pen, eraser,
  layout, performance, integration, and golden tests continue to pass.

### Performance verification

Add a profile-mode timeline that exercises a near-limit animation over normal
existing ink. Report separately:

- animation-layer build/raster frame times;
- whether the completed ink layer repainted during ordinary ticks;
- peak temporary allocation and whether it stays bounded;
- natural completion and forced-finish costs;
- emulator/simulator and physical-device observations.

Do not invent physical-device results. Avoid asserting fragile absolute frame
times in unit tests; use instrumentation and structural repaint tests there.

## Acceptance criteria

- AI Notation responses use one strict version-2 contract with validated
  millisecond timing on every point.
- Authorized notation visibly draws in deterministic time order and supports
  overlapping traces plus linear partial-segment reveal.
- The final notation is committed once, atomically, as ordinary derived ink;
  frames never mutate or duplicate the document.
- No full final stroke flashes before playback and no stroke disappears or
  duplicates when painting ownership transfers at completion.
- Reduced motion and `Finish now` reveal the same final geometry immediately.
- User input can interrupt playback without losing its first event.
- Existing authorization, revocation, staleness, surface, geometry, privacy,
  and all-or-nothing safeguards remain effective.
- Only the dedicated animation layer repaints on ordinary ticks; playback is
  elapsed-time based and refresh-rate independent.
- Transcript state is accurate, accessible, local-only, and never pollutes
  provider history.
- Formatting, static analysis, unit tests, widget tests, integration tests,
  performance instrumentation, and existing plus updated goldens pass.

## Completion report

At the end, report:

- files and dependencies changed;
- the exact version-2 envelope, schema, timing semantics, and migration from
  version 1;
- every retained and new validation limit;
- mapping from normalized timed points to page-local animation data;
- how the atomic commit establishes hidden presentation state without a
  flash;
- how partial paths are calculated and painted efficiently;
- revision and notification counts during commit, frames, skip, and natural
  completion;
- reduced-motion, interruption, lifecycle, and concurrent-response behavior;
- transcript status and accessibility behavior;
- tests, goldens, and performance instrumentation added or changed;
- commands run and their results;
- emulator/simulator and physical-device verification separately, without
  inventing results;
- deferred work, especially replay/scrubbing, looping, arbitrary keyframes,
  moving/deleting old ink, persistence, export, production backend
  enforcement, and general undo/redo.
