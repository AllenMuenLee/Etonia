# Study Desk visual notes and progress

Previously the retrieved note crop was attached directly to the tutor request.
The retrieval planner saw only the small source catalogue, but the final answer
model received the pixels and, where available, citable SVG.

Study Desk now uses this sequence:

1. The existing lightweight planner decides whether notes are needed.
2. Existing RAG selects and crops the relevant note content.
3. For a visual chat answer, a read-only backend route preview first uses the
   actual answer prompt, crop, settings, account state and provider health to
   choose the answering model. It calls no AI provider, reserves no credits and
   records no token usage. If that model is Haiku or Luna, chat receives the
   original crop directly and skips the reader, even when a description is
   cached. The actual answer's allowed models are pinned to that chosen model,
   preventing a retry or outage from forwarding pixels to a larger one. Each
   visual turn checks afresh; text-only turns need no preview. Older backends
   that reject previews retain the separate-reader path during rollout.
4. Otherwise, a dedicated `study.describe` request sends the crop to an enabled
   lightweight vision model (Haiku or Luna), at medium or low effort. Server routing restricts
   this task to these lightweight models, including when the main answer setting
   is High. It respects model switches, capability support and credit access.
5. The larger tutor receives the detailed text description, uncertainties and
   other retrieved text. Its image attachment is the transport placeholder. Source SVG
   is omitted. It retains the original note/page/chunk citation mappings.

The description covers visible expressions, signs, subscripts, units, tables,
labels, directions, connections, layout and worked steps. The reader must preserve
negations and domain restrictions, mark ambiguities, and avoid solving or silently
correcting the note. The tutor is told it has no original image and must preserve
uncertainty. Description failure stops the request; there is no automatic fallback
that sends the source image to a premium model. Essential unreadable details
require a clearer crop.

The same description conversion is used for note-based practice generation and
test-topic suggestions. Completed-test review uses the visual chat decision
above. This change concerns Study Desk source acquisition; editor selection
tools and the separate test-grading operation keep
their own request paths.

Descriptions are cached only in memory, using the crop pixels, panel count and
enabled-model scope as the key. Concurrent identical reads share one call. The
cache holds at most 16 descriptions for 10 minutes and is cleared on memory
release/disposal. Edited pixels invalidate it. Images are not retained in this
cache. Descriptions use panel-relative names; citations are rebound to the current
request rather than reusing stale source identifiers. Malformed results and
provider failures are not cached. Oversized source contexts fail rather than
silently cutting equations.

The progress indicator displays actual application work: the retrieval query,
the note currently being read, the note/page being described, and the sources
used while writing the answer. Progress belongs to its originating chat, so
switching chats does not show another chat's activity. This is observable request
status, not a generated account of private model reasoning. Study Desk currently
has no web-search integration; these search terms describe note retrieval.

## Cost and quality evidence

The larger-model path adds a small initial transcription request and text input
to the tutor in exchange for removing its visual input. The direct lightweight
chat path has no transcription call or added description tokens; its routing
preview adds one backend round trip without AI inference. Repeated crops avoid
the transcription call while cached. The earlier 800-token brief retrieval allowance does not cap
this added description, the full prompt or total billed tokens. Net savings
depend on the description length, image size, selected tutor and cache reuse;
this change does not demonstrate a 50% total-cost reduction.

The synthetic live smoke in
[`visual_description_results.json`](../tool/study_desk_cost/visual_description_results.json)
passed 3/3 checks with Haiku at medium effort: unit prefixes/negation, logarithm
domain restrictions/rejected roots, and two stacked panels. The three direct
provider calls cost $0.001959 at the project's configured rates, without app
credit-ledger charges or learner data. These are clean printed fixtures. The
checks do not establish handwriting accuracy, dense-diagram fidelity, complete
description correctness, tutor-answer quality or production savings. Inspecting
the descriptions also showed some redundant interpretation around the copied
expressions, so the tutor must continue treating them as fallible evidence.

The provider documents image input for
[Haiku](https://platform.claude.com/docs/en/models/haiku-5-5/overview).
Vision descriptions can lose small text or spatial detail; see the documented
[image-input limitations](https://developers.openai.com/api/docs/guides/images-vision).

Validation: 356 Flutter Study Desk/transport regression tests passed. Eight
visual-pipeline tests passed after adding coverage that bypasses an existing
cached description for a lightweight answer. The full backend suite passed
(73 tests); the updated router suite passed (24 tests), including a new check
that retries/outages cannot move direct visual chat to a larger model. Targeted
Dart analysis and backend TypeScript checks passed. The tests cover direct
Haiku/Luna answers, changing the answering model between turns, cached-reader
bypass, cancellation during route selection, reader failures, original citations,
and progress staying with its chat. No additional live provider calls were needed
to validate this routing exception.

## Applying the change

These changes are local. Apply migration
`202611090001_visual_description_usage.sql` before deploying the updated
`ai` function, then rebuild/reload the app. The migration extends the existing
strict, private `ai_settle_usage` task whitelist to include `study.describe`;
it does not change balances or store note text. Planner, description and answer
requests share the chat-turn UUID for content-free cost attribution. Deploying
the function before the migration would prevent description-usage settlement.

Custom single-model clients must provide an explicit lightweight description
client, or use a configured model router; a model hint on an arbitrary
single-model client cannot guarantee lightweight execution.
