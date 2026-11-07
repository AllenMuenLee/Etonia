import { strict as assert } from "node:assert";
import {
  isPlaceholderPng,
  studyDifficulty,
  studyOutputCeiling,
  studyQualification,
  studyQuestion,
  studyQuestionKind,
  usableStudyResponse,
} from "../functions/_shared/study_policy.ts";
import type { StudyRouteCalibration } from "../functions/_shared/study_calibration.ts";
import type { AiInput } from "../functions/_shared/ai_policy.ts";
import {
  buildCatalog,
  escalate,
  route,
  type RouteContext,
} from "../functions/_shared/ai_router.ts";
import type { ModelConfig } from "../functions/_shared/ai_policy.ts";

const input: AiInput = {
  requestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  model: "auto",
  systemInstruction: "Tutor",
  prompt: '[Source N1:P1:C1 | Note: "Source", Page 1]\nEvidence\n\nQuestion: What is a latch?',
  selectedImage:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg==",
  responseFormat: "text",
};

Deno.test("classify only the current question, not keywords in unrelated source text", () => {
  const prompt = "Notes about differential equations and proofs.\n\nQuestion: What is a latch?";
  assert.equal(studyQuestion(prompt), "What is a latch?");
  assert.equal(studyQuestionKind(prompt), "definition");
  assert.equal(studyDifficulty("study.answer", { ...input, prompt }, 1), 1);
  assert.equal(
    studyDifficulty("study.answer", { ...input, prompt, studyPolicyVersion: "study-cost-b1" }, 1),
    2,
  );
  assert.equal(
    studyDifficulty("study.answer", {
      ...input,
      prompt: "Calculate 12 / 4.",
      studyPolicyVersion: "study-cost-b1",
    }, 1),
    1,
  );
  assert.equal(studyQuestionKind("Calculate 12 / 4."), "calculation");
  assert.equal(studyQuestionKind("According to my notes, what is the reset code?"), "sourceLookup");
  assert.equal(studyQuestionKind("Let's chat."), undefined);
  assert.equal(
    studyQuestionKind("Calculate 12 / 4.", [{ role: "user", text: "Prior conditions" }]),
    undefined,
  );
  assert.equal(
    studyQuestionKind("[Source N1:P1:C1 | Note]\nEvidence\n\nQuestion: Calculate its value."),
    undefined,
  );
});

Deno.test("proofs, diagrams, handwriting and active lessons cannot be cheaply misclassified", () => {
  for (
    const prompt of [
      "Prove the theorem.",
      "Derive the Fourier transform.",
      "证明这个定理",
      "Solve a differential equation.",
    ]
  ) {
    assert.equal(studyDifficulty("study.answer", { ...input, prompt }, 1), 3);
  }
  assert.equal(studyDifficulty("study.answer", input, 1, true), 3);
  assert.equal(studyDifficulty("study.answer", input, 1, false, true), 3);
  assert.equal(
    studyDifficulty("study.answer", {
      ...input,
      prompt: 'Lesson planning data\n{"plan":{"stage":"learning"}}\n\nQuestion: next',
    }, 1),
    3,
  );
});

Deno.test("only exact models and held-out qualified text groups get cheaper routes", () => {
  const profile: StudyRouteCalibration[] = [{
    policyVersion: "study-cost-b1",
    model: "gpt-6-luna",
    task: "study.answer",
    kind: "definition",
    difficulty: 1,
    effort: "low",
    score: 55,
    outputTokens: 700,
    calibrationCases: 10,
    holdoutCases: 10,
    calibrationFailures: 0,
    holdoutFailures: 0,
    caseDigest: "a".repeat(64),
  }];
  const hints = {
    difficulty: 1,
    studyQuestionKind: "definition" as const,
    studyPolicyVersion: "study-cost-b1",
  };
  assert(studyQualification("gpt-6-luna", "study.answer", "low", hints, profile));
  assert(!studyQualification("different-model", "study.answer", "low", hints, profile));
  assert(
    !studyQualification(
      "gpt-6-luna",
      "study.answer",
      "low",
      { ...hints, needsVision: true },
      profile,
    ),
  );
  assert(
    !studyQualification("gpt-6-luna", "study.answer", "low", { ...hints, difficulty: 3 }, profile),
  );
  for (
    const changed of [{ holdoutCases: 9 }, { holdoutFailures: 1 }, { calibrationFailures: 1 }, {
      caseDigest: "unknown",
    }]
  ) {
    assert(
      !studyQualification("gpt-6-luna", "study.answer", "low", hints, [{
        ...profile[0],
        ...changed,
      }]),
    );
  }
});

Deno.test("machine-checkable validation catches invented source identifiers and broken helper output", () => {
  assert(usableStudyResponse(input, "study.answer", "A latch holds data. [[N1:P1:C1]]"));
  assert(!usableStudyResponse(input, "study.answer", "Claim. [[N2:P1:C1]]"));
  assert(!usableStudyResponse(input, "study.answer", "Claim. [[N1:P1:C8]]"));
  const json = { ...input, responseFormat: "json" as const };
  assert(
    usableStudyResponse(json, "study.suggestions", '{"questions":["Why?","Example?","Next?"]}'),
  );
  assert(!usableStudyResponse(json, "study.suggestions", '{"questions":["Why?","why?","Next?"]}'));
  assert(!usableStudyResponse(json, "study.suggestions", '{"questions":["Why?"]}'));
  assert(!usableStudyResponse(json, "study.plan", '{"intent":"topic","plan":{"steps":[]}}'));
  assert(!usableStudyResponse(json, "study.plan", '{"intent":"question","difficulty":0}'));
  assert(usableStudyResponse(json, "study.plan", '{"intent":"question","difficulty":1}'));
});

Deno.test("helper ceilings preserve full high-effort and derivation output space", () => {
  assert.equal(studyOutputCeiling("study.suggestions", 16384, "low"), 2048);
  assert.equal(studyOutputCeiling("study.plan", 16384, "medium"), 8192);
  assert.equal(studyOutputCeiling("study.plan", 16384, "high"), 16384);
  assert.equal(studyOutputCeiling("study.answer", 16384, "low"), 16384);
  assert.equal(isPlaceholderPng(input.selectedImage), true);
});

Deno.test("frozen calculation profile routes cheaply and escalates within billing constraints", () => {
  const models: Record<string, ModelConfig> = {
    luna: {
      provider: "openai",
      model: "gpt-6-luna",
      inputMicroPerKilo: 100,
      outputMicroPerKilo: 500,
      maxOutputTokens: 16384,
    },
    sol: {
      provider: "openai",
      model: "gpt-6.1-sol",
      inputMicroPerKilo: 2000,
      outputMicroPerKilo: 10000,
      maxOutputTokens: 16384,
    },
  };
  const catalog = buildCatalog(models);
  const context: RouteContext = {
    task: "study.answer",
    setting: "auto",
    plan: "pro",
    creditsMicro: 1000000,
    hints: {
      inputTokens: 2000,
      difficulty: 2,
      studyQuestionKind: "calculation",
      studyPolicyVersion: "study-cost-b1",
    },
  };
  const automatic = route(catalog, context);
  assert(automatic.ok && automatic.alias === "luna");
  const first = route(catalog, { ...context, setting: "low" });
  assert(first.ok);
  assert.equal(first.alias, "luna");
  assert.equal(first.effort, "low");
  assert.equal(first.billing, "unlimited");
  const next = escalate(catalog, context, first);
  assert(next.ok);
  assert.equal(next.alias, "luna");
  assert.equal(next.effort, "medium");
  assert.equal(next.billing, "unlimited");
  for (
    const hints of [
      { ...context.hints, studyPolicyVersion: undefined },
      { ...context.hints, studyPolicyVersion: "future-version" },
      { ...context.hints, studyQuestionKind: "definition" as const },
      { ...context.hints, studyQuestionKind: "sourceLookup" as const },
      { ...context.hints, difficulty: 3 as const },
      { ...context.hints, needsVision: true },
      { ...context.hints, diagrams: true },
    ]
  ) {
    const decision = route(catalog, { ...context, hints });
    assert(decision.ok);
    assert.equal(decision.alias, "sol");
  }
  const renamed = buildCatalog({ ...models, luna: { ...models.luna, model: "new-luna" } });
  const renamedDecision = route(renamed, context);
  assert(renamedDecision.ok && renamedDecision.alias === "sol");
  const custom = buildCatalog(models, { luna: { scores: { reasoning: { low: 10 } } } });
  const customDecision = route(custom, context);
  assert(customDecision.ok && customDecision.alias === "sol");
  const disabled = route(catalog, { ...context, allowed: ["sol"] });
  assert(disabled.ok && disabled.alias === "sol");
  assert.deepEqual(route(catalog, { ...context, plan: "free", creditsMicro: 0 }), {
    ok: false,
    reason: "free_credit_exhausted",
  });
  assert.equal(studyQuestionKind("Calculate \u4e09 plus two."), undefined);
});
