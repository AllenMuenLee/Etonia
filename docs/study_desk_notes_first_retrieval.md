# Notes-first teaching with a small source budget

The previous gate required an explicit connection to notes. That made ordinary
requests such as “introduce flip-flops” too likely to bypass relevant course
material. The revised policy prefers relevant notes while varying how much
evidence it supplies.

| Request | Source behavior |
|---|---|
| Introduce or explain a concept plausibly covered by the active notes | Brief note check; up to two excerpts and approximately 800 estimated text tokens |
| A generic filename makes coverage unclear | Brief check rather than assuming the notes are irrelevant |
| Explain a previous answer or shorten it | Reuse the conversation; no fresh retrieval unless new source detail is requested |
| Detailed source problem, derivation, proof or test review | Existing full retrieval budget and evidence safeguards |
| Clearly unrelated subject, greeting, standalone calculation, or explicit independent answer | Model knowledge without note retrieval |

The model still makes the decision before the app reads note content. Its
availability view contains bounded titles/page counts and the existing compact
mistake index. A brief introduction counts as a focused question; it does not
automatically generate an entire lesson plan.

After the decision, brief retrieval tries the existing local text index first.
A positive readable match uses no query or document embedding calls. Weak local
matches can use the existing bounded hybrid search. The app sends at most two
brief hits, approximately 800 estimated source-text tokens, and at most one
necessary picture. It omits the extra citable SVG payload for this brief path.
Configured lower limits are preserved. Full retrieval remains available for
problems whose answer needs more evidence.

Paragraphs and citation mappings are preserved. If an intact mathematical block
would be entirely lost under the brief budget, assembly expands locally to the
normal budget using the same hits. This expansion creates no extra model call.
Pictures and such mathematical expansions can cost more than the usual brief
text allowance; 800 is not a cap on all billable input tokens.

The answer is instructed to use relevant excerpts as its primary source,
preserving their terminology, notation and course level. General model knowledge
can explain background the excerpt does not cover. Citations apply only to
supported source details. If no excerpts were supplied, the answer cannot claim
to have read notes or searched online.

There is currently **no web-search tool wired into this Study Desk request
path**. Its independent fallback is model knowledge. Actual web search would
require a separate integration and its own cost/need policy. Official OpenAI
documentation describes [hybrid retrieval ranking](https://developers.openai.com/api/docs/guides/retrieval)
and [web-search tools](https://developers.openai.com/api/docs/guides/tools-web-search);
these are distinct from generating an answer from model knowledge.

Source context has a real input-token cost. At this project's configured Sol
input rate of $2/M, 800 uncached input tokens cost $0.0016, before images and
other prompt tokens. Pure model knowledge needs no retrieved source tokens.
The practical goal is a small, useful grounding cost, not a promise that source
grounding costs exactly the same as using no source.

Validation: **338 Flutter regression tests passed**, targeted Dart analysis
reported no issues, and the evaluation TypeScript type check passed. An
18-case live synthetic gate smoke passed all cases, including ordinary
introductions, generic filenames, unrelated notes, independent answers,
conversation-only follow-ups, and full source derivations. The corrected smoke
cost $0.006115 through direct provider calls, without app-ledger charges.
It verifies retrieval decisions, not general tutor-answer quality or production
savings. The initial policy smoke over-retrieved a conversation-only follow-up;
the policy now gives that exception priority. Initial raw results are preserved
in ignored `build/study_desk_cost_audit/notes_first_initial_live.json`.

Evidence: [gate results](../tool/study_desk_cost/notes_first_results.json),
the source-budget and mathematical-preservation tests in
`test/features/library/study_desk/study_retrieval_gate_test.dart`.

These changes are local. Rebuild or hot-reload the app to apply the policy,
retrieval-depth handling and source budgets. This follow-up did not deploy an
app/backend or change user balances.
