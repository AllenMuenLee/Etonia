# Study Desk cost experiments

Use synthetic fixtures only. Captures and generated answers stay in ignored
`build/study_desk_cost_audit/`; checked-in results contain counts and costs.
No command below deploys an app/function or writes production billing rows.

The implementation/evaluation report is
[`docs/study_desk_cost_implementation.md`](../../docs/study_desk_cost_implementation.md).

## Reproduce locally

Capture current production request construction without provider calls:

```powershell
$env:STUDY_CAPTURE_OUTPUT='build/study_desk_cost_audit/captured_requests_B.json'
flutter test tool/study_desk_cost/capture_test.dart
```

The 150-case manifest was frozen before evaluation. Do not regenerate/edit it
and reuse old grades. Its builder documents the independently authored families;
changing fixtures requires a fresh evaluation directory and calibration.

```powershell
$env:STUDY_CAPTURE_FIXTURES='supabase/evals/study_cost/cases.json'
$env:STUDY_CAPTURE_OUTPUT='build/study_desk_cost_audit/captured_evaluation_B.json'
flutter test tool/study_desk_cost/capture_test.dart
```

The following command makes paid provider calls using local secrets. It is
resumable and enforces a worst-case spend budget including in-flight calls.
The completed run cost $1.091377; future costs and outputs can differ.

```powershell
npx --yes deno run --allow-read --allow-write --allow-env --allow-net --env-file=supabase/.env.local --config supabase/functions/deno.json supabase/evals/study_quality.ts --budget-usd 8
python tool/study_desk_cost/fit_calibration.py
npx --yes deno fmt supabase/functions/_shared/study_calibration.ts
```

The fitter asserts the frozen manifest digest, keeps failed categories disabled,
and writes `phase_B_results.json` plus `study_calibration.ts`. Retain the original
results before experimenting with a new policy/model. Do not tune prompts on the
held-out partition or merge grades from different policies.

For a complete-turn smoke replay, capture a synthetic fixture subset to
`build/study_desk_cost_audit/captured_smoke_B.json`, then run the paid
`supabase/evals/study_routing_smoke.ts` with the same Deno permissions/env/config.
It runs real planner verdicts and router choices, includes all helpers/retries,
and compares calibration off/on on otherwise identical B inputs. Its hard spend
budget is $2; results summarize into `phase_B_smoke_results.json`. The reported
six cases were IDs ending in `020`, `040`, `060`, `100`, `120`, and `131` in the
frozen manifest. The smoke checks structure and routing; it is not the 150-case
quality gate or a representative production workload.

The older `study_cost.ts` A replay uses captured pre-change baseline requests.
Its fixed model choices compare transport/cache behavior; use the routing smoke
for actual routing measurements. Do not compare totals as if these experiments
sampled the same workload.

## Conditional-retrieval follow-up

The November 7 app policy decides retrieval before loading source content.
[`credit_drop_2026_11_07.json`](credit_drop_2026_11_07.json) records a content-free
production billing snapshot. It is distinct from the synthetic experiments.

To capture the changed planner and run its twelve-case synthetic behavior smoke:

```powershell
Remove-Item Env:STUDY_CAPTURE_FIXTURES -ErrorAction SilentlyContinue
$env:STUDY_CAPTURE_OUTPUT='build/study_desk_cost_audit/captured_requests_gate.json'
flutter test tool/study_desk_cost/capture_test.dart
npx --yes deno run --allow-read --allow-write --allow-env --allow-net --env-file=supabase/.env.local --config supabase/functions/deno.json supabase/evals/study_retrieval_gate.ts
```

This makes direct paid provider calls (hard budget $0.10); it does not charge
an app account's credit ledger. The completed run cost $0.005050. `--rescore`
uses saved answers without network calls and recognizes fenced JSON exactly as
the production transport does. The smoke verifies retrieval behavior, rather
than qualifying a new cheaper model route. See
[`docs/study_desk_credit_drop_investigation.md`](../../docs/study_desk_credit_drop_investigation.md).

The notes-first follow-up has a separate capture and result file. Set
`STUDY_CAPTURE_OUTPUT` to `build/study_desk_cost_audit/captured_requests_notes_first.json`,
capture as above, then add `--notes-first` to the paid gate evaluator command.
It checks 18 cases and writes `notes_first_results.json`; the completed corrected
run cost $0.006115. It preserves the earlier twelve-case result file.
See [notes-first policy](../../docs/study_desk_notes_first_retrieval.md).
