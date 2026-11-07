# Study Desk search

How the Study Desk finds the pages a question is about. It used to be words
only (BM25 with fuzzy matching); it is now words and meaning, and it sends
nothing to the model when nothing is relevant.

## Why

A student's digital-systems notes are mostly drawings with a few words. Their
Laplace notes say "system" on every page. A question about "digital systems"
matched the Laplace pages on that one word, and when nothing matched at all a
"fair spread" of arbitrary pages was sent instead, so the answer came out about
Laplace. `study_semantic_search_test.dart` reproduces this and shows it fixed.

## How it works

1. **Chunks** are as before (`StudyChunker`): a page's ink, text and pictures
   grouped by place.
2. **Vectors** (`study_vectors.dart`). Each chunk's words are embedded; a chunk
   a model has to see (a drawing, or ink that reads badly) is also drawn
   (`PageStudyChunkRenderer`) and its picture embedded. The `embed` Edge
   Function does this with `gemini-embedding-2` at 768 dimensions and keeps
   nothing. Vectors are stored on the device in
   `<library>/study_vectors/<noteId>.json`, keyed by what a chunk holds
   (`studyChunkKey`), so editing one page embeds that page only, and a page
   inserted earlier in the note changes nothing.
3. **A question** is embedded with the query prompt. `StudyVectorIndex.signalFor`
   brings the notes up to date and embeds the question, waiting at most four
   seconds; whatever is not done carries on in the background, and the question
   is searched by words if the wait ran out.
4. **Retrieval** (`StudyRetriever.retrieve(..., vectors:)`):
   - three ranked lists: words (BM25), the question against each chunk's words,
     the question against each chunk's picture;
   - merged by reciprocal rank fusion, since the lists' scores are not on one
     scale;
   - a chunk is a candidate if its meaning is near the question's
     (`textFloor`, `imageFloor`), or if its words match and its meaning is not
     far (`textLowFloor`, `imageLowFloor`). A chunk with no vector yet is judged
     by words, so a note not indexed yet behaves as before.
5. **Nothing relevant.** When a question has things to look for and nothing
   matches by words or meaning, no excerpts are sent and the model answers
   without them. The fair spread is kept only for questions with nothing to
   look for ("what is this?") and for overview requests.

## Cost and privacy

- Only notes the user put on the desk are indexed. With none there, questions
  search the whole library by words alone and nothing is sent.
- A picture costs about $0.00012, text about $0.20 per million tokens, charged
  from credits on any plan (never unlimited). At most 60 pictures per note per
  run, so a textbook is indexed over several questions.
- The app stops asking for ten minutes after a refusal (no credit, no plan,
  rate limit) and searches by words.
- Switch: **Add Sources → Search by meaning**, remembered with the desk. Off,
  nothing is sent for search. The privacy policy and `supabase/README.md`
  describe it.

## Work left

1. **Calibrate the floors.** `textFloor` 0.55, `imageFloor` 0.30, `textLowFloor`
   0.35 and `imageLowFloor` 0.15 are starting values, not measurements. Embed a
   few real notes plus questions with known answers, look at the cosines of
   right and wrong chunks, and set them. Too high only means the old behaviour;
   too low lets weakly related pages in.
2. **Caption drawings.** A vision model describing each drawing once ("4-bit
   counter from JK flip-flops") would give BM25 and the text vectors something
   to match, and help the answering model. Not built.
3. **Default scope.** With no sources on the desk, questions search the whole
   library. Asking which notes to use would be safer.
4. **Teaching plan** still drifts if its first retrieval is wrong; it now
   retrieves by meaning too, which helps, but a bad saved plan stays.
5. **Where the vectors live.** Device only, so a second device re-embeds. A
   server store (pgvector with row-level security) was considered and rejected
   for now because it would break the "no note content stored" promise.
