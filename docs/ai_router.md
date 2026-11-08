# AI router

Etonia chooses the model, and how much it thinks, for every AI request. The user
no longer picks a model. The rule is: the cheapest (model, effort) pair, by
provider cost, that is capable enough for the task.

Status: built end to end. The router (`supabase/functions/_shared/ai_router.ts`),
its billing rules (`supabase/migrations/202611060001_router_billing.sql`), the
`ai` function, the app's Thinking control and Advanced settings, and the eval
tooling (`supabase/evals/`) all exist and are tested. Generic capability numbers
remain placeholders. A narrow `study-cost-b1` profile now supplies measured
qualification for first-turn ASCII calculations and selected planner categories
on exactly `gpt-6-luna`; all other categories retain the baseline capability
ordering. See [the cost evaluation](study_desk_cost_implementation.md) for gates,
rejected categories, costs, and limitations. This is not a global model ranking.

## Decisions

- **Cost is provider cost**, never what the user pays. Otherwise unlimited models
  would always look free and win every request.
- **Server side.** Prices, capabilities and provider health change without an app
  release, and plan enforcement already lives on the server.
- **Unlimited models are unlimited only at low and medium effort.** Haiku and Luna
  cost a paid plan nothing up to medium effort. High effort on them is metered.
- **A paid plan that runs out of credits carries on, silently,** on an unlimited
  model at low or medium effort, whatever thinking level was asked for. Neither
  the assistant nor Study Desk says anything about it.
- **A free plan that runs out of credit stops answering.** The request is refused
  with `insufficient_credits`, as today.
- **Capability comes from evals on Etonia's own tasks**, not from this document.

## How a request is routed

The app sends `model: "auto"`, a `task`, an `effort` setting
(`auto | low | medium | high`) and the models the user left on. The server
resolves them before it reserves anything.

1. Refuse a free plan with no credit left.
2. Drop models the user turned off, the plan does not include (free and Starter
   have no frontier models), whose provider is unhealthy, or that cannot take the
   input (a picture that must be read, or too many tokens).
3. Build (model, effort) pairs. `auto` considers every effort; a fixed level
   considers that level, then steps down one at a time if credits cannot pay for
   it.
4. Drop pairs the credits cannot cover. A pair is unlimited (always affordable)
   only on a paid plan, for Haiku or Luna, at low or medium effort. Any other pair
   needs credit greater than zero and at least its estimated cost.
5. Keep the pairs whose capability reaches what the task needs at its difficulty.
6. Choose the cheapest of those, then the fastest, then the strongest. A model
   that answered last turn is kept unless another is more than 15% cheaper, for
   its warm prompt cache and a steady voice.
7. If nothing is capable, the strongest allowed pair answers.

**Escalation.** When an answer fails in a way the server can check (unparseable
JSON, an empty or refused answer, citations that do not resolve), `escalate()`
returns the next pair, strictly stronger and not already tried. The existing
one-pending-request rule means the retry runs after the first request settles.

**Thinking.** Effort maps to each provider's own setting, as the drawing pass
already does: OpenAI `reasoning_effort`, Claude `thinking: adaptive` with
`output_config.effort`, Gemini `thinkingConfig.thinkingLevel`. Thinking tokens
are billed as output, so each effort multiplies the task's usual output in the
cost estimate (`thinkingFactor`, to be calibrated from logged usage).

## Tasks

| Task | Needs | Where it comes from |
|---|---|---|
| `study.suggestions` | structured output | follow-up questions after an answer |
| `study.plan` | structured output, reasoning | the teaching planner |
| `study.answer` | reasoning | Study Desk answers and lessons |
| `study.practice` | structured output, reasoning | practice sets and tests |
| `editor.answer` | reasoning, vision | the editor's selection assistant |
| `editor.notation` | drawing, vision | the notation and drawing pass |
| `test.grading` | reasoning, vision | grading handwritten tests |

A pair is held to the weakest of the capabilities its task needs. The bar is a
base score plus a step for each level of difficulty. Difficulty (1 to 3) comes
from the Study Desk planner, which already reads the retrieved passages, or from
request features such as equations and attached pictures. A picture that must be
read adds `vision`; a diagram adds `diagrams`.

## Settings

Gemini 3.8 Flash (`flash`) is a standard, balanced model alongside Sonnet and
Sol. It uses the native Gemini Generate Content API and `LOW`, `MEDIUM`, or
`HIGH` thinking levels. Its introductory rates through December 31, 2026 are
$0.75 input, $0.075 cached input, and $3.75 output per million tokens, including
thinking. Review rates before January 1, 2027; Google lists $1.50/$0.15/$7.50
from that date. See [Google's pricing](https://ai.google.dev/gemini-api/docs/pricing).

`AI_MODEL_CONFIG_OVERRIDES` is an optional JSON object merged over
`AI_MODEL_CONFIG`. It can enable `flash` without replacing existing provider
models or prices. The app's optional model-ID override is `FLASH_MODEL_ID`.
Apply `202611090001_visual_description_usage.sql` and
`202611100001_flash_balanced_model.sql` before releasing the corresponding AI
function: both task and model aliases must be accepted by billing settlement.

Default settings show one control, **Thinking**: Auto, Low, Medium or High. Auto
lets the router decide. A fixed level is used exactly, unless credits cannot pay
for it (see above).

**Advanced** holds a switch for each model, and for each provider, so a user can
keep their notes away from one. Turning off every model but one pins it. The
choice is stored next to the preferred model in `subscription.json`. A request
whose models are all off, or whose providers are all down, is refused rather than
sent to a model the user turned off. If a paid plan is out of credits and both
unlimited models are off, it is also refused with `insufficient_credits`.

## Capability data

`buildCatalog()` gives every configured model a placeholder score by tier
(unlimited, standard, frontier) and effort. It encodes only the ordering the
product already claims, not any measured strength. Per-model, per-capability
scores go in `AI_ROUTER_CONFIG` (a secret, like `AI_MODEL_CONFIG`) as overrides:

```json
{ "haiku": { "scores": { "reasoning": { "high": 71 } }, "latencyRank": 1 } }
```

Build the eval set before trusting the thresholds in `taskProfiles`: about 30 to
50 prompts per task, from real use (handwritten digital-systems pages, derivations,
diagrams, test grading), run for each (model, effort), scored against known good
answers. The scores and thresholds are then set from the results.

Log content-free usage per request: task, model, effort, tokens, cost, whether it
escalated. It matches the privacy boundary in `supabase/README.md` and calibrates
the output estimates.

## Billing

The previous migration (`202611050001_no_token_reserve.sql`) charged every
settled cost in full, so Haiku and Luna drew credits on a paid plan although the
app calls them unlimited. `202611060001_router_billing.sql` fixes that and makes
the rule depend on effort:

- `ai_reserve` takes `p_effort` and records, per request, whether it is
  **unlimited**: a paid plan, Haiku or Luna, effort low or medium.
- `ai_settle` charges nothing for an unlimited request, and still records the
  provider cost, so real spend on unlimited models stays visible.
- An unlimited request is admitted at a zero balance. That is how a paid plan
  that has run out of credits carries on, silently. A free plan has no unlimited
  requests and is refused with `insufficient_credits`.
- For a request with a drawing pass, the database sees the stricter model and
  the higher effort of the two passes, so it is unlimited only if both are.
- Older apps name a model and no effort: they are billed as medium, as before.

`ai/index.ts` reads the plan and credits (`billing_state`) before it reserves,
so the router never picks a pair the balance cannot pay for. If a retry (the
provider is down, or the answer was empty or unreadable) would change how the
request is billed, it is not made: the reservation was for the first pair.

## What is where

| Piece | Where |
|---|---|
| Router, catalog, escalation, request parsing | `supabase/functions/_shared/ai_router.ts` |
| Effort on provider requests | `providerRequest(..., effort)` in `_shared/ai_policy.ts` |
| Routing in the function, outage skip, usage log | `supabase/functions/ai/index.ts` |
| Unlimited billing | `supabase/migrations/202611060001_router_billing.sql` |
| App request and settings model | `lib/features/editor/ai/ai_routing.dart` |
| Thinking control and Advanced page | `lib/features/editor/widgets/ai_routing_controls.dart` |
| Eval cases, runner, fitting | `supabase/evals/` |

The app's settings live in `subscription.json` under `routing`, beside the
preferred model, and survive launches. Study Desk's planner, suggestions,
answers, practice sets and test grading are all routed tasks. The editor's
answer is `editor.answer`; its drawing pass is chosen on the server (the
configured notation model unless the user turned it off or it cannot be paid
for).

A client that does not route (the direct-key clients used in development) keeps
the old behaviour: it answers with one model, and there is no picker for it.

## Measuring capability

`supabase/evals/cases/seed.json` is a starter set, not the real one. Grow it to
about 30 to 50 cases per task, from real use, then:

```powershell
deno run --allow-env --allow-net --allow-read --allow-write supabase/evals/run.ts --tasks study.answer --models haiku,sonnet
deno run --allow-read supabase/evals/fit.ts supabase/evals/results/<day>.json
```

`run.ts` sends each case to each (model, effort) with the same provider request
the function builds, and scores it (substring, regex, JSON shape, or a judge
model with `--judge`). `fit.ts` prints the `AI_ROUTER_CONFIG` secret to set, and
the bar (`threshold` and `step`) each task needs, to copy into `taskProfiles`.
Cases with a picture put the PNG beside the JSON and name it in `image`.

## Work left

1. Run the eval set on real models and set `AI_ROUTER_CONFIG` and `taskProfiles`.
   The placeholders make Haiku and Luna (unlimited) look capable only up to
   difficulty 1 to 2, so most hard questions will go to a metered model.
2. Difficulty is the server's default (2) except where the app says otherwise.
   The Study Desk planner already reads the passages; having it return a 1 to 3
   verdict, passed on as `routing.difficulty`, is the natural source.
3. Calibrate `thinkingFactor` from the logged `ai_route` lines.
4. The plan cards still say "unlimited" for Haiku and Luna and "never use" the
   token pool; that is true up to medium thinking and no longer at high. Change
   the copy together with its golden images (`test/features/payment`).

## Verification

```powershell
npx --yes deno test --config supabase/functions/deno.json --allow-env --allow-read supabase/tests/ai_router_test.ts supabase/tests/ai_policy_test.ts supabase/tests/evals_test.ts
npx --yes deno test --config supabase/functions/deno.json --allow-env --allow-read --allow-net --allow-write --allow-sys --allow-run supabase/tests/billing_test.ts
flutter test
```
