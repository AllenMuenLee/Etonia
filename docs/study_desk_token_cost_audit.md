# Study Desk token cost and LLMLingua experiment

Measured November 6, 2026. **LLMLingua did not achieve a 50% cost reduction.**
In three paired live answer replays it reduced input tokens by 10.8%, but output
grew by 11.5%, increasing the estimated combined cost by 2.8%. This is a small
experiment, not an estimate of average production savings.

## What was measured

1. Read-only queries of the linked Supabase project's numeric billing records.
2. Three synthetic notes passed through the current `StudyDeskController` and
   `BackendAiClient`, capturing the real planner, answer, and suggestion prompts.
   No real notes or conversations were read or transmitted for the experiment.
3. Local LLMLingua-2 compression of retrieved text at retention targets of 0.5
   and 0.25. System instructions, source headers, and questions stayed intact.
   Digits, common operators, and selected negations were forced to survive.
4. Six paid provider requests: baseline and 0.5-target compressed **answers**
   for each fixture, using `gpt-6.1-sol`, low effort, the production system
   instruction and transport, and a 4,096 completion-token ceiling. All completed
   with `finish_reason: stop`; the provider reported zero reasoning/cache tokens.
   These replays bypassed the automatic router and app billing. Planning,
   suggestions, embeddings, and compression hosting are excluded from their cost.

All USD figures use the application's configured rates. They are not a verified
provider invoice or independently verified current vendor list prices.

## Current configured rates

From local `AI_MODEL_CONFIG`; USD per million tokens:

| Aliases | Input | Output, including billable reasoning |
| --- | ---: | ---: |
| Haiku / Luna | $0.10 | $0.50 |
| Sonnet / Sol | $2.00 | $10.00 |
| Opus / Argon | $4.00 | $20.00 |
| Astra | $10.00 | $50.00 |

For uncached, single-model usage: `cost = (input × input_rate + output × output_rate) / 1,000,000`.
The server also handles cached reads, Claude cache writes, integer micro-dollar
rounding, and separate model costs for requests with multiple passes.

## Live billing baseline and its attribution limit

The database does **not** store task/feature, effort, cached-token counts, or the
separate input/output dollar charges. Its model label can also represent a
request with multiple passes. No usable `ai_route` task logs were returned by
the available log queries. Consequently these totals cannot be labeled
"Study Desk only," and an exact historical input/output dollar split cannot be
reconstructed from the ledger alone.

The latest UTC day's settled generation records, November 6:

| Model | Requests | Input tokens | Output tokens | Nominal input cost | Nominal output cost | Recorded total |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Haiku | 2 | 5,618 | 7,752 | $0.000562 | $0.003876 | $0.004467 |
| Luna | 11 | 30,535 | 3,161 | $0.003054 | $0.001581 | $0.004641 |
| Sol | 13 | 38,459 | 7,720 | $0.076918 | $0.077200 | $0.154118 |
| **Total** | **26** | **74,612** | **18,633** | **$0.080533** | **$0.082657** | **$0.163226** |

Nominal splits apply the current local rates to recorded tokens. The $0.000036
residual is not attributed: cache writes, rounding, and configuration differences
are not recorded separately. Sol's nominal split reconciles exactly for this day.
These are all-feature totals, covering activity through approximately 21:48 UTC.

Semantic search separately recorded 69 embedding requests, 86,749 input tokens,
and $0.017775, bringing the day's combined recorded cost to **$0.181001**.
Embedding cost includes picture charges and is not simply a text-token subtotal.

Across October 18–November 6, the ledger contains 203 settled generation
requests, 2,700,557 input tokens, 566,939 output tokens, and $2.713038 of recorded
cost. Do not apply today's rates retrospectively to this larger window: model
configuration and request composition may have changed. Released and pending
requests are excluded; unrecorded provider charges cannot be inferred.

## Measured Study Desk answer costs

These are actual provider-reported token counts on **synthetic** Study Desk
answer requests, with costs calculated at Sol's configured $2/$10 rates:

| Fixture | Input before → after | Output before → after | Baseline cost | Compressed cost | Total cost change |
| --- | ---: | ---: | ---: | ---: | ---: |
| Digital systems prose | 1,881 → 1,523 | 516 → 482 | $0.008922 | $0.007866 | −11.8% |
| Logarithms and domain restrictions | 1,592 → 1,426 | 398 → 452 | $0.007164 | $0.007372 | +2.9% |
| Chinese technical explanation | 1,422 → 1,419 | 599 → 753 | $0.008834 | $0.010368 | +17.4% |
| **Total** | **4,895 → 4,368** | **1,513 → 1,687** | **$0.024920** | **$0.025606** | **+2.8%** |

Baseline input cost was **$0.009790** and output cost **$0.015130**. Compressed
input cost was **$0.008736** and output cost **$0.016870**. Estimated total spend
for all six replays was $0.050526. Output is stochastic; one pair per fixture
cannot establish that compression consistently increases or decreases output.

The local text-size experiment explains why compressing excerpts is not the same
as compressing the entire request. Counts below use `o200k_base` as a proxy,
excluding images and message framing; live counts above supersede it for replays.

| Fixture | Excerpt tokens, 0.5 target | Whole answer text reduction | Whole answer text reduction, 0.25 target |
| --- | ---: | ---: | ---: |
| Digital systems | 704 → 346 | 19.1% | 28.3% |
| Logarithms | 413 → 247 | 10.5% | 14.6% |
| Chinese | 243 → 239 | 0.2% | 8.6% |

For the same excerpts, planner input fell 24.7%, 14.3%, and 0.3% at the 0.5
target. Suggestions were not compressed. The compressed Chinese text inserted
spaces between characters, so deleting characters produced little token saving.
The retention setting is not a guarantee about a different model's tokenizer.

Warm local compression took roughly 42–106 ms on this machine's CUDA GPU;
the first measured compression took 1.33 s. Model construction took 4.90 s,
excluding Python imports and initial download. These are desktop timings, not
mobile or deployed service timings.

## Quality findings

Compression discarded important source content despite forced digits/operators:

- The English definition of hold time became **"Hold time must."**
- `log_2(x - 1) + log_2(x - 3) = 3` became fragments including
  `log _ 2 - 1 + 2 - 3 = 3`, losing variables and parentheses.
- The Chinese explanation lost the explicit before/after definitions of setup
  and hold time.

The answer model recovered familiar facts in these examples, and both logarithm
answers gave the correct domain and solution. That does not establish faithful
grounding in arbitrary notes. A model can reconstruct a familiar exercise while
silently misreading an unfamiliar one. Citation headers surviving is insufficient
when the evidence inside their chunks has changed.

## Can LLMLingua halve the cost?

At fixed output, model, and caching, let `f` be the fraction of cost spent on
compressible text and `r` its retained fraction. Gross saving is `f × (1 − r)`;
net saving must also subtract compressor hosting and any extra retries/output.

For the latest all-feature generation sample, the nominal **entire input** share
is only 49.3%. Even the unrealistic assumption of halving *every input token*,
including instructions and pictures, saves about **24.7%** of generation cost,
or **22.2%** with the observed embedding charges left unchanged. Halving just
retrieved prose saves less. This is an illustrative bound based on that sample,
not a Study Desk production savings estimate.

LLMLingua compresses text prompts; it does not directly reduce generated answers,
reasoning output, or attached PNGs. Its upstream benchmarks are not evidence of
equal savings or preserved accuracy on Etonia's math and handwritten materials.
See the [Microsoft repository](https://github.com/microsoft/LLMLingua) and
[LLMLingua-2 model card](https://huggingface.co/microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank).

## Recommended next work

1. Record content-free **per-pass** task, served model/effort, uncached/cache-read/
   cache-write/image tokens where available, billable output/reasoning tokens,
   and input/output costs. Group answer, planning, suggestions, and search for a
   turn with an opaque identifier. This enables an actual Study Desk baseline.
2. Evaluate concise fixed instructions and smaller, task-specific planner context.
   The planner and answer currently receive separate instructions and copies of
   retrieved material. Backend history already compacts to twelve turns/24 KB;
   measure before compressing it further.
3. Calibrate the existing router and output/thinking budgets on real tasks.
   Output costs five times as much per token at the configured rates; a credible
   50% goal needs output/reasoning or model-rate savings as well as shorter input.
4. Verify supplier prices and cached-input rates. The local model config omits
   `cachedInputMicroPerKilo`, so cached reads use full input rates in the local
   cost calculation. Live secrets may differ. Keep stable instructions cacheable.
5. If experimenting further with LLMLingua, restrict it to redundant prose,
   protect complete equations, units, conditions, source mappings and original
   quoted evidence, and compare against sentence selection. Use a multilingual,
   math-heavy held-out evaluation before enabling it. It needs a separate serving
   strategy from the current Flutter/Deno stack; include that cost and latency.

No application behavior, production schema, secrets, or deployed functions were
changed by this audit. Measurement tooling and this report were added locally.

## Reproduce

From the repository root, with Flutter dependencies already available:

```powershell
flutter test --no-pub tool/study_desk_cost/capture_test.dart --reporter expanded
python -m venv --system-site-packages build/study_desk_cost_audit/venv
& build/study_desk_cost_audit/venv/Scripts/python.exe -m pip install -r tool/study_desk_cost/requirements.txt
& build/study_desk_cost_audit/venv/Scripts/python.exe tool/study_desk_cost/audit.py
```

The optional `--live-answer-model sol` flag reads local server credentials and
spends real API credit on six synthetic requests. The default performs no paid
generation calls; it downloads the public compressor if not cached. The tested
environment used Python 3.13.5, LLMLingua 0.2.2, Transformers 5.8.1, Torch
2.12.0+cu126, and tiktoken 0.12.0.

Raw captures, compressed text, live answers, and the numeric billing export are
under ignored `build/study_desk_cost_audit/`. A small content-free result snapshot
is retained at `tool/study_desk_cost/results_2026-11-06.json`. The capture harness
passed, and the Python script compiled and completed its local/live runs.
