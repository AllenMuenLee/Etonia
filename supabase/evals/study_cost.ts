/** Paid, bounded synthetic replay of the production provider request builder.
 * Run with --env-file=supabase/.env.local; never prints keys or answer bodies.
 * Captures contain synthetic fixtures only. Results are written locally.
 */
import {
  type AiInput,
  costOf,
  type ModelConfig,
  modelConfig,
  providerAnswer,
  type ProviderEffort,
  providerRequest,
  stepMessage,
} from "../functions/_shared/ai_policy.ts";
import { describePass } from "../functions/_shared/ai_usage.ts";

const flag = (name: string, fallback: string) => {
  const i = Deno.args.indexOf(`--${name}`);
  return i < 0 ? fallback : Deno.args[i + 1];
};
const phase = flag("phase", "A");
const only = flag("only", "both");
const directory = "build/study_desk_cost_audit";
const baseline = JSON.parse(await Deno.readTextFile(`${directory}/captured_requests.json`));
const optimized = JSON.parse(
  await Deno.readTextFile(flag("captures", `${directory}/captured_requests_${phase}.json`)),
);
const catalog = JSON.parse(Deno.env.get("AI_MODEL_CONFIG") ?? "{}");
const keys = { openai: "OPENAI_API_KEY", claude: "ANTHROPIC_API_KEY", gemini: "GEMINI_API_KEY" };
const blankPng =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg==";
const results: Record<string, any>[] = [];
const ceilingMicro = Number(flag("budget-usd", "2")) * 1e6;
let spent = 0;

async function ask(
  capture: any,
  variant: string,
  alias: string,
  effort: ProviderEffort,
  warmup = false,
  prompt = capture.prompt,
) {
  if (spent >= ceilingMicro) throw new Error("evaluation budget reached");
  const configured = modelConfig(catalog, alias);
  const model: ModelConfig = variant === "baseline"
    ? { ...configured, cacheMode: "implicit" }
    : configured;
  const input: AiInput = {
    requestId: crypto.randomUUID(),
    model: alias,
    selectedImage: blankPng,
    systemInstruction: capture.systemInstruction,
    prompt,
    history: capture.history,
    ...(variant === "baseline" ? {} : { responseFormat: capture.responseFormat }),
  };
  const request = providerRequest(
    model,
    input,
    4096,
    Deno.env.get(keys[model.provider]) ?? "",
    undefined,
    effort,
  );
  const start = Date.now();
  const response = await fetch(request.url, {
    method: "POST",
    headers: { ...request.headers, "Content-Type": "application/json" },
    body: JSON.stringify(request.body),
    signal: AbortSignal.timeout(150000),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(
      `${variant}/${capture.fixture}/${capture.task}: provider HTTP ${response.status}`,
    );
  }
  const raw = await response.json();
  const usage = providerAnswer(model, raw);
  const cost = costOf(model, usage.input, usage.output, usage.cached, usage.cacheWrites);
  spent += cost;
  const answer = variant === "baseline" ? stepMessage(usage.answer) : usage.answer.trim();
  const pass = describePass(alias, model, effort, "answer", usage);
  const result = {
    phase,
    variant,
    fixture: capture.fixture,
    task: capture.task,
    warmup,
    latencyMs: Date.now() - start,
    finishReason: usage.finishReason,
    ...pass,
    answer,
  };
  results.push(result);
  console.log(
    JSON.stringify({
      variant,
      fixture: capture.fixture,
      task: capture.task,
      warmup,
      input: usage.input,
      output: usage.output,
      cached: usage.cached,
      cacheWrites: usage.cacheWrites,
      costMicro: cost,
    }),
  );
  await Deno.writeTextFile(
    flag("out", `${directory}/phase_${phase}_live.json`),
    JSON.stringify(results, null, 2),
  );
  return answer;
}

for (const [variant, captures] of [["baseline", baseline], [phase, optimized]] as const) {
  if (only !== "both" && only !== variant) continue;
  const fixtures = [...new Set(captures.map((c: any) => c.fixture))];
  for (const fixture of fixtures) {
    const rows = captures.filter((c: any) => c.fixture === fixture);
    const planner = rows.find((c: any) => c.task === "study.plan");
    const tutor = rows.find((c: any) => c.task === "study.answer");
    const suggestions = rows.find((c: any) => c.task === "study.suggestions");
    if (planner) await ask(planner, variant, "luna", "low");
    const answer = await ask(tutor, variant, "sol", "low");
    if (suggestions) {
      const context = JSON.parse(suggestions.prompt);
      context.answer = answer.length > 7000 ? answer.slice(0, 7000) : answer;
      await ask(suggestions, variant, "luna", "low", false, JSON.stringify(context));
    }
    if (fixture === fixtures[0]) await ask(tutor, variant, "sol", "low", true);
  }
}
for (const variant of ["baseline", phase]) {
  const measured = results.filter((r) => r.variant === variant && !r.warmup);
  console.log(
    JSON.stringify({
      variant,
      requests: measured.length,
      inputCostMicro: measured.reduce((sum, r) => sum + r.inputCostMicro, 0),
      outputCostMicro: measured.reduce((sum, r) => sum + r.outputCostMicro, 0),
      costMicro: measured.reduce((sum, r) => sum + r.costMicro, 0),
      cachedTokens: measured.reduce((sum, r) => sum + r.cachedTokens, 0),
      cacheWriteTokens: measured.reduce((sum, r) => sum + r.cacheWriteTokens, 0),
    }),
  );
}
console.log(`total evaluation cost: $${(spent / 1e6).toFixed(6)}`);
