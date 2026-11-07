/**
 * Turns eval results into router data.
 *
 *   deno run --allow-read supabase/evals/fit.ts supabase/evals/results/<day>.json
 *
 * Prints two things. `AI_ROUTER_CONFIG` is the secret to set: each model's
 * score by capability and effort. The bars are what `taskProfiles` in
 * `ai_router.ts` should hold, read against the baseline scores in effect (the
 * measured ones where there are any).
 */
import {
  buildCatalog,
  type Capability,
  type Effort,
  type Task,
  taskProfiles,
} from "../functions/_shared/ai_router.ts";
import type { ModelConfig } from "../functions/_shared/ai_policy.ts";
import { type EvalCase, type EvalRun, fitScores, fitTaskBars } from "./lib.ts";

const path = Deno.args[0];
if (!path) {
  console.error("usage: fit.ts <results.json>");
  Deno.exit(2);
}
const { cases, runs } = JSON.parse(await Deno.readTextFile(path)) as {
  cases: EvalCase[];
  runs: EvalRun[];
};

const config = fitScores(cases, runs);

// A placeholder price: the router's data does not depend on it.
const priced = (provider: ModelConfig["provider"]): ModelConfig => ({
  provider,
  model: "eval",
  inputMicroPerKilo: 1,
  outputMicroPerKilo: 1,
  maxOutputTokens: 1024,
});
const catalog = buildCatalog(
  {
    haiku: priced("claude"),
    luna: priced("openai"),
    sonnet: priced("claude"),
    sol: priced("openai"),
    opus: priced("claude"),
    argon: priced("gemini"),
    astra: priced("openai"),
  },
  config,
);

const scoreOf = (alias: string, effort: Effort, task: Task) => {
  const model = catalog.find((entry) => entry.alias === alias);
  if (!model) return 0;
  return Math.min(
    ...taskProfiles[task].needs.map((need: Capability) => model.scores[need][effort]),
  );
};

console.log("AI_ROUTER_CONFIG =");
console.log(JSON.stringify(config, null, 2));
console.log("\nTask bars (set threshold and step in taskProfiles):");
const bars = fitTaskBars(cases, runs, scoreOf);
for (const [task, bar] of Object.entries(bars)) {
  console.log(
    `${task}: threshold ${bar.threshold}, step ${bar.step} ` +
      `(per difficulty ${JSON.stringify(bar.perDifficulty)}; now ` +
      `${taskProfiles[task as Task].threshold}/${taskProfiles[task as Task].step})`,
  );
}
const failed = runs.filter((run) => run.error);
if (failed.length > 0) console.log(`\n${failed.length} runs failed; their score counts as 0.`);
