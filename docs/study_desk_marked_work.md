# Finding marked work: "review my past mistakes"

A mistake on paper is a mark (a cross, a circled step, a correction in red pen),
not a written word. Retrieval used to index only words, plus a few diagram
shape tags, so a request about marked work matched nothing and fell back to a
fair sample of pages.

Two changes let the existing text and picture search find it.

## 1. Marks are indexed

`StudyChunker` now looks for marks while chunking a page and adds words for them
to the chunk's `tags`, which BM25 already searches:

| Detected | Tags added |
|---|---|
| Tick (short stroke down, longer stroke up-right) | `marked tick checkmark correct` |
| Cross (two diagonal strokes meeting near their middles) | `marked cross wrong incorrect mistake` |
| Loop round a word or typed line | `marked circled circle` |
| Level line through the middle of a word | `marked strikethrough crossed-out corrected correction` |
| Three or more strokes in a pen other than the page's usual one | `annotated <colour>-ink <colour>` |

The synonyms are deliberate: BM25 matches only the words it is given, and a
student asks for "mistakes", not "cross".

The detector favours precision:

- Ink the recognizer read as handwriting is not a mark, unless it is in another
  pen.
- A tick or cross in the page's own pen counts only with 8px of clear paper
  round it, since a letter looks the same.
- "Another pen" needs at least six strokes on the page to establish the usual one,
  and it compares colour families (`red`, `blue`, ...), not exact shades.
- Known misses: an X written over a word in the page's own pen, and a
  strike-through the recognizer merged into the word. A page written entirely
  in the correction colour has no contrast to detect.

A chunk with marks now `needsPicture`. That gives it a picture vector, so the
image search can see it, and it reaches the tutor through the existing
description stage, whose prompt now reports marks, their ink colour and what each
is attached to. Chunk cache version 4 → 5 re-chunks existing notes on first read.

## 2. The planner describes how the page looks

The planner's `retrieval` object has an optional `visualQuery`: one sentence
(≤300 characters) describing the sought page's appearance, for example
"handwritten working with red pen crosses, ticks, circled or struck-through
steps and written corrections beside them". It is empty unless appearance
matters, and ignored when `notes` is false. A malformed value is dropped, not the
plan, and older replies without it parse as before.

It is embedded with the same query embedder and matched against picture vectors
only, as a fourth ranked list in the reciprocal-rank fusion (after words, the
question against text, the question against pictures). Only the closest
`2 × limit` pictures take part, since a description of a look fits many pages a
little. It also counts for the "meaning is not far" check, so a page whose words
match is kept if its picture fits the description.

When a `visualQuery` is present the search always uses the embedding path, even
for a brief request with a good local keyword match, and first-use indexing
embeds up to 6 pictures instead of 2, marked chunks first. Embedding that
sentence is one extra `embed` call per such turn, cached by text.

The planner prompt also separates two meanings of "mistakes": marks in the
notes (set `notes` true, depth full, mark vocabulary in `query`, and a
`visualQuery`) and the graded-practice index (`mistakeIndices`).

## Limits

- Not measured against real handwritten pages. Stroke thresholds (tick and cross
  size 14-120 logical px, 8px clearance) are reasoned from the existing diagram
  heuristics and unit-tested on synthetic strokes only.
- Scanned pages with marks printed into the image are not stroke data. They
  already had picture vectors; only the `visualQuery` helps there.
- Cosine floors for the look list reuse `imageFloor` (0.30). Whether that suits
  descriptive queries against the production embedding model is untested.
- The planner prompt is not covered by the live retrieval-gate evaluation yet.
  Add a marked-work fixture to `supabase/evals/study_retrieval_gate.ts` before
  relying on the model to emit `visualQuery` consistently.
- The planner prompt's three older negative directives ("do not assume…",
  "do not repeat…", "Do not invent…") were reworded positively, with the same
  meaning, so the repository's prompt-style test passes. The new marked-work
  text follows the same rule.

Tests: `test/features/library/study_desk/study_marks_test.dart`.
