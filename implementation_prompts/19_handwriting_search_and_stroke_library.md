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
  with normalized confidence `>= 0.90` enter search. This prevents ordinary
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

- A recognition enters the reusable pool only at confidence `>= 0.90`, the
  same threshold used by search.
- Apple Vision's normalized candidate confidence is used directly.
- ML Kit Digital Ink scores are model-specific costs rather than
  probabilities. Android marks only a clearly separated first candidate as
  high confidence; ambiguous results and bitmap-OCR fallbacks are retained as
  recognition metadata but cannot be searched or reused.
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
- Words without an eligible exact-case sample continue to use
  `NotationFont`. A single generated text item may therefore mix learned
  words and built-in glyphs while preserving spaces and line breaks.
- Both immediate and timed AI notation, including notation written on an AI
  sticky note, use the same sample pool.

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
