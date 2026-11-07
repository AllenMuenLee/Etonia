/** Small synthetic behavior smoke, not a new model-quality qualification.
 * Direct provider calls never touch an app user's credit ledger. Budget: $0.10.
 */
import {
  type AiInput,
  modelConfig,
  providerAnswer,
  providerRequest,
} from "../functions/_shared/ai_policy.ts";
import { buildCatalog, estimateInputTokens, route } from "../functions/_shared/ai_router.ts";
import { describePass } from "../functions/_shared/ai_usage.ts";
const folder = "build/study_desk_cost_audit";
const capture = JSON.parse(
  await Deno.readTextFile(`${folder}/captured_requests_gate.json`),
)
  .find((r: any) => r.task === "study.plan");
const configuration = JSON.parse(Deno.env.get("AI_MODEL_CONFIG") ?? "{}");
const catalogue = buildCatalog(configuration);
const blank =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg==";
const availability =
  'Available notes (titles/page counts only; not source evidence):\n{"title":"Physics","pages":30}\n\n' +
  "Mistake topic index (availability only, not confirmed relevance):\n" +
  JSON.stringify([
    {
      index: 1,
      topic: "Linear equations",
      question: "Solve -2x = 4.",
      errorHint:
        "Chose x=2 instead of x=-2: lost the negative sign when dividing by a negative coefficient.",
      studentAnswer: "x=2",
      unanswered: false,
    },
    {
      index: 2,
      topic: "Heat capacity",
      question: "Define specific heat capacity.",
      errorHint: "Confused energy with energy per unit mass per degree.",
      studentAnswer: "energy",
      unanswered: false,
    },
  ]) + "\n\n";
const fixtures = [
  { id: "greeting", question: "Hello!", notes: false, mistakes: [] },
  {
    id: "arithmetic",
    question: "Calculate 17 + 28.",
    notes: false,
    mistakes: [],
  },
  {
    id: "general-definition",
    question: "Explain Newton's second law using general knowledge, independently of my notes.",
    notes: false,
    mistakes: [],
  },
  {
    id: "formatting",
    question: "Make your previous explanation one sentence.",
    notes: false,
    mistakes: [],
    history: true,
  },
  {
    id: "conversation-followup",
    question: "Why does twice the force give twice the acceleration in your example?",
    notes: false,
    mistakes: [],
    history: true,
  },
  {
    id: "explicit-note-connection",
    question: "Teach Newton's second law and connect it to the worked example in my Physics notes.",
    notes: true,
    mistakes: [],
  },
  {
    id: "specific-note-review",
    question: "Explain the force diagram on page 3 of my Physics notes.",
    notes: true,
    mistakes: [],
  },
  {
    id: "exact-past-error",
    question: "Solve -2x = 4.",
    notes: false,
    mistakes: [1],
  },
  {
    id: "shared-error-mechanism",
    question: "Solve -3x = 6 and help me avoid my earlier sign error.",
    notes: false,
    mistakes: [1],
  },
  {
    id: "broad-topic-not-a-match",
    question: "What is an equation? Just define the term.",
    notes: false,
    mistakes: [],
  },
  {
    id: "independent-topic",
    question: "Teach me photosynthesis from the basics, independently of my notes.",
    notes: false,
    mistakes: [],
  },
  {
    id: "completed-test-review",
    question: "Explain why my answer to question 1 was marked wrong in my completed test.",
    notes: true,
    mistakes: [],
    test: true,
  },
];
const results: any[] = [];
let spent = 0;
const parseGate = (answer: string) =>
  JSON.parse(answer.trim().replace(/^```(?:json)?\s*|\s*```$/g, ""));
for (const fixture of Deno.args.includes("--rescore") ? [] : fixtures) {
  const prompt =
    (fixture.test ? "Available source: one completed graded test.\n\n" : availability) +
    `Question: ${fixture.question}`;
  const input: AiInput = {
    requestId: crypto.randomUUID(),
    model: "auto",
    selectedImage: blank,
    systemInstruction: capture.systemInstruction,
    prompt,
    responseFormat: "json",
    history: fixture.history
      ? [{ role: "user", content: "Explain force and acceleration." }, {
        role: "assistant",
        content:
          "At constant mass, acceleration equals force divided by mass. Twice the force produces twice the acceleration.",
      }]
      : [],
  };
  const decision = route(catalogue, {
    task: "study.plan",
    setting: "auto",
    plan: "free",
    creditsMicro: 1000000,
    hints: {
      inputTokens: estimateInputTokens([
        input.systemInstruction,
        prompt,
        JSON.stringify(input.history),
      ], 0) + 64,
      difficulty: 2,
    },
  });
  if (!decision.ok) {
    throw new Error("No gate route");
  }
  const model = modelConfig(configuration, decision.alias);
  const cap = Math.min(8192, model.maxOutputTokens);
  const bound = (new TextEncoder().encode(JSON.stringify(input)).length *
      Math.max(model.inputMicroPerKilo, model.cacheWriteMicroPerKilo ?? 0) +
    cap * model.outputMicroPerKilo) / 1000;
  if (spent + bound > 100000) {
    throw new Error("synthetic_gate_budget_reached");
  }
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
    cap,
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
  const pass = describePass(
    decision.alias,
    model,
    decision.effort,
    "answer",
    usage,
  );
  spent += pass.costMicro;
  let value: any;
  try {
    value = parseGate(usage.answer);
  } catch {
    value = null;
  }
  const retrieval = value?.retrieval;
  const actualMistakes = Array.isArray(retrieval?.mistakeIndices)
    ? [...retrieval.mistakeIndices].sort()
    : null;
  const success = retrieval?.notes === fixture.notes &&
    JSON.stringify(actualMistakes) === JSON.stringify(fixture.mistakes) &&
    typeof retrieval?.query === "string" && retrieval.query.length <= 300 &&
    (fixture.notes || retrieval.query === "") &&
    !["length", "max_tokens"].includes(usage.finishReason ?? "");
  results.push({
    id: fixture.id,
    pass: success,
    ...pass,
    passed: success,
    retrieval,
    answer: usage.answer,
  });
  await Deno.writeTextFile(
    `${folder}/retrieval_gate_live.json`,
    JSON.stringify(results, null, 2),
  );
  console.log(
    JSON.stringify({
      id: fixture.id,
      passed: success,
      model: decision.alias,
      effort: decision.effort,
      costMicro: pass.costMicro,
    }),
  );
}
// Production accepts a fenced JSON object. Re-score saved responses without
// spending again when only the smoke's parser (not the policy) was corrected.
if (Deno.args.includes("--rescore")) {
  const saved = JSON.parse(
    await Deno.readTextFile(`${folder}/retrieval_gate_live.json`),
  );
  for (const fixture of fixtures) {
    const row = saved.find((r: any) => r.id === fixture.id);
    if (!row) throw new Error("missing_saved_case");
    let retrieval: any;
    try {
      retrieval = parseGate(row.answer)?.retrieval;
    } catch {
      retrieval = null;
    }
    const actual = Array.isArray(retrieval?.mistakeIndices)
      ? [...retrieval.mistakeIndices].sort()
      : null;
    const passed = retrieval?.notes === fixture.notes &&
      JSON.stringify(actual) === JSON.stringify(fixture.mistakes) &&
      typeof retrieval?.query === "string" && retrieval.query.length <= 300 &&
      (fixture.notes || retrieval.query === "");
    results.push({ ...row, passed, retrieval });
    spent += row.costMicro;
  }
}
await Deno.writeTextFile(
  "tool/study_desk_cost/retrieval_gate_results.json",
  JSON.stringify(
    {
      scope:
        "Twelve synthetic current-policy gate behaviors, actual auto route; no production learner data or app credit charges; not a model qualification.",
      cases: results.length,
      passed: results.filter((r) => r.passed).length,
      costMicro: spent,
      results: results.map((r) => ({
        id: r.id,
        passed: r.passed,
        model: r.model,
        effort: r.effort,
        inputTokens: r.inputTokens,
        outputTokens: r.outputTokens,
        costMicro: r.costMicro,
      })),
    },
    null,
    2,
  ) + "\n",
);
