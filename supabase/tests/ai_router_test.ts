import { strict as assert } from "node:assert";
import type { ModelConfig } from "../functions/_shared/ai_policy.ts";
import {
  buildCatalog,
  type Decision,
  type Denied,
  type Effort,
  efforts,
  escalate,
  estimateCost,
  estimateInputTokens,
  failureCode,
  isUnlimited,
  parseRoutingRequest,
  planFromState,
  providerEffort,
  route,
  type RouteContext,
  type RouterModel,
  type Tier,
} from "../functions/_shared/ai_router.ts";
import { Failure } from "../functions/_shared/common.ts";

const prices: Record<Tier, [number, number]> = {
  unlimited: [100, 500],
  standard: [2000, 10000],
  frontier: [4000, 20000],
};

/** A model whose every capability scores the same, per effort. */
function model(
  alias: string,
  provider: ModelConfig["provider"],
  tier: Tier,
  scores: Record<Effort, number>,
  extra: Partial<ModelConfig> = {},
  latencyRank = tier === "unlimited" ? 1 : tier === "standard" ? 2 : 3,
): RouterModel {
  const [input, output] = prices[tier];
  const row = (): Record<Effort, number> => ({ ...scores });
  return {
    alias,
    tier,
    latencyRank,
    contextTokens: 200000,
    vision: true,
    config: {
      provider,
      model: `${alias}-id`,
      inputMicroPerKilo: input,
      outputMicroPerKilo: output,
      maxOutputTokens: 16384,
      ...extra,
    },
    scores: {
      reasoning: row(),
      vision: row(),
      diagrams: row(),
      structured: row(),
      drawing: row(),
    },
  };
}

const catalog = (): RouterModel[] => [
  model("haiku", "claude", "unlimited", { low: 40, medium: 52, high: 62 }),
  model("luna", "openai", "unlimited", { low: 38, medium: 50, high: 60 }),
  model("sonnet", "claude", "standard", { low: 62, medium: 74, high: 82 }),
  model("sol", "openai", "standard", { low: 60, medium: 72, high: 80 }),
  model("opus", "claude", "frontier", { low: 78, medium: 88, high: 94 }),
  model("argon", "gemini", "frontier", { low: 76, medium: 86, high: 92 }),
];

const context = (over: Partial<RouteContext> = {}): RouteContext => ({
  task: "study.answer",
  setting: "auto",
  plan: "pro",
  creditsMicro: 5_000_000,
  hints: { inputTokens: 8000, difficulty: 2 },
  ...over,
});

Deno.test("Flash is a metered balanced Gemini model available on free credit and Starter", () => {
  const models = buildCatalog({
    flash: {
      provider: "gemini", model: "gemini-3.8-flash", inputMicroPerKilo: 750,
      cachedInputMicroPerKilo: 75, outputMicroPerKilo: 3750, maxOutputTokens: 16384,
    },
  });
  assert.equal(models.length, 1);
  assert.equal(models[0].tier, "standard");
  for (const plan of ["free", "starter", "pro", "max"] as const) {
    const chosen = decided(route(models, context({ plan, allowed: ["flash"] })));
    assert.equal(chosen.alias, "flash");
    assert.equal(chosen.provider, "gemini");
    assert.equal(chosen.billing, "metered");
  }
  const parsed = parseRoutingRequest({ allowedModels: ["flash"] });
  assert.deepEqual(parsed.allowed, ["flash"]);
  assert.equal(route(models, context({ allowed: ["sol"] })).ok, false);
});

function decided(result: Decision | Denied): Decision {
  assert.equal(result.ok, true, JSON.stringify(result));
  return result as Decision;
}

Deno.test("direct visual chat stays on its selected lightweight model on retries", () => {
  for (const alias of ["haiku", "luna"]) {
    const ctx = context({
      allowed: [alias],
      previous: { alias: "sol", ageMs: 0 },
      hints: { inputTokens: 12000, difficulty: 3, needsVision: true, diagrams: true },
    });
    const chosen = decided(route(catalog(), ctx));
    assert.equal(chosen.alias, alias);
    const retry = escalate(catalog(), ctx, chosen);
    if (retry.ok) assert.equal(retry.alias, alias);
    else assert.equal(retry.reason, "no_stronger_model");
    const outage = route(catalog(), { ...ctx, unhealthyProviders: [chosen.provider] });
    assert.equal(outage.ok, false);
  }
});

function denied(result: Decision | Denied): Denied {
  assert.equal(result.ok, false, JSON.stringify(result));
  return result as Denied;
}

Deno.test("auto picks the cheapest pair that is capable enough", () => {
  // Difficulty 2 needs 67: no unlimited pair reaches it, and Sonnet at medium is
  // the cheapest that does (Sol ties on price and loses on score).
  const pick = decided(route(catalog(), context()));
  assert.deepEqual([pick.alias, pick.effort, pick.capable], ["sonnet", "medium", true]);
  assert.equal(pick.billing, "metered");
});

Deno.test("visual descriptions stay on enabled lightweight vision models, including High settings", () => {
  const base = context({
    task: "study.describe",
    setting: "high",
    hints: { inputTokens: 5000, difficulty: 3, needsVision: true },
    plan: "free",
  });
  const pick = decided(route(catalog(), base));
  assert(["haiku", "luna"].includes(pick.alias));
  assert.notEqual(pick.effort, "high");
  assert.equal(pick.billing, "metered");
  assert(pick.capable);
  const luna = decided(route(catalog(), { ...base, allowed: ["luna", "sol"] }));
  assert.equal(luna.alias, "luna");
  assert.equal(
    denied(route(catalog(), { ...base, allowed: ["sol", "opus"] })).reason,
    "no_model_enabled",
  );
  const noVision = catalog().map((m) => ({ ...m, vision: false }));
  assert.equal(denied(route(noVision, base)).reason, "unsupported_input");
  assert.equal(
    denied(route(catalog(), { ...base, creditsMicro: 0 })).reason,
    "free_credit_exhausted",
  );
});

Deno.test("an easy task is answered by an unlimited model, free to a paid plan", () => {
  const pick = decided(route(catalog(), context({ task: "study.suggestions" })));
  assert.deepEqual([pick.alias, pick.effort, pick.billing], ["haiku", "low", "unlimited"]);
});

Deno.test("more thinking on a cheap model beats a bigger model with less", () => {
  const cheap = catalog();
  cheap[0] = model("haiku", "claude", "unlimited", { low: 40, medium: 52, high: 70 });
  const pick = decided(route(cheap, context()));
  assert.deepEqual([pick.alias, pick.effort], ["haiku", "high"]);
  // High effort is real money even on an unlimited model, so it is metered.
  assert.equal(pick.billing, "metered");
  assert.equal(isUnlimited("pro", cheap[0], "high"), false);
  assert.equal(isUnlimited("pro", cheap[0], "medium"), true);
  assert.equal(isUnlimited("free", cheap[0], "low"), false);
});

Deno.test("a fixed thinking level is the level used", () => {
  const low = decided(route(catalog(), context({ setting: "low" })));
  assert.equal(low.effort, "low");
  assert.equal(low.alias, "opus");
  const high = decided(route(catalog(), context({ setting: "high", task: "study.suggestions" })));
  assert.equal(high.effort, "high");
});

Deno.test("models the user turned off are never used", () => {
  const only = decided(route(catalog(), context({ allowed: ["sonnet"] })));
  assert.equal(only.alias, "sonnet");
  assert.equal(denied(route(catalog(), context({ allowed: [] }))).reason, "no_model_enabled");
  assert.equal(
    denied(route(catalog(), context({ plan: "starter", allowed: ["opus", "argon"] }))).reason,
    "plan_required",
  );
});

Deno.test("free and starter plans never reach frontier models", () => {
  for (const plan of ["free", "starter"] as const) {
    const pick = decided(route(
      catalog(),
      context({ plan, hints: { inputTokens: 8000, difficulty: 3 } }),
    ));
    assert.notEqual(pick.alias, "opus");
    assert.notEqual(pick.alias, "argon");
  }
});

Deno.test("a free plan with no credit left is refused", () => {
  const result = denied(route(catalog(), context({ plan: "free", creditsMicro: 0 })));
  assert.equal(result.reason, "free_credit_exhausted");
  assert.equal(failureCode(result.reason), "insufficient_credits");
});

Deno.test("a free plan with little credit left moves to what it can pay for", () => {
  const hard = { inputTokens: 8000, difficulty: 3 as const };
  const rich = decided(route(
    catalog(),
    context({ plan: "free", creditsMicro: 100_000, hints: hard }),
  ));
  assert.deepEqual([rich.alias, rich.effort, rich.capable], ["sonnet", "high", true]);
  const poor = decided(route(
    catalog(),
    context({ plan: "free", creditsMicro: 20_000, hints: hard }),
  ));
  // Sonnet no longer fits; it carries on with the strongest it can afford.
  assert.deepEqual([poor.alias, poor.billing, poor.capable], ["haiku", "metered", false]);
  assert.ok(poor.estimatedCost <= 20_000);
});

Deno.test("a paid plan out of credits carries on, silently, on a cheaper model", () => {
  const pick = decided(route(
    catalog(),
    context({ creditsMicro: 0, setting: "high", hints: { inputTokens: 8000, difficulty: 3 } }),
  ));
  // High was asked for; with no credit left it steps down to what is free.
  assert.deepEqual([pick.alias, pick.effort, pick.billing], ["haiku", "medium", "unlimited"]);
  const auto = decided(route(catalog(), context({ creditsMicro: 0 })));
  assert.equal(auto.billing, "unlimited");
  assert.notEqual(auto.effort, "high");
});

Deno.test("out of credits with the unlimited models turned off is a refusal", () => {
  const result = denied(route(
    catalog(),
    context({ creditsMicro: 0, allowed: ["sonnet", "opus"] }),
  ));
  assert.equal(result.reason, "insufficient_credits");
});

Deno.test("an unhealthy provider is routed around, across providers", () => {
  const pick = decided(route(catalog(), context({ unhealthyProviders: ["claude"] })));
  assert.deepEqual([pick.alias, pick.effort], ["sol", "medium"]);
  assert.equal(
    denied(route(catalog(), context({ unhealthyProviders: ["claude", "openai", "gemini"] })))
      .reason,
    "provider_unavailable",
  );
});

Deno.test("nothing capable: the strongest allowed answers, marked not capable", () => {
  const pick = decided(route(
    catalog(),
    context({ allowed: ["haiku", "luna"], hints: { inputTokens: 8000, difficulty: 3 } }),
  ));
  assert.deepEqual([pick.alias, pick.effort, pick.capable], ["haiku", "high", false]);
});

Deno.test("escalation goes strictly up, never back to a pair already tried", () => {
  const first = decided(route(catalog(), context()));
  const second = decided(escalate(catalog(), context(), first));
  assert.ok(second.score > first.score);
  assert.notDeepEqual([second.alias, second.effort], [first.alias, first.effort]);
  const third = decided(escalate(catalog(), context(), second));
  assert.ok(third.score > second.score);
  const top = decided(route(catalog(), context({ allowed: ["opus"], setting: "high" })));
  assert.equal(
    denied(escalate(catalog(), context({ allowed: ["opus"], setting: "high" }), top)).reason,
    "no_stronger_model",
  );
});

Deno.test("the model that answered last turn is kept unless another is clearly cheaper", () => {
  const near = catalog();
  near[3] = model("sol", "openai", "standard", { low: 60, medium: 72, high: 80 }, {
    inputMicroPerKilo: 1800,
    outputMicroPerKilo: 9000,
  });
  assert.equal(decided(route(near, context())).alias, "sol");
  assert.equal(
    decided(route(near, context({ previous: { alias: "sonnet", ageMs: 1000 } }))).alias,
    "sonnet",
  );
  const far = catalog();
  far[3] = model("sol", "openai", "standard", { low: 60, medium: 72, high: 80 }, {
    inputMicroPerKilo: 1000,
    outputMicroPerKilo: 5000,
  });
  assert.equal(
    decided(route(far, context({ previous: { alias: "sonnet", ageMs: 1000 } }))).alias,
    "sol",
  );
});

Deno.test("a warm prompt cache lowers the estimate only inside its lifetime", () => {
  const sol = model("sol", "openai", "standard", { low: 60, medium: 72, high: 80 }, {
    cachedInputMicroPerKilo: 200,
  });
  const hints = { inputTokens: 8000, cacheablePrefixTokens: 6000 };
  const cold = estimateCost(sol, "medium", "study.answer", hints, false);
  const warm = estimateCost(sol, "medium", "study.answer", hints, true);
  assert.ok(warm < cold);
  const aged = decided(route(
    [sol],
    context({ previous: { alias: "sol", ageMs: 10 * 60 * 1000 }, hints }),
  ));
  const fresh = decided(route(
    [sol],
    context({ previous: { alias: "sol", ageMs: 1000 }, hints }),
  ));
  assert.ok(fresh.estimatedCost < aged.estimatedCost);
});

Deno.test("a picture that must be read needs a model that can see", () => {
  const blind = catalog();
  blind[2] = { ...blind[2], vision: false };
  const pick = decided(route(
    blind,
    context({ task: "editor.answer", hints: { inputTokens: 8000, needsVision: true } }),
  ));
  assert.notEqual(pick.alias, "sonnet");
  const huge = denied(route(catalog(), context({ hints: { inputTokens: 900000 } })));
  assert.equal(huge.reason, "unsupported_input");
});

Deno.test("effort becomes each provider's own setting", () => {
  assert.deepEqual(providerEffort("openai", "high").body, { reasoning_effort: "high" });
  assert.deepEqual(providerEffort("claude", "low").body, {
    thinking: { type: "adaptive" },
    output_config: { effort: "low" },
  });
  assert.deepEqual(providerEffort("gemini", "medium").generationConfig, {
    thinkingConfig: { thinkingLevel: "MEDIUM" },
  });
});

Deno.test("the routing request is validated, never guessed at", () => {
  assert.deepEqual(parseRoutingRequest(undefined), { setting: "auto" });
  assert.deepEqual(
    parseRoutingRequest({ effort: "high", allowedModels: ["haiku", "haiku", "sol"] }),
    { setting: "high", allowed: ["haiku", "sol"] },
  );
  assert.deepEqual(parseRoutingRequest({ allowedModels: [] }), { setting: "auto", allowed: [] });
  const rejected = (error: unknown) => error instanceof Failure && error.code === "rejected";
  assert.throws(() => parseRoutingRequest({ effort: "extreme" }), rejected);
  assert.throws(() => parseRoutingRequest({ allowedModels: ["gpt-1"] }), rejected);
  assert.throws(() => parseRoutingRequest({ allowedModels: "sonnet" }), rejected);
  assert.throws(() => parseRoutingRequest([]), rejected);
  // The task, hints and previous model of a request.
  assert.deepEqual(
    parseRoutingRequest({
      task: "study.plan",
      difficulty: 3,
      needsVision: true,
      diagrams: false,
      previous: { alias: "sol", ageMs: 1200 },
    }),
    {
      setting: "auto",
      task: "study.plan",
      difficulty: 3,
      needsVision: true,
      diagrams: false,
      previous: { alias: "sol", ageMs: 1200 },
    },
  );
  assert.throws(() => parseRoutingRequest({ task: "chat" }), rejected);
  assert.throws(() => parseRoutingRequest({ difficulty: 4 }), rejected);
  assert.throws(() => parseRoutingRequest({ needsVision: "yes" }), rejected);
  assert.throws(() => parseRoutingRequest({ previous: { alias: "gpt", ageMs: 1 } }), rejected);
  assert.throws(() => parseRoutingRequest({ previous: { alias: "sol", ageMs: -1 } }), rejected);
  assert.throws(() => parseRoutingRequest({ model: "opus" }), rejected);
});

Deno.test("the plan comes from the billing state", () => {
  assert.equal(planFromState({ activePlan: null }), "free");
  assert.equal(planFromState({ activePlan: "starter699" }), "starter");
  assert.equal(planFromState({ activePlan: "pro1499" }), "pro");
  assert.equal(planFromState({ activePlan: "max2499" }), "max");
});

Deno.test("input tokens are counted cautiously, picture included", () => {
  assert.equal(estimateInputTokens(["abc", undefined, "def"], 0), 2);
  assert.equal(estimateInputTokens(["abc"], 1), 1 + 8192);
});

Deno.test("refusals reach the app as codes it already knows", () => {
  assert.equal(failureCode("insufficient_credits"), "insufficient_credits");
  assert.equal(failureCode("plan_required"), "plan_required");
  assert.equal(failureCode("provider_unavailable"), "server");
  assert.equal(failureCode("no_model_enabled"), "rejected");
});

Deno.test("the catalog skips unconfigured models and keeps the product's ordering", () => {
  const configured = (name: string, tier: Tier): ModelConfig => ({
    provider: "claude",
    model: name,
    inputMicroPerKilo: prices[tier][0],
    outputMicroPerKilo: prices[tier][1],
    maxOutputTokens: 16384,
  });
  const built = buildCatalog({
    haiku: configured("haiku-real", "unlimited"),
    sonnet: configured("sonnet-real", "standard"),
    opus: configured("opus-real", "frontier"),
    luna: configured("YOUR_LUNA_MODEL_ID", "unlimited"),
  });
  assert.deepEqual(built.map((m) => m.alias), ["haiku", "sonnet", "opus"]);
  for (const effort of efforts) {
    assert.ok(built[0].scores.reasoning[effort] < built[1].scores.reasoning[effort]);
    assert.ok(built[1].scores.reasoning[effort] < built[2].scores.reasoning[effort]);
  }
  for (const m of built) {
    assert.ok(m.scores.reasoning.low < m.scores.reasoning.medium);
    assert.ok(m.scores.reasoning.medium < m.scores.reasoning.high);
  }
  const tuned = buildCatalog(
    { haiku: configured("haiku-real", "unlimited") },
    { haiku: { scores: { reasoning: { high: 90 } }, vision: false } },
  );
  assert.equal(tuned[0].scores.reasoning.high, 90);
  assert.equal(tuned[0].scores.vision.high, 62);
  assert.equal(tuned[0].vision, false);
});
