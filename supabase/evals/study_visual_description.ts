/** Paid synthetic transcription smoke. No app ledger writes. Budget $0.10. */
import {
  type AiInput,
  modelConfig,
  providerAnswer,
  providerRequest,
} from "../functions/_shared/ai_policy.ts";
import { buildCatalog, route } from "../functions/_shared/ai_router.ts";
import { describePass } from "../functions/_shared/ai_usage.ts";
import { usableStudyResponse } from "../functions/_shared/study_policy.ts";
const folder = "build/study_desk_cost_audit/visual_fixtures";
const fixtures = JSON.parse(await Deno.readTextFile(`${folder}/requests.json`));
const models = JSON.parse(Deno.env.get("AI_MODEL_CONFIG") ?? "{}");
const results: any[] = [];
let spent = 0;
for (const fixture of fixtures) {
  const bytes = await Deno.readFile(fixture.imagePath);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  const input: AiInput = {
    requestId: crypto.randomUUID(),
    model: "auto",
    responseFormat: "json",
    selectedImage: btoa(binary),
    systemInstruction: fixture.systemInstruction,
    prompt: JSON.stringify({
      panelCount: fixture.panelCount,
      layout: fixture.panelCount === 1 ? "Panel A" : "Panels A, B stacked top to bottom",
      request: "Describe all visible evidence in every panel, including uncertainties.",
    }),
  };
  const decision = route(buildCatalog(models), {
    task: "study.describe",
    setting: "medium",
    plan: "free",
    creditsMicro: 1000000,
    hints: { inputTokens: 10000, needsVision: true, difficulty: 3 },
  });
  if (!decision.ok) throw new Error("no_visual_reader");
  const model = modelConfig(models, decision.alias);
  const bound = (20000 * Math.max(model.inputMicroPerKilo, model.cacheWriteMicroPerKilo ?? 0) +
    4096 * model.outputMicroPerKilo) / 1000;
  if (spent + bound > 100000) throw new Error("smoke_budget_exceeded");
  const key = Deno.env.get(
    {
      openai: "OPENAI_API_KEY",
      claude: "ANTHROPIC_API_KEY",
      gemini: "GEMINI_API_KEY",
    }[model.provider],
  ) ?? "";
  const request = providerRequest(
    model,
    input,
    Math.min(4096, model.maxOutputTokens),
    key,
    undefined,
    decision.effort,
  );
  const response = await fetch(request.url, {
    method: "POST",
    headers: { ...request.headers, "Content-Type": "application/json" },
    body: JSON.stringify(request.body),
    signal: AbortSignal.timeout(90000),
  });
  if (!response.ok) {
    await response.body?.cancel();
    throw new Error(`provider_http_${response.status}`);
  }
  const usage = providerAnswer(model, await response.json());
  const pass = describePass(decision.alias, model, decision.effort, "answer", usage);
  spent += pass.costMicro;
  const structure = usableStudyResponse(input, "study.describe", usage.answer) &&
    !["length", "max_tokens"].includes(usage.finishReason ?? "");
  const value = structure
    ? JSON.parse(usage.answer.trim().replace(/^```(?:json)?\s*|\s*```$/g, ""))
    : null;
  const normalized = (text: string) =>
    text.replace(/\\[a-zA-Z]+/g, " ").replace(/[{}$\\]/g, "").replace(/\s+/g, " ");
  const panels = value?.panels?.map((p: any) => normalized(p.description)) ?? [];
  const units = (text: string) =>
    /12/.test(text) && /4/.test(text) && /0\.003/.test(text) && /3\s*mA/i.test(text) &&
    /not\s*3\s*A/i.test(text);
  const domain = (text: string) =>
    /x\s*>\s*3/.test(text) && /-\s*1/.test(text) && /reject/i.test(text) && /positive/i.test(text);
  const passed = structure &&
    (fixture.id === "units"
      ? units(panels[0])
      : fixture.id === "domain"
      ? domain(panels[0])
      : units(panels[0]) && domain(panels[1]));
  results.push({ id: fixture.id, ...pass, passed, answer: usage.answer });
  await Deno.writeTextFile(`${folder}/results.json`, JSON.stringify(results, null, 2));
  console.log(
    JSON.stringify({
      id: fixture.id,
      model: decision.alias,
      effort: decision.effort,
      passed,
      costMicro: pass.costMicro,
    }),
  );
}
await Deno.writeTextFile(
  "tool/study_desk_cost/visual_description_results.json",
  JSON.stringify(
    {
      scope:
        "Three synthetic images; no learner data or app credit charges. Tests transcription, not general visual reasoning.",
      cases: results.length,
      passed: results.filter((r) => r.passed).length,
      costMicro: spent,
      results: results.map(({ answer, ...row }) => row),
    },
    null,
    2,
  ) + "\n",
);
if (results.some((row) => !row.passed)) Deno.exit(1);
