import { Failure } from "./common.ts";
import { aliases, costOf, type ModelConfig, modelConfig } from "./ai_policy.ts";
import { studyQualification, type StudyQuestionKind } from "./study_policy.ts";

/**
 * Chooses which model, and how much thinking, answers a request: the cheapest
 * (model, effort) pair that is capable enough, by provider cost.
 *
 * Pure and deterministic, so it can be tested without a network. Callers pass
 * in everything that varies (plan, credits, the user's enabled models, provider
 * health); nothing here reads the environment.
 */

export const efforts = ["low", "medium", "high"] as const;
export type Effort = typeof efforts[number];
/** What the user picks: a fixed level, or `auto` to let the router decide. */
export type EffortSetting = "auto" | Effort;

export const capabilities = ["reasoning", "vision", "diagrams", "structured", "drawing"] as const;
export type Capability = typeof capabilities[number];

export const tasks = [
  "study.answer",
  "study.plan",
  "study.suggestions",
  "study.practice",
  "editor.answer",
  "editor.notation",
  "test.grading",
] as const;
export type Task = typeof tasks[number];

/** The user's plan as the router sees it. `free` is no plan, on free credit. */
export type Plan = "free" | "starter" | "pro" | "max";
export type Tier = "unlimited" | "standard" | "frontier";

export interface RouterModel {
  studyCalibration?: boolean;
  alias: string;
  config: ModelConfig;
  /** Billing tier: unlimited models cost a paid plan nothing at low and medium
   * effort; frontier models are Pro and Max only. */
  tier: Tier;
  contextTokens: number;
  vision: boolean;
  /** Lower is faster. Breaks ties between equally cheap pairs. */
  latencyRank: number;
  /** 0 to 100, by capability and effort. */
  scores: Record<Capability, Record<Effort, number>>;
}

export interface RouterOverride {
  /** Explicit custom scores take precedence unless this is set to true. */
  studyCalibration?: boolean;
  tier?: Tier;
  contextTokens?: number;
  vision?: boolean;
  latencyRank?: number;
  scores?: Partial<Record<Capability, Partial<Record<Effort, number>>>>;
}

export interface RouterOptions {
  /** How many times a task's usual output a given effort multiplies it by, as
   * thinking tokens are billed as output. Calibrate from logged usage. */
  thinkingFactor: Record<Effort, number>;
  /** A model that served the previous turn is kept unless another is this much
   * cheaper, for its warm prompt cache and a steady voice. */
  stickiness: number;
  cacheTtlMs: number;
}

export const defaultOptions: RouterOptions = {
  thinkingFactor: { low: 1, medium: 1.8, high: 3.5 },
  stickiness: 0.15,
  cacheTtlMs: 5 * 60 * 1000,
};

// ---------------------------------------------------------------------------
// The catalog
// ---------------------------------------------------------------------------

const baselineTier: Record<string, Tier> = {
  haiku: "unlimited",
  luna: "unlimited",
  sonnet: "standard",
  sol: "standard",
  opus: "frontier",
  argon: "frontier",
  astra: "frontier",
};

/**
 * PLACEHOLDER capability by tier and effort. It encodes only the ordering the
 * product already claims (unlimited < standard < frontier, more effort is more
 * capable), not any measured per-skill strength. Replace per model and
 * capability through [RouterOverride] with eval results.
 */
const baselineScores: Record<Tier, Record<Effort, number>> = {
  unlimited: { low: 40, medium: 52, high: 62 },
  standard: { low: 62, medium: 74, high: 82 },
  frontier: { low: 78, medium: 88, high: 94 },
};

const baselineLatency: Record<Tier, number> = { unlimited: 1, standard: 2, frontier: 3 };

/** The models that are configured, with their router data. A model with no
 * valid entry in [models] is simply absent, never an error: it is not routable. */
export function buildCatalog(
  models: Record<string, ModelConfig>,
  overrides: Record<string, RouterOverride> = {},
): RouterModel[] {
  const catalog: RouterModel[] = [];
  for (const alias of aliases) {
    let config: ModelConfig;
    try {
      config = modelConfig(models, alias);
    } catch {
      continue;
    }
    const override = overrides[alias] ?? {};
    const tier = override.tier ?? baselineTier[alias];
    if (!tier) continue;
    const scores = {} as RouterModel["scores"];
    for (const capability of capabilities) {
      scores[capability] = { ...baselineScores[tier], ...override.scores?.[capability] };
    }
    catalog.push({
      studyCalibration: override.studyCalibration ?? override.scores === undefined,
      alias,
      config,
      tier,
      contextTokens: override.contextTokens ?? 200000,
      vision: override.vision ?? true,
      latencyRank: override.latencyRank ?? baselineLatency[tier],
      scores,
    });
  }
  return catalog;
}

// ---------------------------------------------------------------------------
// Tasks
// ---------------------------------------------------------------------------

interface TaskProfile {
  /** The weakest of these, for the pair, is what it is held to. */
  needs: readonly Capability[];
  /** The score needed at difficulty 1, and what each step up adds. */
  threshold: number;
  step: number;
  /** Typical answer length before thinking. */
  outputTokens: number;
}

/** PLACEHOLDER thresholds, to be tuned against the eval set. */
export const taskProfiles: Record<Task, TaskProfile> = {
  "study.suggestions": { needs: ["structured"], threshold: 30, step: 0, outputTokens: 150 },
  "study.plan": { needs: ["structured", "reasoning"], threshold: 45, step: 8, outputTokens: 700 },
  "study.answer": { needs: ["reasoning"], threshold: 55, step: 12, outputTokens: 1200 },
  "study.practice": {
    needs: ["structured", "reasoning"],
    threshold: 55,
    step: 10,
    outputTokens: 2500,
  },
  "editor.answer": {
    needs: ["reasoning", "vision"],
    threshold: 55,
    step: 12,
    outputTokens: 900,
  },
  "editor.notation": { needs: ["drawing", "vision"], threshold: 60, step: 10, outputTokens: 3000 },
  "test.grading": { needs: ["reasoning", "vision"], threshold: 68, step: 8, outputTokens: 1500 },
};

export const defaultDifficulty = 2;

export interface RouteHints {
  /** Classified on the server, never accepted as a client routing field. */
  studyQuestionKind?: StudyQuestionKind;
  studyPolicyVersion?: string;
  /** 1 easy, 2 normal, 3 hard. From the planner's verdict or request features. */
  difficulty?: 1 | 2 | 3;
  /** A picture has to be read, not just attached. */
  needsVision?: boolean;
  /** The picture is a diagram. */
  diagrams?: boolean;
  /** Everything sent, images included. */
  inputTokens: number;
  /** The part that repeats from turn to turn: system prompt and history. */
  cacheablePrefixTokens?: number;
}

export interface RouteContext {
  task: Task;
  setting: EffortSetting;
  plan: Plan;
  /** Credits left, in micro-USD. */
  creditsMicro: number;
  /** The models the user left on. Absent means all of them. */
  allowed?: readonly string[];
  unhealthyProviders?: readonly string[];
  previous?: { alias: string; ageMs: number };
  hints: RouteHints;
  /** `alias:effort` keys that were already tried and failed. */
  exclude?: readonly string[];
  /** Escalation: only a pair scoring strictly above this may answer. */
  above?: number;
}

export type DenyReason =
  | "free_credit_exhausted"
  | "insufficient_credits"
  | "plan_required"
  | "no_model_enabled"
  | "provider_unavailable"
  | "unsupported_input"
  | "no_stronger_model";

export interface Decision {
  ok: true;
  alias: string;
  effort: Effort;
  provider: ModelConfig["provider"];
  /** Unlimited pairs are free to the user; metered ones draw on credits. */
  billing: "unlimited" | "metered";
  estimatedCost: number;
  score: number;
  required: number;
  /** False when nothing allowed was capable and this is the best that was. */
  capable: boolean;
}

export interface Denied {
  ok: false;
  reason: DenyReason;
}

export const pairKey = (alias: string, effort: Effort) => `${alias}:${effort}`;

interface Pair {
  model: RouterModel;
  effort: Effort;
  unlimited: boolean;
  cost: number;
  score: number;
}

function entitled(plan: Plan, model: RouterModel): boolean {
  return model.tier !== "frontier" || plan === "pro" || plan === "max";
}

/** Whether a pair costs a paid plan nothing: Haiku and Luna, but only up to
 * medium effort, since heavy thinking is real money. Free credit pays for all. */
export function isUnlimited(plan: Plan, model: RouterModel, effort: Effort): boolean {
  return plan !== "free" && model.tier === "unlimited" && effort !== "high";
}

export function requiredScore(task: Task, difficulty: number): number {
  const profile = taskProfiles[task];
  return profile.threshold + profile.step * (difficulty - 1);
}

function needsOf(task: Task, hints: RouteHints): Capability[] {
  const needs = new Set<Capability>(taskProfiles[task].needs);
  if (hints.needsVision) needs.add("vision");
  if (hints.diagrams) needs.add("diagrams");
  return [...needs];
}

export function estimateCost(
  model: RouterModel,
  effort: Effort,
  task: Task,
  hints: RouteHints,
  cacheWarm: boolean,
  options: RouterOptions = defaultOptions,
): number {
  const input = Math.max(0, Math.ceil(hints.inputTokens));
  const cached = cacheWarm ? Math.min(Math.ceil(hints.cacheablePrefixTokens ?? 0), input) : 0;
  const qualified = model.studyCalibration === false
    ? undefined
    : studyQualification(model.config.model, task, effort, hints);
  const output = qualified?.outputTokens ??
    Math.ceil(taskProfiles[task].outputTokens * options.thinkingFactor[effort]);
  return costOf(model.config, input, output, cached, 0);
}

/** Lower efforts to fall back through, so that a fixed level the credits cannot
 * pay for becomes the next one down rather than a refusal. */
function effortPasses(setting: EffortSetting): Effort[][] {
  if (setting === "auto") return [[...efforts]];
  const down = efforts.slice(0, efforts.indexOf(setting) + 1).reverse();
  return down.map((effort) => [effort]);
}

/**
 * The (model, effort) that should answer: capable first, then cheapest.
 *
 * - A free plan with no credit left is refused outright.
 * - A paid plan with no credit left carries on, silently, on an unlimited model
 *   at low or medium effort, whatever level was asked for.
 * - Models the user turned off are never used.
 */
export function route(
  catalog: readonly RouterModel[],
  context: RouteContext,
  options: RouterOptions = defaultOptions,
): Decision | Denied {
  const { plan, hints } = context;
  if (plan === "free" && context.creditsMicro <= 0) {
    return { ok: false, reason: "free_credit_exhausted" };
  }

  let pool = catalog.filter((model) => !context.allowed || context.allowed.includes(model.alias));
  if (pool.length === 0) return { ok: false, reason: "no_model_enabled" };
  pool = pool.filter((model) => entitled(plan, model));
  if (pool.length === 0) return { ok: false, reason: "plan_required" };
  pool = pool.filter((model) => !context.unhealthyProviders?.includes(model.config.provider));
  if (pool.length === 0) return { ok: false, reason: "provider_unavailable" };
  const needs = needsOf(context.task, hints);
  pool = pool.filter((model) =>
    (!needs.includes("vision") || model.vision) && hints.inputTokens <= model.contextTokens
  );
  if (pool.length === 0) return { ok: false, reason: "unsupported_input" };

  const required = requiredScore(context.task, hints.difficulty ?? defaultDifficulty);
  const scoreOf = (model: RouterModel, effort: Effort) =>
    (model.studyCalibration === false
      ? undefined
      : studyQualification(model.config.model, context.task, effort, hints)?.score) ??
      Math.min(...needs.map((need) => model.scores[need][effort]));
  const warm = (model: RouterModel) =>
    context.previous?.alias === model.alias && context.previous.ageMs <= options.cacheTtlMs;

  let affordable: Pair[] = [];
  for (const pass of effortPasses(context.setting)) {
    affordable = [];
    for (const model of pool) {
      for (const effort of pass) {
        const unlimited = isUnlimited(plan, model, effort);
        const cost = estimateCost(model, effort, context.task, hints, warm(model), options);
        // Metered pairs need credit that covers them, so a nearly empty balance
        // moves down to a cheaper pair instead of overdrawing.
        if (!unlimited && !(context.creditsMicro > 0 && cost <= context.creditsMicro)) continue;
        affordable.push({ model, effort, unlimited, cost, score: scoreOf(model, effort) });
      }
    }
    if (affordable.length > 0) break;
  }
  if (affordable.length === 0) return { ok: false, reason: "insufficient_credits" };

  let pairs = affordable.filter((pair) =>
    !context.exclude?.includes(pairKey(pair.model.alias, pair.effort))
  );
  if (context.above !== undefined) {
    pairs = pairs.filter((pair) => pair.score > context.above!);
  }
  if (pairs.length === 0) {
    return {
      ok: false,
      reason: context.above !== undefined || context.exclude?.length
        ? "no_stronger_model"
        : "insufficient_credits",
    };
  }

  const cheapest = (a: Pair, b: Pair) =>
    a.cost - b.cost || a.model.latencyRank - b.model.latencyRank || b.score - a.score ||
    a.model.alias.localeCompare(b.model.alias) || efforts.indexOf(a.effort) -
      efforts.indexOf(b.effort);

  const capable = pairs.filter((pair) => pair.score >= required);
  let chosen: Pair;
  if (capable.length > 0) {
    capable.sort(cheapest);
    chosen = capable[0];
    const last = context.previous?.alias;
    const kept = last ? capable.find((pair) => pair.model.alias === last) : undefined;
    if (kept && kept.cost <= chosen.cost * (1 + options.stickiness)) chosen = kept;
  } else {
    // Nothing allowed is capable enough: the strongest, and the cheapest of those.
    pairs.sort((a, b) => b.score - a.score || cheapest(a, b));
    chosen = pairs[0];
  }
  return {
    ok: true,
    alias: chosen.model.alias,
    effort: chosen.effort,
    provider: chosen.model.config.provider,
    billing: chosen.unlimited ? "unlimited" : "metered",
    estimatedCost: chosen.cost,
    score: chosen.score,
    required,
    capable: chosen.score >= required,
  };
}

/** The next pair to try after [failed] could not answer: strictly stronger, and
 * not one already tried. */
export function escalate(
  catalog: readonly RouterModel[],
  context: RouteContext,
  failed: Decision,
  options: RouterOptions = defaultOptions,
): Decision | Denied {
  return route(catalog, {
    ...context,
    exclude: [...(context.exclude ?? []), pairKey(failed.alias, failed.effort)],
    above: failed.score,
  }, options);
}

// ---------------------------------------------------------------------------
// Talking to providers and to the app
// ---------------------------------------------------------------------------

export { providerEffort } from "./ai_policy.ts";

export interface RoutingRequest {
  setting: EffortSetting;
  /** What the request is for; `editor.answer` when the app says nothing. */
  task?: Task;
  /** The models the user left on, or undefined for all. */
  allowed?: string[];
  /** From the Study Desk planner, 1 easy to 3 hard. */
  difficulty?: 1 | 2 | 3;
  needsVision?: boolean;
  diagrams?: boolean;
  /** The model that answered the previous turn, and how long ago. */
  previous?: { alias: string; ageMs: number };
}

const routingKeys = [
  "task",
  "effort",
  "allowedModels",
  "difficulty",
  "needsVision",
  "diagrams",
  "previous",
];

/** The routing part of a request, from the app. Anything unexpected is
 * refused: the server never guesses what a user meant to turn off. */
export function parseRoutingRequest(raw: unknown): RoutingRequest {
  if (raw === undefined || raw === null) return { setting: "auto" };
  if (typeof raw !== "object" || Array.isArray(raw)) throw new Failure("rejected");
  const body = raw as Record<string, unknown>;
  if (Object.keys(body).some((key) => !routingKeys.includes(key))) throw new Failure("rejected");
  const { effort, allowedModels, task, difficulty, needsVision, diagrams, previous } = body;
  const setting = effort ?? "auto";
  if (setting !== "auto" && !(efforts as readonly unknown[]).includes(setting)) {
    throw new Failure("rejected");
  }
  const request: RoutingRequest = { setting: setting as EffortSetting };
  if (task !== undefined) {
    if (!(tasks as readonly unknown[]).includes(task)) throw new Failure("rejected");
    request.task = task as Task;
  }
  if (difficulty !== undefined) {
    if (difficulty !== 1 && difficulty !== 2 && difficulty !== 3) throw new Failure("rejected");
    request.difficulty = difficulty;
  }
  for (const [name, value] of [["needsVision", needsVision], ["diagrams", diagrams]] as const) {
    if (value === undefined) continue;
    if (typeof value !== "boolean") throw new Failure("rejected");
    request[name] = value;
  }
  if (previous !== undefined) {
    const last = previous as Record<string, unknown> | null;
    if (
      !last || typeof last !== "object" || typeof last.alias !== "string" ||
      !aliases.includes(last.alias) || typeof last.ageMs !== "number" ||
      !Number.isFinite(last.ageMs) || last.ageMs < 0
    ) throw new Failure("rejected");
    request.previous = { alias: last.alias, ageMs: last.ageMs };
  }
  if (allowedModels !== undefined) {
    if (
      !Array.isArray(allowedModels) || allowedModels.length > aliases.length ||
      !allowedModels.every((alias) => typeof alias === "string" && aliases.includes(alias))
    ) throw new Failure("rejected");
    request.allowed = [...new Set(allowedModels as string[])];
  }
  return request;
}

/** The plan the router sees, from `billing_state`. */
export function planFromState(state: Record<string, unknown>): Plan {
  switch (state.activePlan) {
    case "starter699":
      return "starter";
    case "pro1499":
      return "pro";
    case "max2499":
      return "max";
    default:
      return "free";
  }
}

/** A cautious count of the tokens a request sends: its text at one token per
 * three bytes, and the picture at the most it can cost on any provider. */
export function estimateInputTokens(parts: readonly (string | undefined)[], images = 1): number {
  const bytes = parts.reduce(
    (sum, part) => sum + (part ? new TextEncoder().encode(part).length : 0),
    0,
  );
  return Math.ceil(bytes / 3) + images * 8192;
}

/** The error code a refusal reaches the app as. */
export function failureCode(reason: DenyReason): string {
  switch (reason) {
    case "free_credit_exhausted":
    case "insufficient_credits":
      return "insufficient_credits";
    case "plan_required":
      return "plan_required";
    case "provider_unavailable":
      return "server";
    default:
      return "rejected";
  }
}
