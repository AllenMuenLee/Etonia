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
  /** The note as coordinates for this request. Sent apart from the fixed
   * [systemInstruction] so that the fixed part stays a cacheable prefix. */
  noteMetadata?: string;
  selectedImage: string;
  notationContext?: Record<string, number>;
  /** The answer's JSON schema, sent with Notation on: the provider is held
   * to it, so the drawing arrives in the shape the app reads. */
  responseSchema?: Record<string, unknown>;
}
export interface AiHistoryMessage {
  role: "user" | "assistant";
  content: string;
}

/** The most a response schema may be, as JSON. */
const maxSchemaBytes = 64000;
const maxHistoryBytes = 128000;
const maxHistoryMessages = 100;

export function validatePng(image: unknown): asserts image is string {
  if (
    typeof image !== "string" || image.length > 6000000 || !/^[A-Za-z0-9+/]+={0,2}$/.test(image)
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
  if ([view.getUint32(0), view.getUint32(4)].some((n) => n < 1 || n > 2048)) {
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
        "noteMetadata",
        "selectedImage",
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
    (body.noteMetadata !== undefined &&
      (typeof body.noteMetadata !== "string" ||
        new TextEncoder().encode(body.noteMetadata).length > 64000))
  ) throw new Failure("rejected");
  validatePng(body.selectedImage);
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
    model.maxOutputTokens > 16384 ||
    (model.cachedInputMicroPerKilo !== undefined &&
      (!Number.isSafeInteger(model.cachedInputMicroPerKilo) ||
        model.cachedInputMicroPerKilo < 0 ||
        model.cachedInputMicroPerKilo > model.inputMicroPerKilo)) ||
    (model.reasoningEffort !== undefined &&
      !reasoningEfforts.includes(model.reasoningEffort))
  ) throw new Failure("not_configured", 503);
  return model;
}
/** The most one provider call's input can cost. */
function inputCostBound(model: ModelConfig, input: AiInput): number {
  // UTF-8 bytes conservatively bound text tokens; leave room for the fixed
  // system instruction, framing and a conservative allowance for a 2048px crop.
  const inputBound = new TextEncoder().encode(
    input.prompt + input.systemInstruction + (input.noteMetadata ?? "") +
      JSON.stringify(input.history ?? []) +
      JSON.stringify(input.responseSchema ?? ""),
  ).length +
    32768;
  return Math.ceil(inputBound * model.inputMicroPerKilo / 1000);
}

/** The most this request can cost at full output, so only that much of the
 * balance is held and other requests can run alongside it. A two-step request
 * sends the input twice, the second time with step 1's answer added. */
export function reservationCap(model: ModelConfig, input: AiInput, twoSteps: boolean): number {
  const step = inputCostBound(model, input) +
    Math.ceil(model.maxOutputTokens * model.outputMicroPerKilo / 1000);
  if (!twoSteps) return step;
  return 2 * step + Math.ceil(model.maxOutputTokens * model.inputMicroPerKilo / 1000);
}

export function outputBudget(
  model: ModelConfig,
  input: AiInput,
  reserved: number,
  unlimited: boolean,
): number {
  // Reasoning counts against this, often thousands of tokens before the
  // answer starts; the model config caps it, as for metered requests.
  if (unlimited) return model.maxOutputTokens;
  const inputCost = inputCostBound(model, input);
  const output = Math.min(
    model.maxOutputTokens,
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
function fixedInstruction(input: AiInput): string {
  return input.systemInstruction +
    "\nPrivacy: You receive this AI conversation's text, the current question, and selected image " +
    "crop. You cannot see the rest of the note or PDFs. Do not pretend you can.";
}

/** What changes from request to request: where the crop is, and the note. */
function requestInstruction(input: AiInput): string {
  return (input.notationContext
    ? "Crop on the note (page logical width and height; crop bounds note_normalized). Beyond " +
      "it you know only the metadata; never assume other paper is blank. " +
      JSON.stringify(input.notationContext)
    : "Return notation:null.") +
    (input.noteMetadata ? "\n\n" + input.noteMetadata : "");
}

function instruction(input: AiInput): string {
  return fixedInstruction(input) + " " + requestInstruction(input);
}

/** One of the two requests Claude answers in with Notation on: first the
 * explanation alone, then the notation that writes and draws it. */
export type ClaudeStep = { step: "text" } | { step: "notation"; message: string };

/** Whether [model] answers [input] in two steps. Claude cannot be held to
 * the whole answer's shape (its grammar is too large), and one answer that
 * both explains and draws often runs out before the drawing; split, the
 * words come first and always, and the drawing request has one job. */
export function twoStep(model: ModelConfig, input: AiInput): boolean {
  return model.provider === "claude" && input.notationContext !== undefined;
}

const textStep = "\nThis is step 1 of 2. Return only the explanation, in message, as the " +
  "instructions above describe; write no notation now. In step 2 you will be asked to " +
  "write and draw on the note following this explanation, so you may say briefly what you " +
  "are writing and drawing there, but never mention steps, requests, or doing it later: " +
  "the user sees one answer.";

const notationStep = "\nThis is step 2 of 2. Your previous message, the explanation, has " +
  "already been shown to the user. Following it, write and draw it on the note: return only a JSON " +
  'object {"notation": ...} holding the notation, exactly as the instructions above describe, ' +
  'animated only if they enable animation, or {"notation": null} when the explanation is a ' +
  "simple text answer. Write nothing else.";

/** Step 1's answer: the explanation alone. */
const textSchema = {
  type: "object",
  additionalProperties: false,
  properties: { message: { type: "string" } },
  required: ["message"],
};

/** The explanation in step 1's answer. */
export function stepMessage(answer: string): string {
  let message: unknown;
  try {
    message = JSON.parse(withoutFence(answer)).message;
  } catch {
    throw new Failure("server", 503);
  }
  if (typeof message !== "string" || !message.trim()) throw new Failure("server", 503);
  return message;
}

/** The answer the app reads, from step 1's explanation and step 2's answer,
 * or none: a drawing that cannot be read is left out, the words kept. */
export function combineSteps(message: string, notationAnswer: string | undefined): string {
  let notation: unknown = null;
  try {
    const parsed = JSON.parse(withoutFence(notationAnswer ?? ""));
    if (parsed && typeof parsed === "object") {
      // {"notation": {...}}, or, from a model that left out the wrapper, the
      // notation itself.
      notation = "notation" in parsed ? parsed.notation : "items" in parsed ? parsed : null;
    }
  } catch {
    // Words without a drawing.
  }
  return JSON.stringify({ version: 2, message, notation });
}

/** [text] without a Markdown code fence round it. */
function withoutFence(text: string): string {
  const body = text.trim();
  if (!body.startsWith("```")) return body;
  return body.replace(/^```[^\n]*\n?/, "").replace(/```\s*$/, "").trim();
}

export function providerRequest(
  model: ModelConfig,
  input: AiInput,
  maxOutput: number,
  key: string,
  claudeStep?: ClaudeStep,
): {
  url: string;
  headers: Record<string, string>;
  body: Record<string, unknown>;
} {
  const system = instruction(input);
  const history = input.history ?? [];
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
        // Not strict: strict mode needs every property required, and the
        // answer has optional fields. The schema still steers the shape.
        response_format: input.responseSchema
          ? {
            type: "json_schema",
            json_schema: { name: "etonia_answer", schema: input.responseSchema, strict: false },
          }
          : { type: "json_object" },
        messages: [
          { role: "system", content: system },
          ...history,
          {
            role: "user",
            content: [
              {
                type: "image_url",
                // Always the full-resolution read: misread handwriting
                // costs more than the image's tokens.
                image_url: {
                  url: `data:image/png;base64,${input.selectedImage}`,
                  detail: "high",
                },
              },
              { type: "text", text: input.prompt },
            ],
          },
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
            text: fixedInstruction(input),
            cache_control: { type: "ephemeral" },
          },
          {
            type: "text",
            text: requestInstruction(input) +
              (claudeStep?.step === "text" ? textStep : claudeStep ? notationStep : ""),
          },
        ],
        // The explanation is held to its one-field shape. The notation's
        // shape cannot be: Claude refuses its schema as too large a grammar
        // (a plot alone just fits), so the prompt's example and the app's
        // tolerant parser carry it.
        ...(claudeStep?.step === "text"
          ? { output_config: { format: { type: "json_schema", schema: textSchema } } }
          : {}),
        messages: [
          ...history,
          {
            role: "user",
            content: [
              {
                type: "image",
                source: { type: "base64", media_type: "image/png", data: input.selectedImage },
              },
              { type: "text", text: input.prompt },
            ],
          },
          ...(claudeStep?.step === "notation"
            ? [
              { role: "assistant", content: claudeStep.message },
              {
                role: "user",
                content: "Following your explanation, write and draw it on the note.",
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
        ...history.map((message) => ({
          role: message.role === "assistant" ? "model" : "user",
          parts: [{ text: message.content }],
        })),
        {
          role: "user",
          parts: [
            { inlineData: { mimeType: "image/png", data: input.selectedImage } },
            { text: input.prompt },
          ],
        },
      ],
      generationConfig: {
        maxOutputTokens: maxOutput,
        ...(model.reasoningEffort
          ? { thinkingConfig: { thinkingLevel: model.reasoningEffort } }
          : {}),
        responseMimeType: "application/json",
        ...(input.responseSchema ? { responseJsonSchema: input.responseSchema } : {}),
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
