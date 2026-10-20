# Handwriting Search and Reusable Stroke Library

## Status

Implemented in storage schema 5.

This iteration adds two connected features:

1. ordinary handwritten page and sticky-note ink is recognized on device and
   indexed as searchable text; and
2. high-confidence recognized words keep normalized vector samples that AI
   text notation can reuse in the writer's own hand.

No additional neural network is bundled. Recognition reuses the existing
platform services: Apple Vision on iOS/iPadOS and ML Kit Digital Ink on
Android, with the existing bitmap OCR fallback. Recomposition is ordinary
vector geometry and has negligible model memory cost.

## User-visible behavior

### Searchable handwriting

- Finishing ordinary Pen strokes starts a debounce equal to
  `AiCanvasConfig.recognitionDelay`. Recognition never runs in the pointer
  event or paint path.
- Clear horizontal gaps and new lines split a burst into word groups. Delayed
  marks over existing letters, such as an i-dot or t-cross, remain in the
  current group.
- Page ink and ink inside sticky notes are indexed. Highlighter strokes are
  not treated as handwriting.
- Existing pre-schema-5 ink is lazily backfilled when its page is opened with
  the real platform recognizer.
- Recognition metadata is retained with its source strokes, but only readings
  with normalized confidence `>= 0.75` enter search. This prevents ordinary
  shapes and diagrams from surfacing as text.
- Library search matches note titles or recognized handwriting without
  loading every note file. `NoteEntry.searchText` is refreshed whenever the
  note is saved.
- In an open note, the app bar exposes **Find handwriting** after the note has
  recognized text. Typing a word or phrase shows the match count and page;
  Previous/Next navigate between matching pages. The chosen result is outlined
  and softly highlighted directly over its source strokes, including ink on a
  transformed sticky note.
- A recognized entry remains linked to the strokes that produced it. Erasing
  source ink removes the entry. Page-stroke transforms follow replacement
  strokes, so moving or scaling writing does not lose its search text.

### Reusable stroke library

- A recognition enters the reusable pool only at confidence `>= 0.90`. This is
  deliberately stricter than the `>= 0.75` search threshold so a moderately
  confident word can be found without teaching AI notation the wrong shape.
- Apple Vision's normalized candidate confidence is used directly.
- ML Kit Digital Ink scores are model-specific costs rather than
  probabilities. Android maps a moderate winner gap to the search threshold
  and only a clearly separated first candidate to reusable confidence;
  ambiguous results and bitmap-OCR fallbacks are retained as recognition
  metadata but cannot be searched or reused.
- Each reusable sample stores the original trace boundaries and point order,
  normalized into a unit box, plus its aspect ratio. At most 4096 points are
  copied for one sample.
- The runtime pool retains at most 12 variants for an exact, case-sensitive
  text value. This bounds lookup memory and prevents a very common word from
  dominating the pool.
- AI notation selects a variant randomly every time it writes a matching
  word. It applies only translation and independent x/y scale:

  ```text
  output.x = origin.x + normalized.x * (sampleAspectRatio * requestedHeight)
  output.y = origin.y + normalized.y * requestedHeight
  ```

  Trace topology and order are not averaged, joined, inferred, or regenerated.
  This avoids corrupting legibility when two samples have different pen lifts
  or point counts.
- Note samples are used only when every word of a text item has one;
  otherwise the whole item is written in `NotationFont`, in the writer's
  calibrated style. A text item never switches hands mid-way.
- Both immediate and timed AI notation, including notation written on an AI
  sticky note, use the same sample pool.

### Handwriting calibration

- On the first launch of the device library, a full-screen calibration asks
  the writer to copy one sentence, "goodnotes ain't good, freenotes ain't
  free, so we got both.", onto three ruled lines (one per line of
  `calibrationLines`, short enough for a phone). The screen never scrolls:
  the pad fills the height left and the lines shrink to fit it. Only a
  stylus writes on the pad; a finger or palm leaves no ink and shows "Use
  your pen to write here". The pen's eraser end, its side button, or the
  Eraser button erases whole strokes; Undo steps back through writing,
  erasing, and Clear. What is written is kept as a draft beside the
  profile (`handwriting_profile.json.draft`, in line-height units so it
  survives rotation) until Save or Skip, so leaving or the app closing
  loses nothing. The saved hand lives in the device library's folder,
  which does not depend on the signed-in account. It can be skipped and is
  offered again from the library's Sort menu ("Calibrate handwriting…").
- The text is known, so no recognizer runs. Each stroke belongs to the
  ruled line it sits on, and each line's ink is split into words at clear
  gaps. A line whose word count does not match is rejected with a hint
  (leave more room / keep words together).
- No letters or strokes are stored. Calibration measures a
  `HandwritingStyle`, the traits of the hand, in `NotationFont`'s grid:
  slant (weighted median lean of near-vertical strokes), x-height (from
  "so" and "we" against the ascender words), width against the font, word
  spacing, the g's tail (depth, how far it hooks, whether it loops back
  up), loop roundness (closed o-sized strokes), the tilt of cross-strokes,
  and how far words wander off the line and vary in size. Each word's
  baseline is the median of its strokes' valleys in its lower half, so
  descenders, dots, and t-bars do not move it.
- Two traits are curves rather than numbers, each a degree-10 polynomial
  fitted by least squares with a penalty growing as the fourth power of
  each term's order, so they follow the hand and not its tremor, and held
  to a few swings (`limited`), so they can never ring into a wiggle:
  - `lineProfile` (`StrokeProfile`): how straight lines develop along
    their length — how far they stray from the chord at each point, as a
    share of their length, read along `canonicalLine`. s(1 − s) times a
    Chebyshev series, so a line's ends stay put. Lines are found by
    `straightRuns`, the same detector the style uses on the font.
  - `curveProfile` (`CurveProfile`): how tightly curves bend by the way
    they face — the log of the radius against the font's, as a polynomial
    in the bend's outward normal (cos θ, sin θ), so it goes round without
    a seam and reads the same whichever way the pen went. Every curved
    point counts (`bends`); nothing is cut out of a stroke. Drawing it
    (`withCurves`) scales each curved step and keeps every turn, so curves
    tighten or loosen without new corners.
  Each is measured against the calibration sentence written by the font
  in the hand's other traits (`_writtenUpright`), so what a wider o or a
  looped g already explains is not added twice.
- The measured style is mixed 80 % of the way from the built-in style
  (`calibrationMix`) and clamped to legible ranges, then previewed: the
  writer sees the assistant writing in it and saves or tries again.
- The style is global (`handwriting_profile.json` beside the library, JSON
  `version: 3`) and shared by every note. A file from the letter-by-letter
  calibration, or a version 2 style measured before the line and curve
  profiles, is ignored and calibration is offered once more.
- AI notation, plot labels included, writes in `NotationFont` shaped by the
  style. The result is fitted inside the box the built-in hand would fill
  (`NotationFont.width` × `NotationFont.height`, from a little above the
  origin), which is what the assistant planned for, so a wider or taller
  hand cannot run off the paper and get the whole notation refused.

### Built-in hand

- `NotationFont`'s letters come from EMS Readability (SIL OFL 1.1), a
  single-line font, converted by `tool/build_notation_glyphs.py` into
  `notation_glyphs.dart`. The converter normalizes the font's own metrics
  to the grid (x-height y = 3.8, descenders to y = 13), narrows it a
  little, turns its outlined dots and commas into pen marks, and builds a
  single-storey g from q. Mathematics it lacks (≤ ≥ ≠ ≈ √ π θ Δ ∞ → ← ✓)
  stays hand-drawn.
- `HandwritingStyle.standard` gives it an easy forward slant, a hooked g,
  a slight bow to its lines, and slight per-letter drift and size, derived
  from the text so a note lays out the same every time. Nothing is added
  as sampled noise: each letter's lines take the profile a little more or
  less strongly, smoothly, so no line is drawn with saw teeth (the old
  per-segment sine wobble aliased into them).

## Persistence format

Each stored page may have `recognizedWords`. One entry contains:

- `text`;
- optional normalized `confidence`;
- `strokeIndices`, referring either to page strokes or to the named sticky;
- optional `stickyId`;
- `aspectRatio`; and
- `normalizedStrokes` only when the confidence and point limits allow reuse.

Malformed references, coordinates, confidence values, or aspect ratios are
dropped without preventing the note from opening. A sample read below the
current confidence threshold keeps its recognition metadata but is excluded
from search and discards reusable geometry. Older schemas remain readable.

The normalized copy is intentional. The normal note strokes are still the
source of truth and remain editable; the copy makes the learned handwriting
stable after the source is transformed and lets notation fit it with simple
math. It also avoids retaining raster recognition images, raw native objects,
or a second model in memory.

## Main implementation files

- `lib/features/editor/handwriting/handwriting_indexer.dart`
- `lib/features/editor/handwriting/recognized_handwriting.dart`
- `lib/features/editor/ai/canvas_text_recognizer.dart`
- `lib/features/editor/ai/notation_layout.dart`
- `lib/features/editor/editor_screen.dart`
- `lib/features/editor/page/note_document.dart`
- `lib/features/library/note_content.dart`
- `lib/features/library/library_models.dart`
- `lib/features/library/note_repository.dart`
- `android/app/src/main/kotlin/com/etonia/app/HandwritingRecognizerChannel.kt`

## Validation

Automated coverage verifies:

- spatial word grouping and detailed confidence propagation;
- rejection of low-confidence readings from search and pool admission;
- schema-5 JSON and document round trips with live stroke identity restored;
- library search by handwriting rather than title;
- bounded pools and random selection of intact variants;
- affine reuse by AI notation with no averaging; and
- compatibility with legacy schema-3 notes.

The implementation is also checked with `flutter analyze`, the complete
Flutter test suite, and Android `compileDebugKotlin`.
