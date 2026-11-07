import {
  capabilities,
  type Capability,
  type Effort,
  efforts,
  type Task,
} from "../functions/_shared/ai_router.ts";

/**
 * The eval set turns into router data here: how often each (model, effort) gets
 * each kind of case right becomes its capability score, and how strong a pair
 * has to be to pass a task at each difficulty becomes that task's bar.
 *
 * Pure functions only, so the arithmetic can be tested without a provider.
 */

export type Check =
  /** Every value appears, ignoring case and spacing. */
  | { type: "contains_all"; values: string[] }
  /** At least one value appears. */
  | { type: "contains_any"; values: string[] }
  /** The answer matches the pattern. */
  | { type: "regex"; pattern: string; flags?: string }
  /** The answer is a JSON object (a Markdown fence is ignored) with these keys. */
  | { type: "json"; requiredKeys: string[] }
  /** Scored 0 to 1 by a judge model against the rubric. */
  | { type: "judge"; rubric: string };

export interface EvalCase {
  id: string;
  task: Task;
  /** 1 easy, 2 normal, 3 hard: the same scale the router uses. */
  difficulty: 1 | 2 | 3;
  /** What the case exercises. Its pass counts toward each of these. */
  capabilities: Capability[];
  prompt: string;
  system?: string;
  /** A PNG, relative to the cases folder. Without one, a blank pixel is sent. */
  image?: string;
  check: Check;
}

export interface EvalRun {
  caseId: string;
  alias: string;
  effort: Effort;
  /** 0 to 1. */
  score: number;
  /** Provider cost in micro-USD, and wall time. */
  costMicro: number;
  latencyMs: number;
  /** Set when the provider refused or the answer could not be read. */
  error?: string;
}

/** The text of an answer without a Markdown fence round it. */
export function unfenced(text: string): string {
  const body = text.trim();
  if (!body.startsWith("```")) return body;
  return body.replace(/^```[^\n]*\n?/, "").replace(/```\s*$/, "").trim();
}

const squash = (text: string) => text.toLowerCase().replace(/\s+/g, " ").trim();

/** 0 or 1 for the checks that need no judge. A judge check is scored elsewhere. */
export function scoreAnswer(check: Exclude<Check, { type: "judge" }>, answer: string): number {
  switch (check.type) {
    case "contains_all": {
      const text = squash(answer);
      return check.values.every((value) => text.includes(squash(value))) ? 1 : 0;
    }
    case "contains_any": {
      const text = squash(answer);
      return check.values.some((value) => text.includes(squash(value))) ? 1 : 0;
    }
    case "regex":
      return new RegExp(check.pattern, check.flags ?? "i").test(answer) ? 1 : 0;
    case "json": {
      try {
        const parsed = JSON.parse(unfenced(answer));
        if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return 0;
        return check.requiredKeys.every((key) => key in parsed) ? 1 : 0;
      } catch {
        return 0;
      }
    }
  }
}

/** Reads a judge's reply as a score from 0 to 1: the first number in it, as a
 * fraction if it is above 1 (a score out of 10 or 100). Anything else is 0. */
export function judgeScore(reply: string): number {
  const match = /-?\d+(?:\.\d+)?/.exec(reply);
  if (!match) return 0;
  const value = Number(match[0]);
  if (!Number.isFinite(value) || value < 0) return 0;
  if (value <= 1) return value;
  return Math.min(1, value <= 10 ? value / 10 : value / 100);
}

const mean = (values: number[]) => values.reduce((a, b) => a + b, 0) / values.length;

/** Capability scores, 0 to 100, for each (model, effort): how often it passed
 * the cases that exercise the capability. A pair with no such case is left out,
 * so that the baseline stays in force for it. */
export function fitScores(
  cases: readonly EvalCase[],
  runs: readonly EvalRun[],
): Record<string, { scores: Partial<Record<Capability, Partial<Record<Effort, number>>>> }> {
  const byId = new Map(cases.map((c) => [c.id, c]));
  const buckets = new Map<string, number[]>();
  for (const run of runs) {
    const evalCase = byId.get(run.caseId);
    if (!evalCase) continue;
    for (const capability of evalCase.capabilities) {
      const key = `${run.alias}|${capability}|${run.effort}`;
      buckets.set(key, [...(buckets.get(key) ?? []), run.score]);
    }
  }
  const config: Record<
    string,
    { scores: Partial<Record<Capability, Partial<Record<Effort, number>>>> }
  > = {};
  for (const [key, scores] of buckets) {
    const [alias, capability, effort] = key.split("|") as [string, Capability, Effort];
    config[alias] ??= { scores: {} };
    config[alias].scores[capability] ??= {};
    config[alias].scores[capability]![effort] = Math.round(mean(scores) * 100);
  }
  // More thinking never makes a model worse than less in the data the router
  // reads, even when a small sample says so.
  for (const model of Object.values(config)) {
    for (const capability of capabilities) {
      const row = model.scores[capability];
      if (!row) continue;
      let best = 0;
      for (const effort of efforts) {
        if (row[effort] === undefined) continue;
        best = Math.max(best, row[effort]!);
        row[effort] = best;
      }
    }
  }
  return config;
}

export interface TaskBar {
  /** The capability score a pair needs at each difficulty, from the weakest
   * that still answered [target] of that difficulty's cases correctly. */
  perDifficulty: Partial<Record<1 | 2 | 3, number>>;
  /** What `taskProfiles` takes: the bar at difficulty 1, and the step up. */
  threshold: number;
  step: number;
}

/**
 * How strong a pair must be for a task: for each difficulty, the lowest
 * capability score among pairs that answered at least [target] of its cases
 * correctly. [scoreOf] gives a pair's score on the task's capabilities, as the
 * router will read it.
 */
export function fitTaskBars(
  cases: readonly EvalCase[],
  runs: readonly EvalRun[],
  scoreOf: (alias: string, effort: Effort, task: Task) => number,
  target = 0.85,
): Partial<Record<Task, TaskBar>> {
  const byId = new Map(cases.map((c) => [c.id, c]));
  const results = new Map<string, number[]>();
  for (const run of runs) {
    const evalCase = byId.get(run.caseId);
    if (!evalCase) continue;
    const key = `${evalCase.task}|${evalCase.difficulty}|${run.alias}|${run.effort}`;
    results.set(key, [...(results.get(key) ?? []), run.score]);
  }
  const needs = new Map<string, number>();
  for (const [key, scores] of results) {
    if (mean(scores) < target) continue;
    const [task, difficulty, alias, effort] = key.split("|");
    const bar = scoreOf(alias, effort as Effort, task as Task);
    const at = `${task}|${difficulty}`;
    needs.set(at, Math.min(needs.get(at) ?? Infinity, bar));
  }
  const bars: Partial<Record<Task, TaskBar>> = {};
  for (const [at, bar] of needs) {
    const [task, difficulty] = at.split("|");
    bars[task as Task] ??= { perDifficulty: {}, threshold: 0, step: 0 };
    bars[task as Task]!.perDifficulty[Number(difficulty) as 1 | 2 | 3] = bar;
  }
  for (const bar of Object.values(bars)) {
    const known = ([1, 2, 3] as const).filter((d) => bar!.perDifficulty[d] !== undefined);
    if (known.length === 0) continue;
    const first = known[0];
    const last = known[known.length - 1];
    bar!.threshold = bar!.perDifficulty[first]! - (first - 1) *
        (known.length > 1
          ? (bar!.perDifficulty[last]! - bar!.perDifficulty[first]!) / (last - first)
          : 0);
    bar!.step = known.length > 1
      ? (bar!.perDifficulty[last]! - bar!.perDifficulty[first]!) / (last - first)
      : 0;
    bar!.threshold = Math.round(bar!.threshold);
    bar!.step = Math.round(bar!.step);
  }
  return bars;
}
