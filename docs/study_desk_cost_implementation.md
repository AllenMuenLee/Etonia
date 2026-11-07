# Study Desk cost optimization: implementation and evaluation

Work authorized: complete A, evaluate it, then complete B without another checkpoint.
Existing unrelated working-tree changes are preserved. No deployment has been performed.

Follow-up: the [retrieval-gate and free-credit investigation](study_desk_credit_drop_investigation.md)
records the November 7 fix. It supersedes deterministic planner skipping for
`next`: each reply now obtains a fresh model retrieval decision. Prior A/B cost
figures below describe their original experiments, not the changed planner policy.
Follow-up verification: 317 Flutter tests, 70 backend tests, 12/12 live synthetic
retrieval checks, and clean targeted Dart analysis. Live billing reconstructed
19.6228% to 2.6258% of a $0.50 free grant; the linked report explains the charges.

## A: completed initial gate

- Added cache-read/write pricing, exact Standard defaults for Sol/Luna, and OpenAI
  cache-write/reasoning/image usage parsing. Reasoning remains part of output cost.
- Added content-free per-pass and per-turn accounting with atomic settlement,
  strict metadata fields, service-role permissions, and aggregate analytics views.
- Added explicit stable-instruction cache boundaries on supported configured models.
- Added plain Markdown/JSON transport for backend Study Desk chat/helpers; drawing
  transport is unchanged. Old-server validation failures fall back once before
  provider work; provider failures/timeouts are never retried as legacy work.
- Fixed a live-discovered JSON/LaTeX escape failure using object JSON mode and an
  explicit JSON contract. Both object and legacy-array suggestions are readable.
- Confirmed in-flight suggestion refreshes do not trigger duplicate requests.

The corrected live replay passed 9/9 completion/structure checks and the checked
facts/citations for three synthetic tutor turns. Actual corrected replay cost was
$0.015856, with 4,224 cache-read tokens. The comparison baseline was $0.025525.
Repricing the corrected outputs without cache discounts gives $0.023880, about
6.4% below baseline. These are small controlled samples, not production savings.
Cache hits were intermittent, so a repeat request is not assumed to be warm.
The first attempted plain replay exposed invalid suggestion JSON and was rejected
as a gate result; it is not counted as a successful cost optimization.

Numbers: `tool/study_desk_cost/phase_A_results.json`.
Raw synthetic replay output: ignored `build/study_desk_cost_audit/phase_A*_live.json`.

## B: completed and evaluated (November 7, 2026)

- Whole-paragraph selection for sufficiently long typed prose, with neighboring
  context. Mathematical blocks, uncertain ink, and visual evidence stay intact.
- Opaque turn correlation across planner, answer and suggestions.
- Bounded planner difficulty; server-side protection for proofs, complex
  derivations, visual input, and active lesson/assessment context.
- Deterministic one-step navigation for explicit `next` requests; assessment and
  correctness judgments still use the planner.
- Task-specific helper output ceilings, with full high-effort/answer headroom.
- Structural helper and source-ID checks before escalation.
- Nine model-version-specific routing entries passed the frozen calibration and
  held-out gate. Definition/source answer entries failed and were rejected.

### What qualified

| Task | Category | Difficulty | Luna effort |
|---|---|---|---|
| Answer | Routine calculation | 1 and 2 | Low and medium |
| Planner | Calculation | 2 | Low and medium |
| Planner | Definition | 2 | Medium |
| Planner | Source lookup | 2 | Low and medium |

Each entry needs at least ten calibration and ten held-out cases with **zero
failures**. Answer categories must pass both difficulty bands at the same effort
before either band is enabled. Output estimates use calibration cases only;
they do not truncate answers. Scores apply only to the exact `gpt-6-luna` model
and `study-cost-b1` protocol. Explicit custom router scores take precedence.

Qualification is limited to the evaluated scope: first-turn ASCII text. Routine
calculation qualification excludes attached source excerpts. History, non-ASCII
text, visual input, diagrams, proofs, complex derivations and active lessons
receive no new cheap-answer qualification. Unqualified answer categories have a
minimum normal difficulty, preventing a cheap planner's "easy" classification
from indirectly lowering their answer route. Model switches, plan eligibility,
credits, and retry billing constraints remain enforced by the router.

### Measured costs and tokens

The frozen experiment covered **150 synthetic cases, 630 generations, and 450
blind automated answer judgments**. It cost **$1.091377**, including judges.
There were 571 passing generations and 59 failures across all tested models and
efforts; qualification uses individual category gates, not that aggregate rate.

Forty routine calculation answers used the same B inputs across models:

| Model / effort | Input tokens | Output tokens | Input cost | Output cost | Total cost* |
|---|---:|---:|---:|---:|---:|
| Sol medium | 46,178 | 3,599 | $0.0184232 | $0.0359900 | $0.054436 |
| Luna low | 46,178 | 2,936 | $0.00102356 | $0.0014680 | $0.002513 |
| Luna medium | 46,178 | 3,761 | $0.00111572 | $0.0018805 | $0.003018 |

*Totals include per-call rounding to whole microdollars. Cache states differ.
Both Luna efforts passed 40/40 cases. Low cost **95.4% less** and medium **94.5%
less** than Sol medium on this workload. The automatic router can choose medium
when its calibrated output estimate is as cheap or cheaper; it is not pinned to
low. **These savings come mainly from price, not halving tokens.** Input token
counts are identical; medium output tokens actually increased.

A separate six-turn replay ran real planner decisions, router choices, answers,
and suggestions, comparing calibration disabled/enabled on otherwise identical B
transport/context. Both variants completed 17/17 structurally valid calls; one
explicit next-step turn correctly skipped the planner. Total cost changed from
**$0.019889 to $0.017109 (14.0% less)**. The two calculation turns changed from
$0.000670 to $0.000329 (50.9% less) and $0.003677 to $0.000523 (85.8% less).
Definitions/source lookups retained Sol medium and proof/lesson answers retained
Sol high. Output sampling caused some protected turns to cost more in B. The
first smoke run exposed the easy-label routing gap and was rejected; the figures
above are from the corrected run. Initial and corrected raw runs stay in build/.

Whole-paragraph selection removed 11,794 of 71,791 source characters (16.4%)
across the 40 source fixtures, pruning 19 cases. Every original paragraph
containing the synthetic source's relevant identifier remained verbatim. This
is a **source-character** measurement, not a 16.4% total-token saving. Unit tests
also protect mathematical blocks, visual/uncertain evidence, neighboring context,
and whole-block budget fitting.

### Self-evaluation and decision

Keep A and the qualified B routes. **Do not add LLMLingua to the default path.**
The earlier compressor trial saved only 10.8% input tokens, increased cost 2.8%,
and damaged math. Broad Luna answer routing also failed this experiment:
definitions lost technical qualifications; source answers sometimes omitted
exceptions or citations. Those routes were not enabled. Some stronger-model
answers failed too, so retaining them does not claim perfect correctness.

The evaluation uses a model judge, not an independent human correctness audit.
Source grades were conservative: the judge received original source text rather
than every UI source identifier, so some citation rejections may be false
negatives. We kept them as failures. No prompts were tuned to rescue held-out
results, and no failed answer category was enabled. The sentinels are text
examples; real handwriting/image quality has not been certified by this study.

**The 50% overall Study Desk cost goal is not yet demonstrated.** The mixed-turn
replay saved 14.0%; production workload proportions and cache behavior remain
unknown. With a 94.5% saving confined to one workload, roughly 53% of the original
bill would need to come from that eligible workload to halve the entire bill,
before considering other changes. A's metering now makes that production
question measurable after deployment. Historical rows cannot retroactively
separate Study Desk from editor usage.

Machine-readable evidence:
[A results](../tool/study_desk_cost/phase_A_results.json),
[B results](../tool/study_desk_cost/phase_B_results.json),
[complete-turn replay](../tool/study_desk_cost/phase_B_smoke_results.json).
Frozen case SHA-256:
`280e3b62e4bcb0132e4dd5d1e6a9239a8f4d0efbb1b8b3e8c63d1a71546a9acf`.
The [fitting script](../tool/study_desk_cost/fit_calibration.py) regenerates the
profile and content-free summary from ignored local evaluation results.

### Verification

- 310 relevant Flutter regression tests passed, including Study Desk, source
  citations, teaching plans, navigation, practice flows, and backend transport.
- Targeted Dart static analysis reported no issues.
- 70 backend tests passed, covering real PostgreSQL settlement, permissions, privacy,
  idempotence, router constraints, pricing, policy and response validation.
- TypeScript function/evaluation type checks and whitespace checks passed.

The corrected complete-turn experiment cost $0.036998 for both variants. The
rejected initial smoke cost $0.042012. Together with A's earlier $0.0843 replay
spend and B's $1.091377 quality experiment, implementation evaluation spend was
approximately **$1.25469**. These are provider-priced experiment costs, separate
from user feature-cost measurements and the earlier research/compressor trial.

The earlier [audit](study_desk_token_cost_audit.md) and
[research report](study_desk_token_savings_research.md) document the original
baseline and alternatives. Their statements that implementation had not started
describe that earlier research stage; this document records the completed work.

## Deployment order

Apply `202611080001_ai_usage_breakdown.sql` before deploying the updated `ai`
function. Deploy the backend before distributing an app that uses the new
transport. The legacy settlement RPC and old SVG clients remain supported.
The current local backend credentials/secrets have not been printed or changed.
No migration, function, or app has been deployed during this implementation.
Future prompt/model changes require fresh qualification and a policy version
change; the scores are not a permanent or general model quality claim.
