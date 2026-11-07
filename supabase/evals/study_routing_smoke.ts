/** Paid synthetic turn replay using the real router, planner verdict and validators.
 * Compares B with its calibration disabled/enabled; no production data or ledger writes.
 */
import {
  type AiInput,
  modelConfig,
  providerAnswer,
  providerRequest,
} from "../functions/_shared/ai_policy.ts";
import {
  buildCatalog,
  escalate,
  estimateInputTokens,
  route,
  type RouteContext,
  type Task,
} from "../functions/_shared/ai_router.ts";
import { describePass } from "../functions/_shared/ai_usage.ts";
import {
  studyDifficulty,
  studyOutputCeiling,
  studyQuestionKind,
  usableStudyResponse,
} from "../functions/_shared/study_policy.ts";

const directory = "build/study_desk_cost_audit";
const captures = JSON.parse(
  await Deno.readTextFile(`${directory}/captured_smoke_B.json`),
);
const configured = JSON.parse(Deno.env.get("AI_MODEL_CONFIG") ?? "{}");
const overrides = JSON.parse(Deno.env.get("AI_ROUTER_CONFIG") ?? "{}");
const keys = {
  openai: "OPENAI_API_KEY",
  claude: "ANTHROPIC_API_KEY",
  gemini: "GEMINI_API_KEY",
};
const png =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg==";
const results: Record<string, any>[] = [];
let spent = 0;
for (const variant of ["uncalibrated", "B"]) {
  const catalog = buildCatalog(configured, overrides).map((m) =>
    variant === "uncalibrated" ? { ...m, studyCalibration: false } : m
  );
  for (const fixture of [...new Set(captures.map((r: any) => r.fixture))]) {
    const rows = captures.filter((r: any) => r.fixture === fixture);
    let difficulty: 1 | 2 | 3 | undefined;
    let tutorAnswer = "";
    for (const capture of rows) {
      const task = capture.task as Task;
      let prompt = capture.prompt;
      if (task === "study.suggestions") {
        const value = JSON.parse(prompt);
        value.answer = tutorAnswer.slice(0, 7000);
        prompt = JSON.stringify(value);
      }
      const input: AiInput = {
        requestId: crypto.randomUUID(),
        model: "auto",
        prompt,
        systemInstruction: capture.systemInstruction,
        history: capture.history,
        responseFormat: capture.responseFormat,
        studyPolicyVersion: capture.studyPolicyVersion,
        selectedImage: png,
      };
      const context: RouteContext = {
        task,
        setting: capture.routing.effort ?? "auto",
        plan: "pro",
        creditsMicro: 1000000,
        allowed: capture.routing.allowed,
        hints: {
          difficulty: studyDifficulty(
            task,
            input,
            task === "study.answer"
              ? difficulty ?? capture.routing.difficulty ?? 2
              : capture.routing.difficulty ?? 2,
          ),
          studyQuestionKind: studyQuestionKind(prompt, input.history),
          studyPolicyVersion: input.studyPolicyVersion,
          inputTokens: estimateInputTokens([
            prompt,
            input.systemInstruction,
            JSON.stringify(input.history ?? []),
          ], 0) + 64,
          cacheablePrefixTokens: estimateInputTokens([
            input.systemInstruction,
            JSON.stringify(input.history ?? []),
          ], 0),
        },
      };
      let decision = route(catalog, context);
      let valid = false;
      let answer = "";
      for (let attempt = 0; attempt < 3; attempt++) {
        if (!decision.ok) throw new Error(`No route ${decision.reason}`);
        const model = modelConfig(configured, decision.alias);
        const cap = studyOutputCeiling(
          task,
          model.maxOutputTokens,
          decision.effort,
        );
        const bound = (context.hints.inputTokens *
            Math.max(
              model.inputMicroPerKilo,
              model.cacheWriteMicroPerKilo ?? 0,
            ) + cap * model.outputMicroPerKilo) / 1000;
        if (spent + bound > 2000000) throw new Error("smoke_budget_reached");
        const request = providerRequest(
          model,
          input,
          cap,
          Deno.env.get(keys[model.provider]) ?? "",
          undefined,
          decision.effort,
        );
        const response = await fetch(request.url, {
          method: "POST",
          headers: { ...request.headers, "Content-Type": "application/json" },
          body: JSON.stringify(request.body),
          signal: AbortSignal.timeout(150000),
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
        answer = usage.answer.trim();
        valid = !["length", "MAX_TOKENS"].includes(usage.finishReason ?? "") &&
          !!answer && usableStudyResponse(input, task, answer);
        results.push({
          fixture,
          variant,
          task,
          attempt,
          ...pass,
          valid,
          answer,
        });
        await Deno.writeTextFile(
          `${directory}/routing_smoke_B.json`,
          JSON.stringify(results, null, 2),
        );
        console.log(
          JSON.stringify({
            fixture,
            variant,
            task,
            alias: decision.alias,
            effort: decision.effort,
            valid,
            costMicro: pass.costMicro,
          }),
        );
        if (valid) break;
        decision = escalate(catalog, context, decision);
      }
      if (!valid) throw new Error("smoke_invalid_response");
      if (task === "study.plan") difficulty = JSON.parse(answer).difficulty;
      if (task === "study.answer") tutorAnswer = answer;
    }
  }
}
const summaries = ["uncalibrated", "B"].map((variant) => ({
  variant,
  calls: results.filter((r) => r.variant === variant).length,
  costMicro: results.filter((r) => r.variant === variant).reduce(
    (n, r) => n + r.costMicro,
    0,
  ),
  valid: results.filter((r) => r.variant === variant).every((r) => r.valid),
}));
await Deno.writeTextFile(
  "tool/study_desk_cost/phase_B_smoke_results.json",
  JSON.stringify(
    {
      scope:
        "Six synthetic turns; real planner and router; same B transport/context; calibration off versus on; includes all helpers and retries.",
      summaries,
      spendMicro: spent,
    },
    null,
    2,
  ) + "\n",
);
