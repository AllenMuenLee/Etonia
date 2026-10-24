import { Failure } from "./common.ts";

export interface ModelConfig {
  provider: "openai" | "claude" | "gemini";
  model: string;
  inputMicroPerKilo: number;
  outputMicroPerKilo: number;
  maxOutputTokens: number;
  /** What a cached input token costs, from the provider's price list. Without
   * it, cached input is billed as any other input. */
  cachedInputMicroPerKilo?: number;
  /** How hard the model thinks before answering: OpenAI's reasoning_effort, or
   * Gemini's thinkingLevel. Reasoning is billed as output, so a lower effort is
   * the largest saving per answer. Without it, the provider's default. */
  reasoningEffort?: string;
}
const reasoningEfforts = ["none", "minimal", "low", "medium", "high"];
export const aliases = ["haiku", "luna", "sonnet", "sol", "opus", "argon", "astra"];
export interface AiInput {
  requestId: string;
  model: string;
  prompt: string;
  history?: AiHistoryMessage[];
  systemInstruction: string;
  /** Expensive drawing grammar, sent to the provider only after the first
   * pass decides that a visual adds value. */
  notationInstruction?: string;
  animationAllowed?: boolean;
  /** The note as coordinates for this request. Sent apart from the fixed
   * [systemInstruction] so that the fixed part stays a cacheable prefix. */
  noteMetadata?: string;
  selectedImage: string;
  /** Clean crop is used for reading; this gridded variant is used only if a
   * second drawing pass is needed. */
  notationImage?: string;
  notationContext?: Record<string, number>;
  /** Accepted from older app versions for request compatibility. New clients
   * omit it, and it is never forwarded to providers. */
  responseSchema?: Record<string, unknown>;
}
export interface AiHistoryMessage {
  role: "user" | "assistant";
  content: string;
}

const maxHistoryBytes = 24000;
const maxHistoryMessages = 24;
const maxSchemaBytes = 256000;
const hardMaxOutputTokens = 16384;
/** With Notation on, the user's model writes the words only, within this many
 * output tokens; the drawing is left to [drawingModel]. */
export const answerOutputCap = 8192;
/** The model that turns an answer into the editable notation SVG. */
export const drawingModel = "luna";

export function validatePng(image: unknown): asserts image is string {
  if (
    typeof image !== "string" || image.length > 10000000 ||
    !/^[A-Za-z0-9+/]+={0,2}$/.test(image)
  ) {
    throw new Failure("rejected");
  }
  let bytes: string;
  try {
    bytes = atob(image);
  } catch {
    throw new Failure("rejected");
  }
  if (
    !bytes.startsWith("\x89PNG\r\n\x1a\n") || bytes.length < 24 || bytes.slice(12, 16) !== "IHDR"
  ) {
    throw new Failure("rejected");
  }
  const view = new DataView(Uint8Array.from(bytes.slice(16, 24), (c) => c.charCodeAt(0)).buffer);
  if ([view.getUint32(0), view.getUint32(4)].some((n) => n < 1 || n > 4096)) {
    throw new Failure("rejected");
  }
}

export function validateInput(body: Record<string, unknown>) {
  // Reject documents/URLs; the one permitted image is an inline PNG crop.
  if (
    Object.keys(body).some((k) =>
      ![
        "requestId",
        "model",
        "prompt",
        "history",
        "systemInstruction",
        "notationInstruction",
        "animationAllowed",
        "noteMetadata",
        "selectedImage",
        "notationImage",
        "notationContext",
        "responseSchema",
      ].includes(k)
    ) ||
    typeof body.requestId !== "string" ||
    !/^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
      body.requestId,
    ) ||
    typeof body.model !== "string" || !aliases.includes(body.model) ||
    typeof body.prompt !== "string" || !body.prompt.trim() ||
    new TextEncoder().encode(body.prompt).length > 24000 ||
    (body.history !== undefined && !validHistory(body.history)) ||
    typeof body.systemInstruction !== "string" ||
    new TextEncoder().encode(body.systemInstruction).length > 64000 ||
    (body.notationInstruction !== undefined &&
      (typeof body.notationInstruction !== "string" ||
        new TextEncoder().encode(body.notationInstruction).length > 64000)) ||
    (body.animationAllowed !== undefined &&
      typeof body.animationAllowed !== "boolean") ||
    (body.noteMetadata !== undefined &&
      (typeof body.noteMetadata !== "string" ||
        new TextEncoder().encode(body.noteMetadata).length > 128000))
  ) throw new Failure("rejected");
  validatePng(body.selectedImage);
  if (body.notationImage !== undefined) validatePng(body.notationImage);
  if (body.notationContext !== undefined) {
    const context = body.notationContext as Record<string, number>;
    const keys = ["width", "height", "left", "top", "right", "bottom"];
    if (
      !context || Object.keys(context).length !== keys.length || keys.some((k) =>
        !Number.isFinite(context[k])
      ) ||
      context.width <= 0 || context.height <= 0 || context.width > 1e7 || context.height > 1e7 ||
      context.left < 0 || context.top < 0 || context.right > 1 || context.bottom > 1 ||
      context.left >= context.right || context.top >= context.bottom
    ) throw new Failure("rejected");
  } else if (
    body.notationInstruction !== undefined || body.animationAllowed !== undefined ||
    body.notationImage !== undefined
  ) {
    throw new Failure("rejected");
  }
  if (body.responseSchema !== undefined) {
    const schema = body.responseSchema;
    if (
      schema === null || typeof schema !== "object" || Array.isArray(schema) ||
      (schema as Record<string, unknown>).type !== "object" ||
      new TextEncoder().encode(JSON.stringify(schema)).length > maxSchemaBytes
    ) throw new Failure("rejected");
  }
  return body as unknown as AiInput;
}

function validHistory(value: unknown): value is AiHistoryMessage[] {
  if (!Array.isArray(value) || value.length > maxHistoryMessages) return false;
  if (new TextEncoder().encode(JSON.stringify(value)).length > maxHistoryBytes) return false;
  let expected: AiHistoryMessage["role"] = "user";
  for (const message of value) {
    if (
      !message || typeof message !== "object" || Array.isArray(message) ||
      Object.keys(message).length !== 2 || !("role" in message) || !("content" in message) ||
      message.role !== expected || typeof message.content !== "string" || !message.content.trim()
    ) return false;
    expected = expected === "user" ? "assistant" : "user";
  }
  // History consists of completed turns; the current user prompt follows it.
  return expected === "user";
}
export function modelConfig(catalog: Record<string, ModelConfig>, alias: string): ModelConfig {
  const model = catalog[alias];
  if (
    !model || !["openai", "claude", "gemini"].includes(model.provider) ||
    !model.model || model.model.startsWith("YOUR_") || !/^[a-zA-Z0-9._-]+$/.test(model.model) ||
    !Number.isSafeInteger(model.inputMicroPerKilo) || model.inputMicroPerKilo < 0 ||
    model.inputMicroPerKilo > 1e9 ||
    !Number.isSafeInteger(model.outputMicroPerKilo) || model.outputMicroPerKilo <= 0 ||
    model.outputMicroPerKilo > 1e9 ||
    !Number.isSafeInteger(model.maxOutputTokens) || model.maxOutputTokens < 256 ||
    (model.cachedInputMicroPerKilo !== undefined &&
      (!Number.isSafeInteger(model.cachedInputMicroPerKilo) ||
        model.cachedInputMicroPerKilo < 0 ||
        model.cachedInputMicroPerKilo > model.inputMicroPerKilo)) ||
    (model.reasoningEffort !== undefined &&
      !reasoningEfforts.includes(model.reasoningEffort))
  ) throw new Failure("not_configured", 503);
  return model;
}
/** Which request an input bound is for: a plain one, or the answer or drawing
 * step of a notation request, each of which sends only part of the input. */
type Part = "all" | "text" | "draw";

/** The most one provider call's input can cost. */
function inputCostBound(model: ModelConfig, input: AiInput, part: Part = "all"): number {
  const sent = part === "text"
    ? input.prompt + input.systemInstruction + JSON.stringify(input.history ?? [])
    : part === "draw"
    ? input.prompt + (input.notationInstruction ?? input.systemInstruction) +
      (input.noteMetadata ?? "") + JSON.stringify(input.responseSchema ?? "") +
      drawingRequest(input)
    : input.prompt + input.systemInstruction + (input.notationInstruction ?? "") +
      (input.noteMetadata ?? "") + JSON.stringify(input.history ?? []) +
      JSON.stringify(input.responseSchema ?? "");
  // UTF-8 bytes conservatively bound text tokens; leave room for the fixed
  // system instruction, framing and a conservative allowance for a 2048px crop.
  const inputBound = new TextEncoder().encode(sent).length + 32768;
  return Math.ceil(inputBound * model.inputMicroPerKilo / 1000);
}

/** The most the drawing step can cost: [drawer] reads the note and the
 * answer, which is at most [answerOutputCap] tokens, and writes the notation. */
function drawingCap(drawer: ModelConfig, input: AiInput): number {
  const maxOutput = Math.min(drawer.maxOutputTokens, hardMaxOutputTokens);
  return inputCostBound(drawer, input, "draw") +
    Math.ceil(answerOutputCap * drawer.inputMicroPerKilo / 1000) +
    Math.ceil(maxOutput * drawer.outputMicroPerKilo / 1000);
}

/** The most this request can cost at full output, so only that much of the
 * balance is held and other requests can run alongside it. A notation request
 * has [drawer] draw the answer after [model] has written it. */
export function reservationCap(model: ModelConfig, input: AiInput, drawer?: ModelConfig): number {
  const maxOutput = Math.min(model.maxOutputTokens, hardMaxOutputTokens);
  if (!drawer) {
    return inputCostBound(model, input) + Math.ceil(maxOutput * model.outputMicroPerKilo / 1000);
  }
  return inputCostBound(model, input, "text") +
    Math.ceil(Math.min(maxOutput, answerOutputCap) * model.outputMicroPerKilo / 1000) +
    drawingCap(drawer, input);
}

/** What of [reserved] is left for the answer once [drawer]'s step is paid for. */
export function answerReserve(reserved: number, drawer: ModelConfig, input: AiInput): number {
  return reserved - drawingCap(drawer, input);
}

export function outputBudget(
  model: ModelConfig,
  input: AiInput,
  reserved: number,
  unlimited: boolean,
  drawn = false,
): number {
  // Reasoning counts against this, often thousands of tokens before the
  // answer starts; the model config caps it, as for metered requests.
  const cap = Math.min(
    model.maxOutputTokens,
    hardMaxOutputTokens,
    drawn ? answerOutputCap : Infinity,
  );
  if (unlimited) return cap;
  const inputCost = inputCostBound(model, input, drawn ? "text" : "all");
  const output = Math.min(
    cap,
    Math.floor((reserved - inputCost) * 1000 / model.outputMicroPerKilo),
  );
  if (output < 256) throw new Failure("insufficient_credits", 409);
  return output;
}
/** What [input] tokens, [cached] of them read from the provider's cache and
 * [cacheWrites] of them written to it, and [output] tokens cost. */
export function costOf(
  model: ModelConfig,
  input: number,
  output: number,
  cached = 0,
  cacheWrites = 0,
): number {
  if (
    ![input, output, cached, cacheWrites].every((n) => Number.isSafeInteger(n) && n >= 0) ||
    cached + cacheWrites > input
  ) {
    throw new Failure("server", 503);
  }
  const cachedRate = model.cachedInputMicroPerKilo ?? model.inputMicroPerKilo;
  // Claude charges a quarter more to write the cache, once per five minutes.
  const writeRate = model.provider === "claude"
    ? model.inputMicroPerKilo * 1.25
    : model.inputMicroPerKilo;
  return Math.ceil(
    ((input - cached - cacheWrites) * model.inputMicroPerKilo + cached * cachedRate +
      cacheWrites * writeRate + output * model.outputMicroPerKilo) / 1000,
  );
}

/** The fixed instructions, the same for every request: a cacheable prefix. */
function fixedInstruction(input: AiInput, notation = false): string {
  return (notation
    ? input.notationInstruction ?? input.systemInstruction
    : input.systemInstruction) +
    "\nPrivacy: You receive this AI conversation's text, the current question, and selected image " +
    "crop. You cannot see the rest of the note or PDFs. Do not pretend you can.";
}

/** What changes from request to request: where the crop is, and the note. */
function requestInstruction(input: AiInput): string {
  return (input.notationContext
    ? "Crop on the note (page logical width and height; crop bounds note_normalized). Beyond " +
      "it you know only the metadata; never assume other paper is blank. " +
      JSON.stringify(input.notationContext)
    : "Return no visible SVG elements.") +
    (input.noteMetadata ? "\n\n" + input.noteMetadata : "");
}

function instruction(input: AiInput, notation = false): string {
  return fixedInstruction(input, notation) + (notation ? " " + requestInstruction(input) : "");
}

/** One phase of a notation-enabled request: the user's model writes the words
 * from the clean crop, then [drawingModel] draws them from the gridded one. */
export type AiStep =
  | { step: "text" }
  | { step: "notation"; message: string; visual?: "static" };

/** Whether [input] is eligible for the answer-then-drawing pair of passes. */
export function twoStep(_model: ModelConfig, input: AiInput): boolean {
  return input.notationContext !== undefined;
}

const textStep =
  "\nAnswer fully but concisely, in words only: return the required SVG with only title and message desc. " +
  "A separate step draws on the note afterwards, so do not draw or mention a drawing.";

const notationStep =
  "\nThe explanation is already complete. Return the required self-contained SVG, placing the " +
  "explanation in its message desc and adding only the useful visible vector annotation. " +
  "Use no visible elements when a drawing would not help. Write nothing outside the SVG.";

/** The explanation in step 1's answer; an unreadable answer fails. */
export function stepMessage(answer: string): string {
  const svg = withoutFence(answer);
  const match = /<desc\b[^>]*data-etonia-role=["']message["'][^>]*>([\s\S]*?)<\/desc>/i.exec(svg);
  if (!match?.[1]?.trim()) {
    throw new Failure("server", 503);
  }
  return decodeXml(match[1]).trim();
}

/** The answer the app reads, from step 1's explanation and step 2's answer,
 * or none: a drawing that cannot be read is left out, the words kept. */
export function combineSteps(message: string, notationAnswer: string | undefined): string {
  const fallback =
    `<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" viewBox="0 0 1 1"><title>Answer</title><desc data-etonia-role="message">${
      escapeXml(message)
    }</desc></svg>`;
  const svg = withoutFence(notationAnswer ?? "");
  if (!/^<svg\b/i.test(svg) || !/<\/svg>\s*$/i.test(svg)) return fallback;
  const desc = /<desc\b[^>]*data-etonia-role=["']message["'][^>]*>[\s\S]*?<\/desc>/i;
  const replacement = `<desc data-etonia-role="message">${escapeXml(message)}</desc>`;
  return desc.test(svg)
    ? svg.replace(desc, replacement)
    : svg.replace(/<svg\b[^>]*>/i, (root) => root + replacement);
}

function escapeXml(text: string): string {
  return text.replaceAll("&", "&amp;").replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function decodeXml(text: string): string {
  return text.replaceAll("&lt;", "<").replaceAll("&gt;", ">")
    .replaceAll("&quot;", '"').replaceAll("&apos;", "'").replaceAll("&amp;", "&");
}

/** [text] without a Markdown code fence round it. */
function withoutFence(text: string): string {
  const body = text.trim();
  if (!body.startsWith("```")) return body;
  return body.replace(/^```[^\n]*\n?/, "").replace(/```\s*$/, "").trim();
}

const maxRequestEcho = 1500;
const maxEarlierRequests = 3;
const maxEarlierRequestLength = 300;

/** The closing turn of the drawing step: what the user actually asked for,
 * so the drawing model decides what to write, draw, complete, or animate from
 * their words and not only from the explanation. Recent earlier requests come
 * along so a follow-up ("now animate it") keeps its subject. */
export function drawingRequest(input: AiInput, visual?: "static"): string {
  const clip = (text: string, limit: number) => Array.from(text.trim()).slice(0, limit).join("");
  const earlier = (input.history ?? [])
    .filter((message) => message.role === "user")
    .slice(-maxEarlierRequests)
    .map((message) => clip(message.content, maxEarlierRequestLength))
    .filter((text) => text !== "");
  return `The user asked: ${JSON.stringify(clip(input.prompt, maxRequestEcho))}` +
    (earlier.length > 0
      ? `\nEarlier in this conversation they asked: ${earlier.map((t) => JSON.stringify(t)).join("; ")}`
      : "") +
    "\nFollowing your explanation, put on the note what this request calls for. If it asks you to " +
    "draw, complete, label, mark, plot, or fix something, do that directly on their own ink, adding " +
    "only what is missing. " +
    (visual === "static"
      ? ""
      : "If it asks for something to move or unfold in stages, animate it with steps. ") +
    "Otherwise add only the useful visual, or no visible elements when none helps.";
}

export function providerRequest(
  model: ModelConfig,
  input: AiInput,
  maxOutput: number,
  key: string,
  aiStep?: AiStep,
): {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
} {
  const system = instruction(input, aiStep?.step === "notation") +
    (aiStep?.step === "text" ? textStep : aiStep?.step === "notation"
      ? notationStep +
        (aiStep.visual === "static" ? " This visual is static; omit step on every item." : "")
      : "");
  const history = input.history ?? [];
  const requestHistory = aiStep?.step === "notation" ? [] : history;
  const selectedImage = aiStep?.step === "notation"
    ? input.notationImage ?? input.selectedImage
    : input.selectedImage;
  if (model.provider === "openai") {
    return {
      url: "https://api.openai.com/v1/chat/completions",
      headers: { Authorization: `Bearer ${key}` },
      body: {
        model: model.model,
        store: false,
        stream: false,
        max_completion_tokens: maxOutput,
        ...(model.reasoningEffort ? { reasoning_effort: model.reasoningEffort } : {}),
        messages: [
          { role: "system", content: system },
          ...requestHistory,
          {
            role: "user",
            content: [
              {
                type: "image_url",
                // Always the full-resolution read: misread handwriting
                // costs more than the image's tokens.
                image_url: {
                  url: `data:image/png;base64,${selectedImage}`,
                  detail: "high",
                },
              },
              { type: "text", text: input.prompt },
            ],
          },
          ...(aiStep?.step === "notation"
            ? [
              { role: "assistant", content: aiStep.message },
              { role: "user", content: drawingRequest(input, aiStep.visual) },
            ]
            : []),
        ],
      },
    };
  }
  if (model.provider === "claude") {
    return {
      url: "https://api.anthropic.com/v1/messages",
      headers: { "x-api-key": key, "anthropic-version": "2023-06-01" },
      body: {
        model: model.model,
        max_tokens: maxOutput,
        stream: false,
        // The fixed instructions are cached: later requests within five
        // minutes read them at a tenth of the price.
        system: [
          {
            type: "text",
            text: fixedInstruction(input, aiStep?.step === "notation"),
            cache_control: { type: "ephemeral" },
          },
          {
            type: "text",
            text: (aiStep?.step === "notation" ? requestInstruction(input) : "") +
              (aiStep?.step === "text" ? textStep : aiStep?.step === "notation"
                ? notationStep +
                  (aiStep.visual === "static"
                    ? " This visual is static; omit step on every item."
                    : "")
                : ""),
          },
        ],
        // The explanation/decision is held to its small shape. The notation's
        // shape cannot be: Claude refuses its schema as too large a grammar
        // (a plot alone just fits), so the prompt's example and the app's
        // tolerant parser carry it.
        messages: [
          ...requestHistory,
          {
            role: "user",
            content: [
              {
                type: "image",
                source: { type: "base64", media_type: "image/png", data: selectedImage },
              },
              { type: "text", text: input.prompt },
            ],
          },
          ...(aiStep?.step === "notation"
            ? [
              { role: "assistant", content: aiStep.message },
              {
                role: "user",
                content: drawingRequest(input, aiStep.visual),
              },
            ]
            : []),
        ],
      },
    };
  }
  return {
    url: `https://generativelanguage.googleapis.com/v1beta/models/${model.model}:generateContent`,
    headers: { "x-goog-api-key": key },
    body: {
      systemInstruction: { parts: [{ text: system }] },
      contents: [
        ...requestHistory.map((message) => ({
          role: message.role === "assistant" ? "model" : "user",
          parts: [{ text: message.content }],
        })),
        {
          role: "user",
          parts: [
            { inlineData: { mimeType: "image/png", data: selectedImage } },
            { text: input.prompt },
          ],
        },
        ...(aiStep?.step === "notation"
          ? [
            { role: "model", parts: [{ text: aiStep.message }] },
            { role: "user", parts: [{ text: drawingRequest(input, aiStep.visual) }] },
          ]
          : []),
      ],
      generationConfig: {
        maxOutputTokens: maxOutput,
        ...(model.reasoningEffort
          ? { thinkingConfig: { thinkingLevel: model.reasoningEffort } }
          : {}),
        responseMimeType: "text/plain",
      },
    },
  };
}
export function providerAnswer(model: ModelConfig, body: any) {
  if (model.provider === "openai") {
    return {
      answer: body.choices?.[0]?.message?.content,
      input: body.usage?.prompt_tokens,
      output: body.usage?.completion_tokens,
      cached: body.usage?.prompt_tokens_details?.cached_tokens ?? 0,
      cacheWrites: 0,
    };
  }
  if (model.provider === "claude") {
    // Claude counts cached input apart from input_tokens.
    const read = body.usage?.cache_read_input_tokens ?? 0;
    const written = body.usage?.cache_creation_input_tokens ?? 0;
    const uncached = body.usage?.input_tokens;
    return {
      answer: body.content?.filter((p: any) => p.type === "text").map((p: any) => p.text).join(""),
      input: typeof uncached === "number" ? uncached + read + written : uncached,
      output: body.usage?.output_tokens,
      cached: read,
      cacheWrites: written,
    };
  }
  return {
    answer: body.candidates?.[0]?.content?.parts?.filter((p: any) => !p.thought).map((p: any) =>
      p.text ?? ""
    ).join(""),
    cached: body.usageMetadata?.cachedContentTokenCount ?? 0,
    cacheWrites: 0,
    input: body.usageMetadata?.promptTokenCount,
    output: typeof body.usageMetadata?.candidatesTokenCount === "number"
      ? body.usageMetadata.candidatesTokenCount + (body.usageMetadata.thoughtsTokenCount ?? 0)
      : undefined,
  };
}
