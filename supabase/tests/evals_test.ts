import { strict as assert } from "node:assert";
import type { Effort, Task } from "../functions/_shared/ai_router.ts";
import { tasks } from "../functions/_shared/ai_router.ts";
import {
  type EvalCase,
  type EvalRun,
  fitScores,
  fitTaskBars,
  judgeScore,
  scoreAnswer,
  unfenced,
} from "../evals/lib.ts";

const makeCase = (id: string, difficulty: 1 | 2 | 3, task: Task = "study.answer"): EvalCase => ({
  id,
  task,
  difficulty,
  capabilities: ["reasoning"],
  prompt: "?",
  check: { type: "contains_all", values: ["x"] },
});

const run = (caseId: string, alias: string, effort: Effort, score: number): EvalRun => ({
  caseId,
  alias,
  effort,
  score,
  costMicro: 0,
  latencyMs: 0,
});

Deno.test("answers are checked without a judge", () => {
  assert.equal(
    scoreAnswer(
      { type: "contains_all", values: ["Kirchhoff", "loop"] },
      "the LOOP law of kirchhoff",
    ),
    1,
  );
  assert.equal(
    scoreAnswer({ type: "contains_all", values: ["Kirchhoff", "node"] }, "the loop law"),
    0,
  );
  assert.equal(
    scoreAnswer({ type: "contains_any", values: ["3 mA", "0.003 A"] }, "I = 0.003 A"),
    1,
  );
  assert.equal(scoreAnswer({ type: "regex", pattern: "^\\d+$" }, "42"), 1);
  assert.equal(scoreAnswer({ type: "regex", pattern: "^\\d+$" }, "forty-two"), 0);
  const json = { type: "json" as const, requiredKeys: ["score", "feedback"] };
  assert.equal(scoreAnswer(json, '```json\n{"score":4,"feedback":"ok"}\n```'), 1);
  assert.equal(scoreAnswer(json, '{"score":4}'), 0);
  assert.equal(scoreAnswer(json, "[1,2]"), 0);
  assert.equal(scoreAnswer(json, "not json"), 0);
  assert.equal(unfenced("```\nabc\n```"), "abc");
});

Deno.test("a judge's reply becomes a score from 0 to 1", () => {
  assert.equal(judgeScore("0.5"), 0.5);
  assert.equal(judgeScore("8"), 0.8);
  assert.equal(judgeScore("Score: 75"), 0.75);
  assert.equal(judgeScore("1"), 1);
  assert.equal(judgeScore("no idea"), 0);
  assert.equal(judgeScore("-3"), 0);
});

Deno.test("scores are the pass rate by capability, and thinking more never lowers one", () => {
  const cases = [makeCase("a", 1), makeCase("b", 2), makeCase("c", 3)];
  const runs = [
    run("a", "haiku", "low", 1),
    run("b", "haiku", "low", 0),
    run("c", "haiku", "low", 0),
    // A small sample that says medium is worse than low: it is held at low's.
    run("a", "haiku", "medium", 0),
    run("b", "haiku", "medium", 1),
    run("c", "haiku", "medium", 0),
    run("a", "sol", "high", 1),
    run("b", "sol", "high", 1),
    run("c", "sol", "high", 1),
  ];
  const config = fitScores(cases, runs);
  assert.deepEqual(config.haiku.scores.reasoning, { low: 33, medium: 33 });
  assert.deepEqual(config.sol.scores.reasoning, { high: 100 });
  // No vision case, so nothing is said about vision.
  assert.equal(config.haiku.scores.vision, undefined);
});

Deno.test("a task's bar is the weakest pair that still passes its cases", () => {
  const cases = [
    makeCase("easy", 1),
    makeCase("hard", 3),
    makeCase("other", 1, "study.plan"),
  ];
  const strength: Record<string, number> = {
    "haiku:low": 40,
    "sonnet:medium": 74,
    "opus:high": 94,
  };
  const runs = [
    run("easy", "haiku", "low", 1),
    run("easy", "sonnet", "medium", 1),
    run("easy", "opus", "high", 1),
    run("hard", "haiku", "low", 0),
    run("hard", "sonnet", "medium", 0),
    run("hard", "opus", "high", 1),
    run("other", "haiku", "low", 0),
  ];
  const bars = fitTaskBars(cases, runs, (alias, effort) => strength[`${alias}:${effort}`]);
  assert.deepEqual(bars["study.answer"]!.perDifficulty, { 1: 40, 3: 94 });
  // Difficulty 1 needs 40 and difficulty 3 needs 94: a step of 27 between levels.
  assert.equal(bars["study.answer"]!.threshold, 40);
  assert.equal(bars["study.answer"]!.step, 27);
  // Nothing passed the other task's case, so no bar is claimed for it.
  assert.equal(bars["study.plan"], undefined);
});

Deno.test("the seed cases are well formed and cover every routed task", async () => {
  const seed = JSON.parse(
    await Deno.readTextFile(new URL("../evals/cases/seed.json", import.meta.url)),
  ) as EvalCase[];
  assert.equal(new Set(seed.map((c) => c.id)).size, seed.length, "ids are unique");
  for (const evalCase of seed) {
    assert.ok((tasks as readonly string[]).includes(evalCase.task), evalCase.id);
    assert.ok(evalCase.capabilities.length > 0, evalCase.id);
    assert.ok([1, 2, 3].includes(evalCase.difficulty), evalCase.id);
    if (evalCase.check.type === "regex") {
      new RegExp(evalCase.check.pattern, evalCase.check.flags ?? "i");
    }
  }
  for (const task of tasks) {
    if (task === "editor.notation" || task === "study.describe") continue; // Needs real visual pages.
    assert.ok(seed.some((c) => c.task === task), `no seed case for ${task}`);
  }
});
