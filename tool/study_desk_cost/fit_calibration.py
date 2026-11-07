"""Fit the frozen B gate. Raw answers stay in ignored build/; no network calls.

Answer categories must pass BOTH difficulty bands at a given effort, with zero
failures in at least ten calibration and ten held-out cases per band. Planner
qualification covers only difficulty 2, the band actually evaluated.
"""
import hashlib
import json
import math
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
manifest = ROOT / "supabase/evals/study_cost/cases.json"
digest = hashlib.sha256(manifest.read_bytes()).hexdigest()
cases = {c["id"]: c for c in json.loads(manifest.read_text(encoding="utf-8"))}
result = json.loads((ROOT / "build/study_desk_cost_audit/quality_B/results.json").read_text(encoding="utf-8"))
assert result["caseDigest"] == digest, "Frozen manifest changed"
groups = defaultdict(list)
for row in result["runs"]:
    case = cases[row["caseId"]]
    groups[(row["task"], case["kind"], case["difficulty"], row["model"], row["effort"])].append(row)


def passed(key):
    rows = groups.get(key, [])
    return all(sum(r["partition"] == p for r in rows) >= 10 and
               all(r["pass"] for r in rows if r["partition"] == p)
               for p in ("calibration", "heldout"))


profile, summaries = [], []
for key, rows in sorted(groups.items()):
    task, kind, difficulty, alias, effort = key
    eligible = alias == "luna" and kind != "sentinel" and passed(key)
    if task == "study.answer":
        eligible = eligible and all(passed((task, kind, d, alias, effort)) for d in (1, 2))
    summary = dict(task=task, kind=kind, difficulty=difficulty, model=alias, effort=effort,
                   qualified=eligible, generationCostMicro=sum(r["costMicro"] for r in rows),
                   inputCostMicro=round(sum(r["inputCostMicro"] for r in rows), 6),
                   outputCostMicro=round(sum(r["outputCostMicro"] for r in rows), 6),
                   inputTokens=sum(r["inputTokens"] for r in rows),
                   outputTokens=sum(r["outputTokens"] for r in rows))
    for partition in ("calibration", "heldout"):
        subset = [r for r in rows if r["partition"] == partition]
        summary[partition] = dict(cases=len(subset), failures=sum(not r["pass"] for r in subset))
    summaries.append(summary)
    if not eligible:
        continue
    outputs = sorted(r["outputTokens"] for r in rows if r["partition"] == "calibration")
    estimate = max(256, math.ceil(outputs[math.ceil(len(outputs) * .95) - 1] * 1.25))
    profile.append(dict(policyVersion="study-cost-b1", model="gpt-6-luna", task=task,
                        kind=kind, difficulty=difficulty, effort=effort,
                        score=(55 + 12 * (difficulty - 1) if task == "study.answer" else 53) +
                              (effort == "medium"), outputTokens=estimate,
                        calibrationCases=summary["calibration"]["cases"],
                        holdoutCases=summary["heldout"]["cases"],
                        calibrationFailures=0, holdoutFailures=0, caseDigest=digest))

target = ROOT / "supabase/functions/_shared/study_calibration.ts"
header = target.read_text(encoding="utf-8").split("// An empty profile")[0].split("// Frozen gate:")[0]
target.write_text(header + "// Frozen gate: tool/study_desk_cost/fit_calibration.py. Do not hand-edit rows.\n" +
                  "export const studyCalibration: readonly StudyRouteCalibration[] = " +
                  json.dumps(profile, indent=2) + ";\n", encoding="utf-8")
selected = []
for row in result["runs"]:
    c = cases[row["caseId"]]
    if row["task"] == "study.answer" and c["kind"] == "calculation":
        if row["model"] == "sol" or (row["model"] == "luna" and row["effort"] == "low"):
            selected.append(row)
costs = {alias: sum(r["costMicro"] for r in selected if r["model"] == alias)
         for alias in ("sol", "luna")}
captures = json.loads((ROOT / "build/study_desk_cost_audit/captured_evaluation_B.json").read_text(encoding="utf-8"))
before = after = pruned = 0
facts_preserved = []
for case in cases.values():
    if case["kind"] != "sourceLookup":
        continue
    prompt = next(r["prompt"] for r in captures if r["fixture"] == case["id"] and r["task"] == "study.answer")
    paragraphs = case["text"].split("\n\n")
    original = sum(len(p) for p in paragraphs)
    retained = sum(len(p) for p in paragraphs if p in prompt)
    before += original
    after += retained
    pruned += retained < original
    identifier = case["question"].split("notes for ")[-1].split(",")[0]
    facts = [p for p in paragraphs[1:] if identifier.lower() in p.lower()]
    assert facts, "Fixture has no identifiable source facts"
    facts_preserved.append(all(p in prompt for p in facts))
assert all(facts_preserved), "Critical original source paragraph was lost"
summary = dict(caseDigest=digest, cases=len(cases), generations=len(result["runs"]),
               passedGenerations=sum(r["pass"] for r in result["runs"]),
               actualEvaluationSpendMicro=result["actualEvaluationSpendMicro"],
               qualifiedProfiles=len(profile), groups=summaries,
               calculationAnswerCostMicro=costs,
               calculationAnswerSavings=1-costs["luna"]/costs["sol"],
               sourceSelection=dict(cases=len(facts_preserved), casesPruned=pruned,
                    originalSourceCharacters=before, retainedSourceCharacters=after,
                    relevantOriginalParagraphsPreserved=all(facts_preserved)),
               limitations=["Synthetic cases; automated blind grading with conservative zero-failure gate.",
                            "Same B input compared across models, not a production A/B experiment.",
                            "Cache states and sampled output lengths differ.",
                            "Answer profiles require both difficulty bands; no definition/source answer downgrade.",
                            "Protected proof, lesson, visual and non-ASCII requests retain existing routes."])
(ROOT / "tool/study_desk_cost/phase_B_results.json").write_text(json.dumps(summary, indent=2)+"\n", encoding="utf-8")
print(json.dumps({k: v for k, v in summary.items() if k != "groups"}, indent=2))
