import type { AiInput } from "./ai_policy.ts";
import { studyCalibration, type StudyRouteCalibration } from "./study_calibration.ts";

export type StudyQuestionKind = "definition" | "calculation" | "sourceLookup";

export function studyQuestion(prompt: string): string {
  const marker = prompt.lastIndexOf("\n\nQuestion: ");
  const review = prompt.lastIndexOf("\n\nStudent question: ");
  if (review > marker) return prompt.slice(review + "\n\nStudent question: ".length).trim();
  return marker >= 0 ? prompt.slice(marker + "\n\nQuestion: ".length).trim() : prompt.trim();
}

export function studyQuestionKind(
  prompt: string,
  history: readonly unknown[] = [],
): StudyQuestionKind | undefined {
  // The initial calibration is bounded ASCII text. Do not silently generalize
  // its scores to multilingual sources or unfamiliar Unicode notation.
  if (history.length || /[^\x00-\x7f]/.test(prompt)) return undefined;
  const text = studyQuestion(prompt);
  if (
    /according to|in (?:these|the|my) notes|source (?:says|states)|笔记|根据|según.*notas/i.test(
      text,
    )
  ) return "sourceLookup";
  if (
    /\b(?:calculate|compute|evaluate|solve|simplify|convert|differentiate|integrate)\b|计算|求解|化简|calcula|resuelve/i
      .test(text)
  ) return /\[Source N\d+:P\d+/i.test(prompt) ? undefined : "calculation";
  if (
    /\b(?:what (?:is|are|does)|define|definition|meaning|difference|differs|explain|how.*differ)\b|什么|解释|区别|qué es|define|qu'est/i
      .test(text)
  ) return "definition";
  return undefined;
}

export function studyDifficulty(
  task: string,
  input: AiInput,
  requested = 2,
  needsVision = false,
  diagrams = false,
): 1 | 2 | 3 {
  if (!task.startsWith("study.")) return requested as 1 | 2 | 3;
  const question = studyQuestion(input.prompt);
  const hard = needsVision || diagrams ||
    /\b(?:prove|proof|derive|derivation|laplace|fourier|differential equations?|eigenvalues?|eigenvectors?|uniform convergence|stochastic|asymptotic|nonlinear)\b|证明|推导|微分方程|傅里叶/i
      .test(question) ||
    /Lesson planning data[\s\S]*?"stage":"(?:learning|assessment)"/.test(input.prompt);
  if (hard) return 3;
  // A cheap planner can label an unqualified answer category "easy". Keep the
  // normal answer bar unless the answer category itself passed both bands.
  if (
    task === "study.answer" && input.studyPolicyVersion === "study-cost-b1" &&
    studyQuestionKind(input.prompt, input.history) !== "calculation"
  ) return Math.max(2, requested) as 2 | 3;
  return requested as 1 | 2 | 3;
}

export function studyQualification(
  model: string,
  task: string,
  effort: string,
  hints: {
    difficulty?: number;
    studyPolicyVersion?: string;
    needsVision?: boolean;
    diagrams?: boolean;
    studyQuestionKind?: StudyQuestionKind;
  },
  profile: readonly StudyRouteCalibration[] = studyCalibration,
): StudyRouteCalibration | undefined {
  if (
    hints.studyPolicyVersion !== "study-cost-b1" || hints.needsVision || hints.diagrams ||
    !hints.studyQuestionKind
  ) return undefined;
  return profile.find((q) =>
    q.policyVersion === "study-cost-b1" && q.model === model && q.task === task &&
    q.effort === effort &&
    q.kind === hints.studyQuestionKind && q.difficulty === (hints.difficulty ?? 2) &&
    q.calibrationCases >= 10 && q.holdoutCases >= 10 &&
    q.calibrationFailures === 0 && q.holdoutFailures === 0 &&
    /^[a-f0-9]{64}$/.test(q.caseDigest)
  );
}

/** Only the real one-pixel transport placeholder can avoid the visual allowance. */
export function isPlaceholderPng(image: string): boolean {
  if (image.length > 128) return false;
  const bytes = atob(image);
  if (bytes.length < 24) return false;
  const view = new DataView(Uint8Array.from(bytes.slice(16, 24), (c) => c.charCodeAt(0)).buffer);
  return view.getUint32(0) === 1 && view.getUint32(4) === 1;
}

export function studyOutputCeiling(
  task: string | undefined,
  configured: number,
  effort?: string,
): number {
  if (task === "study.describe") return Math.min(configured, 4096);
  if (effort === "high") return configured;
  if (task === "study.suggestions") return Math.min(configured, 2048);
  if (task === "study.plan") return Math.min(configured, 8192);
  // A derivation/lesson is not truncated merely to meet a saving target.
  return configured;
}

/** Check machine-verifiable structure and source IDs before spending on a retry. */
export function usableStudyResponse(
  input: AiInput,
  task: string | undefined,
  text: string,
): boolean {
  if (input.responseFormat === "json") {
    let value: any;
    try {
      value = JSON.parse(text.trim().replace(/^```(?:json)?\s*|\s*```$/g, ""));
    } catch {
      return false;
    }
    if (!value || typeof value !== "object" || Array.isArray(value)) return false;
    if (task === "study.describe") {
      let count: number;
      try {
        count = JSON.parse(input.prompt).panelCount;
      } catch {
        return false;
      }
      return [1, 2].includes(count) && Object.keys(value).length === 1 &&
        Array.isArray(value.panels) && value.panels.length === count &&
        value.panels.every((panel: any, i: number) =>
          panel && Object.keys(panel).length === 3 &&
          panel.panel === String.fromCharCode(65 + i) &&
          typeof panel.description === "string" && panel.description.trim() &&
          panel.description.length <= 6000 &&
          Array.isArray(panel.uncertainties) && panel.uncertainties.length <= 8 &&
          panel.uncertainties.every((s: any) =>
            typeof s === "string" && s.trim() && s.length <= 240
          )
        );
    }
    if (task === "study.suggestions") {
      return Array.isArray(value.questions) && value.questions.length === 3 &&
        value.questions.every((q: any) => typeof q === "string" && q.trim() && q.length <= 180) &&
        new Set(value.questions.map((q: string) => q.trim().toLowerCase())).size === 3;
    }
    if (task === "study.plan") {
      if (value.difficulty !== undefined && ![1, 2, 3].includes(value.difficulty)) return false;
      if (value.intent === "topic") {
        const plan = value.plan;
        return plan && typeof plan.topic === "string" && plan.topic.length <= 200 &&
          (plan.activeStep ?? 0) === 0 && (plan.stage ?? "learning") === "learning" &&
          Array.isArray(plan.steps) && plan.steps.length >= 2 && plan.steps.length <= 12 &&
          new TextEncoder().encode(JSON.stringify(plan)).length <= 8000 &&
          plan.steps.every((step: any) =>
            step &&
            ["title", "goal", "retrievalQuery", "foundationExercise"].every((key) =>
              typeof step[key] === "string" && step[key].trim() && step[key].length <=
                (key === "title" ? 160 : key === "retrievalQuery" ? 300 : 600)
            )
          );
      }
      if (value.intent === "continue") {
        return Number.isSafeInteger(value.activeStep) && value.activeStep >= 0 &&
          value.activeStep < 12;
      }
      return ["question", "assessment", "review", "complete"].includes(value.intent);
    }
    return true;
  }
  if (task !== "study.answer" || input.responseFormat !== "text") return true;
  const pages = new Set<string>();
  const chunks = new Set<string>();
  for (const match of input.prompt.matchAll(/\[Source (N\d+:P\d+):C(\d+)\s*\|/g)) {
    pages.add(match[1]);
    chunks.add(`${match[1]}:C${match[2]}`);
  }
  for (const match of text.matchAll(/\[\[(N\d+:P\d+)(?::(C\d+|L[^\]]+))?[^\]]*\]\]/g)) {
    if (!pages.has(match[1])) return false;
    if (match[2]?.startsWith("C") && !chunks.has(`${match[1]}:${match[2]}`)) return false;
  }
  return true;
}
