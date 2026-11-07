/**
 * Runs the eval cases against real models and writes what each (model, effort)
 * scored, its cost and its speed. `fit.ts` turns the results into router data.
 *
 *   deno run --allow-env --allow-net --allow-read --allow-write \
 *     supabase/evals/run.ts [--models haiku,sol] [--efforts low,medium,high] \
 *     [--tasks study.answer,study.plan] [--judge sol] [--out results.json]
 *
 * Reads `AI_MODEL_CONFIG` and the provider keys from the environment, the same
 * as the `ai` function. Cases are sent as they are: nothing here is a user's.
 * It spends real money; run it with `--tasks` and `--models` while you iterate.
 */
import {
  aliases,
  costOf,
  type ModelConfig,
  modelConfig,
  providerAnswer,
  providerRequest,
} from "../functions/_shared/ai_policy.ts";
import { type Effort, efforts, tasks } from "../functions/_shared/ai_router.ts";
import { type EvalCase, type EvalRun, judgeScore, scoreAnswer } from "./lib.ts";

const keys = { openai: "OPENAI_API_KEY", claude: "ANTHROPIC_API_KEY", gemini: "GEMINI_API_KEY" };
/** A one-pixel PNG, for the cases that have no picture of their own. */
const blankPng =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg==";

function flag(name: string): string | undefined {
  const at = Deno.args.indexOf(`--${name}`);
  return at < 0 ? undefined : Deno.args[at + 1];
}

function list(name: string): string[] | undefined {
  return flag(name)?.split(",").map((part) => part.trim()).filter(Boolean);
}

async function loadCases(only: string[] | undefined): Promise<EvalCase[]> {
  const folder = new URL("./cases/", import.meta.url);
  const cases: EvalCase[] = [];
  for await (const entry of Deno.readDir(folder)) {
    if (!entry.name.endsWith(".json")) continue;
    const parsed = JSON.parse(await Deno.readTextFile(new URL(entry.name, folder)));
    for (const evalCase of parsed as EvalCase[]) {
      if (!(tasks as readonly string[]).includes(evalCase.task)) {
        throw new Error(`${evalCase.id}: unknown task ${evalCase.task}`);
      }
      if (!only || only.includes(evalCase.task)) cases.push(evalCase);
    }
  }
  return cases;
}

async function pictureOf(evalCase: EvalCase): Promise<string> {
  if (!evalCase.image) return blankPng;
  const bytes = await Deno.readFile(new URL(`./cases/${evalCase.image}`, import.meta.url));
  return btoa(String.fromCharCode(...bytes));
}

async function ask(
  model: ModelConfig,
  prompt: string,
  system: string,
  image: string,
  effort: Effort,
) {
  const started = Date.now();
  const sent = providerRequest(
    model,
    {
      requestId: crypto.randomUUID(),
      model: "auto",
      prompt,
      systemInstruction: system,
      selectedImage: image,
    },
    Math.min(model.maxOutputTokens, 8192),
    Deno.env.get(keys[model.provider]) ?? "",
    undefined,
    effort,
  );
  const response = await fetch(sent.url, {
    method: "POST",
    headers: { ...sent.headers, "Content-Type": "application/json" },
    body: JSON.stringify(sent.body),
    signal: AbortSignal.timeout(180000),
  });
  if (!response.ok) throw new Error(`provider answered ${response.status}`);
  const answer = providerAnswer(model, await response.json());
  if (typeof answer.answer !== "string" || !answer.answer.trim()) throw new Error("empty answer");
  return {
    text: answer.answer,
    cost: costOf(model, answer.input ?? 0, answer.output ?? 0, answer.cached, answer.cacheWrites),
    latencyMs: Date.now() - started,
  };
}

const catalog = JSON.parse(Deno.env.get("AI_MODEL_CONFIG") ?? "{}");
const wanted = list("models") ?? aliases;
const wantedEfforts = (list("efforts") ?? [...efforts]) as Effort[];
const judgeAlias = flag("judge");
const cases = await loadCases(list("tasks"));
const runs: EvalRun[] = [];

for (const alias of wanted) {
  let model: ModelConfig;
  try {
    model = modelConfig(catalog, alias);
  } catch {
    console.warn(`skipping ${alias}: not configured`);
    continue;
  }
  for (const effort of wantedEfforts) {
    for (const evalCase of cases) {
      const system = evalCase.system ??
        "You are a careful study assistant. Answer exactly what is asked.";
      try {
        const answered = await ask(
          model,
          evalCase.prompt,
          system,
          await pictureOf(evalCase),
          effort,
        );
        let score: number;
        if (evalCase.check.type === "judge") {
          if (!judgeAlias) throw new Error("a judge check needs --judge <model>");
          const judge = await ask(
            modelConfig(catalog, judgeAlias),
            `Rubric: ${evalCase.check.rubric}\n\nQuestion: ${evalCase.prompt}\n\nAnswer to ` +
              `grade:\n${answered.text}\n\nReply with one number from 0 to 10 and nothing else.`,
            "You grade answers strictly against a rubric.",
            blankPng,
            "low",
          );
          score = judgeScore(judge.text);
        } else {
          score = scoreAnswer(evalCase.check, answered.text);
        }
        runs.push({
          caseId: evalCase.id,
          alias,
          effort,
          score,
          costMicro: answered.cost,
          latencyMs: answered.latencyMs,
        });
      } catch (error) {
        runs.push({
          caseId: evalCase.id,
          alias,
          effort,
          score: 0,
          costMicro: 0,
          latencyMs: 0,
          error: error instanceof Error ? error.message : String(error),
        });
      }
      console.log(`${alias}/${effort} ${evalCase.id}: ${runs[runs.length - 1].score}`);
    }
  }
}

const out = flag("out") ?? `supabase/evals/results/${new Date().toISOString().slice(0, 10)}.json`;
await Deno.mkdir(out.slice(0, Math.max(0, out.lastIndexOf("/"))) || ".", { recursive: true });
await Deno.writeTextFile(out, JSON.stringify({ cases, runs }, null, 2));
console.log(`wrote ${runs.length} runs to ${out}`);
