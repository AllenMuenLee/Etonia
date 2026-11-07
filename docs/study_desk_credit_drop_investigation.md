# Study Desk retrieval gate and free-credit investigation

Follow-up: [notes-first teaching with a small source budget](study_desk_notes_first_retrieval.md)
relaxes this initial gate for ordinary introductions and explanations. Such
requests now prefer a brief relevant note check without needing an explicit
“use my notes” phrase. The billing findings below remain historical evidence.

Investigation: November 7, 2026. Production inspection used read-only SQL and
numeric billing metadata. No production prompts, answers, notes, email addresses,
or raw account identifiers were read. No balances, grants or historical charges
were changed. Raw anonymized metadata remains under ignored `build/`.

## What caused 19% to become 2%

The active free grant is **$0.50**, with **$0.013129 remaining (2.6258%)**.
The observed requests from **16:09:22 to 16:15:47 UTC** (11:09–11:15 Toronto)
charged **$0.084985**. Adding those charges back reconstructs a prior balance of
$0.098114, or **19.6228%**. The app rounds its display down, explaining **19% → 2%**.
The percentage measures remaining dollar credit; it is not a count of raw tokens.

| Work in this window | Calls | Input tokens | Output tokens | Charged | Share |
|---|---:|---:|---:|---:|---:|
| Sol generation | 3 | 17,154 | 1,750 | $0.051808 | 61.0% |
| Haiku generation/helpers | 12 | 49,227 | 23,925 | $0.017038 | 20.0% |
| Embeddings | 59 | 81,762 | 0 | $0.016139 | 19.0% |
| **Total** | **74** | **148,143** | **25,675** | **$0.084985** | **100%** |

All observed charges were settled; reservations were zero. The grant had not
expired. This is actual recorded spend, rather than a temporary reservation
or percentage-display arithmetic error.

The three Sol calls cost $0.017326, $0.014982 and $0.019500. At the configured
$2/M input and $10/M output rates, **$0.034308 was input and $0.017500 output**.
The newly itemized Sol call used 6,125 input / 725 output tokens, with no cache
reads or writes reported. Reasoning was 162 of those output tokens, not an
additional charge. A few thousand uncached input tokens on Sol therefore cost
more than many longer responses on Haiku.

The two most recent correlated tutor turns cost:

| Turn | Planner | Answer | Suggestions | Total |
|---|---:|---:|---:|---:|
| 16:13 UTC | $0.002574 | $0.003558 | $0.000229 | $0.006361 |
| 16:15 UTC | $0.000946 | $0.002264 | $0.000185 | $0.003395 |

Together, these six requests cost **$0.009756**, or **1.9512 percentage points**
of this grant. They do not alone explain the full 17-point decline. A chat
session can contain multiple tutor turns; older requests lack task/turn labels,
and embeddings lack shared turn IDs. The ledger cannot prove exact allocation
to the user's two conversations or distinguish the older unlabelled generation
requests from editor requests. The full observed window does reconcile with
the reported percentage change.

## Problems found and changes made

1. **Retrieval ran before the model decided whether it was useful.** Notes were
   searched, embedded, and rendered for the planner, then a lesson could trigger
   another search. The model now plans first, using only bounded note titles/page
   counts, conversation, lesson state, and a compact mistake-topic/error index.
   Each tutor reply gets a fresh decision, including explicit `next` requests.

2. **Mistake records were attached even without a relevance match.** The model
   now selects at most three indexed records for the same problem or a specific
   shared error mechanism. Only those full records are sent, within 5,000 bytes.
   A note retrieval and a mistake retrieval are independent choices. Unselected
   records and their full feedback remain local. Broad topic overlap is insufficient.

3. **Semantic search could embed an entire collection in the background.** A
   timeout stopped waiting but did not cancel provider work, and the per-note
   image allowance was 60. New embeddings now cover a shortlist of at most
   **16 chunks, 12,000 text characters and two visual candidates** per search.
   Existing cached vectors remain available for the wider collection. Partial
   indexing preserves other cached chunks. Overlapping identical query requests
   share one provider call, and overlapping note indexing is serialized/deduplicated.
   Already submitted calls can still finish after timeout, but their work is bounded.
   First-use semantic recall is limited to the shortlist; lexical retrieval still
   considers the source collection, and subsequent searches can build its cache.

4. **Haiku cache hits were priced as ordinary input.** Its configuration omitted
   the cache-read rate, so the fallback charged $0.10/M instead of the published
   $0.01/M for this exact model/rate pair. Known Haiku cache-read excess in the
   itemized portion is about **$0.00019422 before per-call rounding**—a real but
   small contributor, not the cause of the entire drop. Added exact Standard-rate
   defaults for Claude Haiku/Sonnet/Opus 5.5, preserving explicit overrides. See
   [Anthropic's pricing](https://platform.claude.com/docs/en/about-claude/pricing)
   and [Haiku specifications](https://platform.claude.com/docs/en/models/haiku-5-5/overview).

The retrieval decision is
`{"notes":false,"mistakeIndices":[],"query":""}` by default. Notes are retrieved
only for a useful connection while teaching or a requested source/problem/test
review. General questions and conversation-only follow-ups do not automatically
retrieve. A failed/malformed decision defaults to no retrieval. No note indexing,
embedding or source image is needed to obtain the decision. Attaching or opening
notes no longer starts background index preparation.

The previous planner's quality calibration is not reused for this changed
policy. Existing answer qualifications retain their established scope. The new
planner still uses the existing capable route; its small live smoke is not a
general quality certification or a reason to enable additional cheap answer routes.

## Verification and limits

- Tests verify no-retrieval decisions cause zero note reads and embedding calls,
  selected mistakes arrive without notes or unrelated mistake records, a later
  follow-up can turn retrieval off again, and invalid decisions fail closed.
- Concurrency tests verify shared in-flight provider work, bounded cold-search
  inputs, and preservation of existing vectors during partial indexing.
- Twelve synthetic live scenarios passed, including general questions, explicit
  note connections, exact/shared past errors, and completed-test review. The
  experiment cost **$0.005050** through direct provider calls, with no app-ledger
  charges. One fenced JSON response was initially marked invalid by the smoke
  parser; it was re-scored using the existing production fence handling without
  another paid call. No prompt was changed to rescue the result.
- **317 Flutter regression tests and 70 backend tests passed.** A further
  18-test planner run covered the final fallback when only a premium model is
  configured. Targeted Dart static analysis reported no issues. Backend and
  evaluation TypeScript type checks passed.

Caching reduces the price of repeated input, not the amount of output generated;
cache hits are not guaranteed. See [official OpenAI caching documentation](https://developers.openai.com/api/docs/guides/prompt-caching).
Production prompt content is intentionally unavailable, so the precise split of
historical input into notes, instructions and conversation cannot be reconstructed.
These fixes reduce avoidable work; a new production measurement is required to
quantify savings. A larger free grant would increase runway but would not repair
unnecessary retrieval. A future explicit spending mode could further constrain
premium-model use, with its quality tradeoffs separately evaluated.

## Release status

Changes are implemented and tested locally. No app, function or migration was
deployed by this investigation. Rebuild/hot-reload the app for the retrieval and
embedding changes; deploy the updated `ai` function for corrected Claude cache
pricing. The earlier usage-breakdown migration is already present in the live
database inspected here. Existing balances and historical charges are unchanged.

Evidence: [billing snapshot](../tool/study_desk_cost/credit_drop_2026_11_07.json),
[live gate smoke](../tool/study_desk_cost/retrieval_gate_results.json).
