# Study Desk: token and cost savings decision report

Research date: November 6, 2026.

**Recommendation: combine verified prompt caching, more efficient response
formats, selective retrieval, and quality-tested model routing.** This is a
better fit for Study Desk than applying a general-purpose lossy compressor to
math and technical notes. Routing offers the strongest route to a 50% cost goal;
caching is the first low-risk supplier-cost experiment; sentence selection is the
best next compression experiment.

No application changes or additional paid model calls were made for this report.
The work consists of current primary-source research, repository inspection, and
local token counts on the previous experiment's synthetic captures.

## Evidence and limits

The [first audit](study_desk_token_cost_audit.md) measured three synthetic Study
Desk answers and all-feature backend billing. It did not establish a production
Study Desk average. The ledger still cannot isolate Study Desk from the editor.
The three answer baselines cost an estimated $0.024920: $0.009790 input and
$0.015130 output, or **39.3% input / 60.7% output**. Their low-effort replays
reported zero reasoning and cache-read tokens. Production reasoning savings
cannot be inferred from those examples.

Evidence in this report is explicitly one of:

- **Measured locally:** token counts from those captures, using `o200k_base` as a
  text-size proxy; no new answer-quality experiment.
- **Published:** vendor pricing/behavior or research findings, linked beside the
  claim. Research benchmark gains are not predictions for Etonia.
- **Illustrative:** arithmetic under stated assumptions, not achieved savings.

### Important accounting finding

Official OpenAI documentation now confirms these short-context Standard rates,
in USD per million tokens:

| Model | Ordinary input | Cache reads | Default cache writes | Output |
| --- | ---: | ---: | ---: | ---: |
| GPT-6.1 Sol | $2.00 | $0.10 | $2.50 | $10.00 |
| GPT-6 Luna | $0.10 | $0.01 | $0.125 | $0.50 |

Sources: [Sol model reference](https://developers.openai.com/api/docs/models/gpt-6.1-sol),
[Luna model reference](https://developers.openai.com/api/docs/models/gpt-6-luna).
These rates exclude other service tiers, long-context pricing, and regional
premiums.

The local `AI_MODEL_CONFIG` lacks cached-input rates. `costOf()` consequently
prices cache reads as ordinary input, while `providerAnswer()` sets OpenAI
`cacheWrites` to zero. The current pricing helper applies a write premium only
to Claude. These are gaps to reconcile against the exact endpoint's usage
metadata and provider invoices. The old audit's dollars remain estimates;
OpenAI cache-write costs were not modeled there. **Fixing the accounting alone
does not reduce the provider bill.** It makes existing discounts and surcharges
visible and lets the router compare real costs.

## Ranked options

The savings column describes the affected component, not an additive forecast
for the whole feature. Effort is a relative implementation estimate, excluding
the shared evaluation work.

| Priority | Method | Savings basis | Main tradeoff | Effort |
| --- | --- | --- | --- | --- |
| 1 | Calibrate existing model routing | Luna is 95% cheaper than Sol at equal uncached input/output counts and these rates | Must establish which tasks remain equally good | Medium |
| 2 | Make prompt caching work and meter it correctly | Sol cache reads are 95% cheaper than ordinary input; writes and misses reduce the net benefit | Prefix length, stability, reuse, endpoint behavior | Small–medium |
| 3 | Efficient answer format and output length | Wrapper removal alone represents 6.2% of the prior sample's estimated cost; shorter equivalent answers could add savings | Parser changes; preserve complete explanations | Medium |
| 4 | Select relevant sentences/blocks before sending sources | Cuts only the source-text portion of input | Missing a condition can invalidate an answer | Medium |
| 5 | Gate reasoning effort by task | Cuts billable reasoning where it is currently excessive | Hard derivations still need adequate reasoning | Small–medium |
| 6 | Reuse plans; generate suggestions only when useful | Saves the actual planner/suggestion calls avoided | Helpers may already be very cheap | Medium |
| 7 | Reuse exact results on device | Avoids generation on valid exact cache hits | Source/lesson/history invalidation is essential | Medium |
| 8 | Structured memory for long conversations | Reduces repeated older history | Summary cost, loss of facts, and cache invalidation | Medium |
| 9 | Reuse extracted text; crop relevant visual content | Cuts repeat visual/extraction work where text suffices | Handwriting, diagrams, and units need verification | Medium |
| 10 | Batch or Flex for eligible background work | Published 50% processing discount for eligible work | Delayed results; does not halve live-chat spending | Medium–large |
| 11 | Compact structured data, optionally TOON | Reduces repetitive data keys/formatting | Limited benefit on small nested lesson plans | Small–medium |
| 12 | Fine-tune/distill a small task model | Potentially shorter prompts and cheaper inference | Training data, maintenance, supported models, volume | Large |
| Defer | LLMLingua / Selective Context / abstractive source compression | Can substantially reduce selected text in research settings | Our LLMLingua trial damaged equations and definitions | Medium–large |

### 1. Route suitable work to the cheaper capable model

This changes **cost per token**, and need not reduce the number of tokens at
all. Luna's ordinary input and output rates are both one twentieth of Sol's.
Holding tokens fixed, moving a qualifying request saves 95% of that request's
uncached token cost. Actual results also depend on output length, reasoning,
caching, and retries.

Etonia already has the server router, capability thresholds, escalation, model
restrictions, and an eval runner. However, its capability scores and thinking
multipliers are placeholders. Calibrating that existing machinery is more
promising than adding another routing framework. Do not route purely by question
length, or assume that a plausible answer is correct. Current escalation catches
format/refusal/citation failures; it does not prove mathematical correctness.

Use cheaper routes for definitions and familiar bounded tasks where evaluations
support them. Preserve stronger routes for derivations, unfamiliar notation,
ambiguous handwriting, difficult diagrams, and grading. An expensive verifier
on every answer can erase savings, so include verification and escalation in the
cost comparison. The [RouteLLM paper](https://arxiv.org/abs/2406.18665) supports
evaluating cost/quality routing, but its reported gains are not Etonia results.

**Verdict:** strongest candidate for reaching 50% overall generation savings.

### 2. Cache stable prefixes, including their write costs

OpenAI's current documentation requires an eligible repeated prefix of at least
1,024 visible input tokens on these model generations. Default writes cost
1.25 times ordinary input; Sol reads cost 0.05 times ordinary input. Cache
eligibility and retained-prefix reuse must be measured, not inferred merely
from using the same model. See the [official prompt-caching guide](https://developers.openai.com/api/docs/guides/prompt-caching).

Our captured answer instruction plus the backend suffix is **1,106 proxy
tokens**, identical across the three answer fixtures. Planner instructions are
685 and suggestions 239. The answer prefix is a plausible caching target, but
the earlier six live replays reported zero cache reads. A warm/cold pilot is
necessary. Keep task-specific dynamic content after stable instructions and
use caching controls actually supported by the current Chat Completions path;
do not copy Responses-only parameters into it.

Illustration: ten requests reusing one prefix, with one 1.25-times write and
nine 0.05-times reads, pay an average **17% of that prefix's ordinary cost**.
That is an 83% prefix saving, not an 83% whole-request saving. For the measured
1,106-token prefix at Sol rates, the arithmetic saves about $0.001836 per answer,
approximately 22.1% of the old three-answer average. This assumes all prefix
tokens are eligible, one write, nine full hits, unchanged output, and no other
cache writes. It is not a forecast.

Provider differences matter. Claude currently allows 512-token cached prefixes
on the configured 5.5 family; the app already marks its fixed system block with
`cache_control`. Google lists a 4,096-token minimum for Argon and says explicit
caching is unsupported for Argon onward. Do not assume short instructions cache
equally across providers. Sources: [Claude caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching),
[Google caching](https://ai.google.dev/gemini-api/docs/caching), whose current
Markdown documentation was also retrieved directly when the browser renderer
could not display it.

**Verdict:** best initial low-risk experiment; cache hits preserve source text.

### 3. Remove avoidable output overhead and test concise equivalents

Study Desk currently requests an outer SVG containing a title and an escaped
Markdown message, including for planning and suggestion JSON. That envelope is
useful to the shared transport but need not be the only supported response type.
A chat-specific Markdown/JSON transport could leave actual diagrams inside the
answer while removing the surrounding SVG container.

I parsed the existing synthetic baseline SVGs, extracted the message, decoded
XML escaping, and counted tokens without changing the message text:

| Fixture | Outer SVG, proxy tokens | Message only | Removed |
| --- | ---: | ---: | ---: |
| Digital systems | 513 | 467 | 46 |
| Logarithms | 395 | 341 | 54 |
| Chinese | 596 | 541 | 55 |
| Total | 1,504 | 1,349 | **155** |

At Sol's output rate, 155 tokens represent $0.001550, or **6.2%** of the previous
estimated total. This is a mechanical payload comparison, not a measured new
generation result. A replacement JSON envelope would retain some overhead.
Provider output counts included three more tokens per answer than this proxy.

There is a cache interaction: removing only the SVG instructions reduces the
sample fixed instruction from 1,106 to about **1,009 proxy tokens**, near or
below the 1,024-token cache threshold. The net change needs a warm-cache test.
Do not pad prompts with meaningless text to claim savings.

Beyond formatting, test direct answers and one useful example where sufficient,
while preserving requested proofs, units, domain restrictions, and lesson checks.
The current prompt already asks for direct complete explanations, so additional
shortening is an evaluation hypothesis. At the sample's 60.7% output-cost share,
a genuine 25% output reduction would save **15.2% overall**, at fixed input.

**Verdict:** good low-loss engineering work; evaluate jointly with caching.

### 4. Prefer query-aware sentence selection to deleting individual tokens

Select the smallest useful set of intact source sentences, equations, tables,
and neighboring conditions. Remove irrelevant or duplicate material before it
reaches either planner or answer model. Keep original line/page mappings and
enough surrounding context for pronouns and conditions to make sense.

For the logarithm fixture, preserve the complete original equation, its domain
conditions, candidate roots, and the rejection explanation. An unrelated current
and resistance example can be omitted. This preserves mathematical units of
meaning better than deleting individual words or operators. It is still lossy:
multi-step proofs and questions spanning several passages need wider evidence.

The [RECOMP paper](https://arxiv.org/abs/2310.04408) distinguishes extractive
sentence selection from abstractive summaries. Etonia can first test a simpler
selector using its existing lexical/vector retrieval, deduplication, and bounded
context, without deploying RECOMP's trained model. Reranking can help choose
fewer relevant passages, but adds its own cost. [Anthropic's retrieval study](https://www.anthropic.com/research/contextual-retrieval)
is evidence for evaluating retrieval quality, not a promise of cheaper answers.

The repository already limits retrieval to five chunks and approximately 3,000
text tokens, uses lexical/vector fusion, avoids irrelevant sources, and limits
pictures. Count only incremental savings beyond those existing measures.

**Verdict:** best next compression method to benchmark on actual Study Desk tasks.

### 5. Budget reasoning without truncating useful explanations

Use the existing effort control according to measured task difficulty. Provider
reasoning is billable output; an output ceiling can include reasoning as well as
visible text. A ceiling that is too low can produce an incomplete answer after
incurring cost. See [OpenAI reasoning documentation](https://developers.openai.com/api/docs/guides/reasoning).

In the repository, router `outputTokens` and `thinkingFactor` are **estimates for
selection**, while `outputBudget()` usually permits the configured ceiling up to
16,384 tokens. Lowering that ceiling alone does not save anything when answers
already stop below it. Test suitable effort and concise response instructions
first; use ceilings to control pathological runs while leaving headroom.

The [token-budget-aware reasoning paper](https://arxiv.org/abs/2412.18547) motivates
adaptive budgets, but hidden reasoning in a hosted API is not controlled simply
by telling it to think in a fixed number of words. Also, lower effort can cause
the router to choose a different model, so compare the resulting pair's cost.

**Verdict:** potentially valuable, but the earlier low-effort examples provide
no measured hidden-reasoning savings.

### 6. Avoid unnecessary helper calls, without moving cheap work to Sol

Study Desk can invoke a planner before answering, retrieve again for a lesson
step, and request follow-up suggestions afterward. The planner currently sees
history and retrieved material, including pictures when present.

Candidates to test:

- Reuse an unchanged lesson plan; send a small state transition when sufficient.
- Give the planner a relevant outline or bounded samples instead of every answer
  passage, while retaining evidence needed to classify the request correctly.
- Generate suggestions on explicit refresh or after engagement, rather than for
  every completed answer. Debounce duplicate refreshes and avoid stale work
  before submission; discarding a result after generation does not refund it.
- Keep planning/suggestions on suitably capable inexpensive models.

Combining answer and suggestions into one expensive call is **not automatically
cheaper**. For illustration, 150 suggestion output tokens cost $0.000075 on Luna
versus $0.001500 on Sol, before input or reasoning. Eliminating a small Luna
request by adding those tokens to Sol can increase cost. Model both cases.

**Verdict:** useful workflow cleanup; measure its real spend share first.

### 7. Reuse exact local results and compact older conversation state

An exact result cache can avoid an entire repeat call. Prefer device-local reuse
consistent with the current architecture, keyed by source version, question,
relevant history/lesson state, prompt version, and model settings. Reuse saved
practice sets rather than regenerating them accidentally. A semantic similarity
cache is riskier: a changed sign, number, or lesson step can require a different
answer. Do not introduce shared server-side response storage as an incidental
optimization; the current backend intentionally stores no response content.

For long sessions, store structured state such as the active lesson step,
established facts, unresolved questions, and verbatim mistakes/equations that
must survive. Keep recent turns and retrieve older evidence when needed. The
backend already compacts and caps history at twelve turns / 24 KB. Additional
summary calls must amortize their cost and can invalidate a reusable cache
prefix. Summarize conversational state separately from original source evidence.

**Verdict:** exact reuse first; state compaction when long histories measurably
dominate cost.

### 8. Optimize visual and embedding work selectively

Reuse PDF-native text, existing handwriting recognition, and content-keyed local
vectors. Index changes incrementally; do not add a blanket repeated embedding
pass. That caching already exists in `study_vectors.dart`. A caption or OCR pass
can be amortized over many questions, but costs extra and can misread notation.
Retain the original crop when the question depends on a diagram or unclear ink.

Crop irrelevant whitespace and choose image fidelity from measured readability
and token counts. Reducing PNG file size alone does not imply fewer image tokens.
Current OpenAI docs also warn that `low` detail does not always use fewer tokens
than `high`; it depends on model preprocessing. See [images and vision](https://developers.openai.com/api/docs/guides/images-vision).

The audit's 69 embedding requests cost $0.017775, approximately 9.8% of that
all-feature day's combined recorded AI cost. That includes initial indexing and
does not establish a recurring cost for every question.

**Verdict:** useful on visual-heavy sessions; do not trade away legibility for an
assumed discount.

### 9. Use discounted processing where waiting is acceptable

OpenAI Batch offers a published 50% discount with a 24-hour completion window;
Claude also prices batch usage at half its standard rates. Good candidates are
offline evaluations and explicitly deferred practice-pack generation. Batch
requires a durable job/file workflow outside the current transient request path.
It is not an appropriate replacement for a live tutor answer. Sources:
[OpenAI Batch](https://developers.openai.com/api/docs/guides/batch),
[Claude Batches](https://platform.claude.com/docs/en/build-with-claude/batch-processing).

Flex uses discounted pricing with slower and less predictable availability on
supported models. It may fit non-urgent work if the application can handle waits
and capacity errors. A fallback to Standard pays Standard prices for that work.
See [OpenAI Flex](https://developers.openai.com/api/docs/guides/flex-processing).

If background work represents 20% of spending, halving its price saves 10% of
the whole bill. Moving work into a queue is not sufficient; it must actually
use the provider's discounted processing tier.

**Verdict:** clearest published 50% discount on eligible tasks, with a substantial
latency/workflow tradeoff. It cannot alone halve interactive spending.

### 10. Compact data formats and specialized models: narrower opportunities

Use compact JSON for structured input already represented as JSON. TOON can
avoid repeated keys for uniform arrays, but its own documentation says compact
JSON can win for deeply nested or nonuniform data. Small lesson plans are not
large uniform tables; benchmark the real payload and decoder reliability before
adding a format. Preserve equations and source identifiers exactly. See the
[TOON specification/project](https://github.com/toon-format/toon).

Fine-tuning or distillation can move stable behavior into a smaller model and
reduce lengthy instructions. It has training and maintenance costs and requires
an eligible base model; Luna's current model page lists fine-tuning as unsupported.
It does not replace access to the user's changing notes. See [OpenAI model
optimization](https://developers.openai.com/api/docs/guides/model-optimization).
At the audit window's $2.71 of recorded all-feature generation cost, an always-on
compression service could easily cost more than it saves; future production
volume, rather than this small sample alone, should determine that investment.

**Verdict:** defer specialized training/serving until inexpensive existing
mechanisms and real usage data justify it.

## Compression approaches I would not prioritize

| Approach | Assessment for Study Desk |
| --- | --- |
| LLMLingua-2 word/token deletion | Previously tested; lost technical meaning. Further use needs protected mathematical blocks and stronger evals. |
| Selective Context | Another information-based filtering method; its research does not establish preserved math or citation faithfulness here. |
| Abstractive source summaries | Can be useful for outlines, but can alter conditions or introduce unsupported claims; avoid replacing cited evidence with them. |
| Gzip, ZIP, or Base64 of the prompt | Reduces transport bytes, not automatically model tokens; a normal text API does not transparently decompress it for reasoning. |
| Soft-prompt vectors / KV-cache quantization / inference token pruning | Mostly require control over model internals; no supported route in Etonia's current text/image provider interfaces. Provider prompt caching is a different, available mechanism. |
| Shortening prompts blindly | May remove essential instructions or lose cache eligibility; optimize measured net cost. |

[Selective Context's original paper](https://arxiv.org/abs/2304.12102) and
[RECOMP](https://arxiv.org/abs/2310.04408) are useful research references. The
interface-fit and risk judgments above are this report's engineering assessment.

## A concrete path to 50%, with explicit assumptions

The following is **illustrative arithmetic**, using the previous three-answer
input/output cost mix and uncached rates. It excludes helpers, search, cache
writes, hosting, and retries. It does not assume the changes have passed quality
evaluation, or that the entire application currently uses Sol.

| Scenario | Assumptions | Cost per 1,000 comparable answers | Reduction |
| --- | --- | ---: | ---: |
| Baseline | The previous Sol answer sample | $8.31 | — |
| Token efficiency | 20% fewer input tokens and 25% fewer output tokens | $6.39 | 23.0% |
| Balanced package | Above, then 40% of remaining spend shifted to Luna at 5% of Sol's rates, with the same tokens | $3.96 | **52.3%** |

Calculation:

`new cost / old cost = (0.392857 × 0.80 + 0.607143 × 0.75) × (0.60 + 0.40 × 0.05)`

The 40% is a **share of spend**, not 40% of question count. Cheap-model output,
reasoning, and fallback may differ. Under these exact assumptions, about 36.9%
of remaining spend needs a successful cheaper route to reach 50%. If only 20%
can move, the goal will not be reached by this package. Caching is deliberately
not added to this example because its overlap with prompt shortening depends
on prefix eligibility and reuse.

Define the target as **total cost per correct, complete tutor turn**, including
planning, suggestions, retrieval, indexing amortization, and all attempts.
For example, if unchanged search/indexing is 10% of total cost, generation must
fall by 55.6% to halve the whole bill. A 50% reduction in a selected token
component is a different target.

## Which package should we choose?

| Package | Scope | Why choose it? | Limitation |
| --- | --- | --- | --- |
| A: Preserve model behavior | Metering + cache pilot + efficient transport + duplicate-call prevention | Lowest answer-quality risk | No defensible 50% promise |
| **B: Balanced — recommended** | A + quality-tested cheap routing + extractive source selection + task-specific effort/output policies | Best fit for the 50% goal using existing architecture | Requires task-level evals; not every question can use the cheaper model |
| C: Deep compression/training | Learned compressors, abstractive summaries, specialized trained models, new serving infrastructure | Potentially useful at high sustained volume | More operational cost and risk than current evidence supports |

**My choice is B, staged through A first.** Build trustworthy cost attribution and
test cache behavior first, then compare routing/selection/output policies on the
same cases. Keep the exact source evidence and stronger routes available for
hard questions. This recommendation is a proposal; none of these behavior
changes has been enabled.

Suggested evaluation: at least 120 representative scenarios covering focused
questions, derivations, diagrams/handwriting, multilingual material, and multi-turn
lesson continuity. Repeat stochastic comparisons, separate cold/warm caches,
and report uncertainty. Track mathematical correctness, whether citations
actually support claims, source coverage, lesson continuity, complete parseable
responses, latency, and **cost per successful turn**. Use a held-out set; do not
calibrate and claim quality on the same examples. A proposed gate is no added
critical math/citation failures and no meaningful task-quality regression; the
acceptable margin must be chosen before rollout, and small samples may not be
enough to establish it.

Record numeric per-pass task/model/effort, input/cache-read/cache-write tokens,
billable output and reasoning breakdown where available, pricing version,
retries, and an opaque parent-turn identifier. Avoid counting reasoning twice
when it is already included in provider output totals. Do not log note text,
questions, responses, or filenames to collect these measurements.

## Repository locations and reproducible numbers

- Router and placeholder estimates: `supabase/functions/_shared/ai_router.ts`.
- Pricing, provider request/usage parsing, and output ceiling:
  `supabase/functions/_shared/ai_policy.ts`.
- Current usage log: `supabase/functions/ai/index.ts`.
- Planner, answer, suggestions, and lesson context:
  `lib/features/library/study_desk/study_desk_controller.dart`.
- Prompt contracts: `lib/features/editor/ai/ai_config.dart`.
- Existing history compaction: `lib/features/editor/ai/backend_ai_client.dart`.
- Retrieval and excerpt assembly:
  `lib/features/library/study_desk/study_rag_index.dart`.
- Existing device-side embedding reuse:
  `lib/features/library/study_desk/study_vectors.dart`.
- Content-free local counts and worked arithmetic:
  `tool/study_desk_cost/research_results_2026-11-06.json`.

Only this report and its local numerical result snapshot were added for this
research. No new infrastructure, application dependencies, or paid evaluations
were introduced.
