import { Failure } from "./common.ts";

/**
 * Embeddings for Study Desk search: what the app may send, what is asked of the
 * provider, what comes back and what it costs. Pure, so it is tested without a
 * network. Nothing here is kept: the app stores the vectors it is given.
 */

/** Dimensions of every vector. Truncated by the provider, which normalizes them. */
export const embedDimensions = 768;

/** At most this many inputs in one request. */
export const maxEmbedInputs = 16;
/** Characters of one text input (about 1,500 tokens: a chunk is far smaller). */
export const maxEmbedText = 6000;
/** Characters of one picture's base64, about 1 MB of PNG. */
export const maxEmbedImage = 1_400_000;
/** The request body: sixteen pictures would not fit, which is the point. */
export const maxEmbedBody = 4_200_000;

export type EmbedKind = "document" | "query";

export interface EmbedInput {
  text?: string;
  /** A PNG, base64. */
  image?: string;
}

export interface EmbedRequest {
  requestId: string;
  kind: EmbedKind;
  inputs: EmbedInput[];
}

export interface EmbedConfig {
  model: string;
  /** Micro-USD per million text tokens. */
  textMicroPerMillion: number;
  /** Micro-USD per picture. */
  imageMicro: number;
}

/** Gemini Embedding 2 at standard prices; `AI_EMBED_CONFIG` overrides them. */
export const defaultEmbedConfig: EmbedConfig = {
  model: "gemini-embedding-2",
  textMicroPerMillion: 200_000,
  imageMicro: 120,
};

export function embedConfig(raw: string | undefined): EmbedConfig {
  if (!raw) return defaultEmbedConfig;
  try {
    const parsed = JSON.parse(raw);
    const config = { ...defaultEmbedConfig, ...parsed };
    if (
      typeof config.model !== "string" || !/^[a-z0-9.\-]+$/.test(config.model) ||
      !Number.isFinite(config.textMicroPerMillion) || config.textMicroPerMillion < 0 ||
      !Number.isFinite(config.imageMicro) || config.imageMicro < 0
    ) throw new Error();
    return config;
  } catch {
    throw new Failure("not_configured", 503);
  }
}

const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const pngBase64 = /^iVBORw0KGgo[A-Za-z0-9+/]*={0,2}$/;

export function validateEmbed(body: Record<string, unknown>): EmbedRequest {
  for (const key of Object.keys(body)) {
    if (!["requestId", "kind", "inputs"].includes(key)) throw new Failure("rejected");
  }
  const { requestId, kind, inputs } = body;
  if (typeof requestId !== "string" || !uuid.test(requestId)) throw new Failure("rejected");
  if (kind !== "document" && kind !== "query") throw new Failure("rejected");
  if (!Array.isArray(inputs) || inputs.length === 0 || inputs.length > maxEmbedInputs) {
    throw new Failure("rejected");
  }
  const checked: EmbedInput[] = inputs.map((raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) throw new Failure("rejected");
    const item = raw as Record<string, unknown>;
    for (const key of Object.keys(item)) {
      if (key !== "text" && key !== "image") throw new Failure("rejected");
    }
    const hasText = item.text !== undefined;
    const hasImage = item.image !== undefined;
    if (hasText === hasImage) throw new Failure("rejected"); // exactly one
    if (hasText) {
      if (
        typeof item.text !== "string" || item.text.trim() === "" || item.text.length > maxEmbedText
      ) {
        throw new Failure("rejected");
      }
      return { text: item.text };
    }
    if (kind === "query") throw new Failure("rejected"); // a query is words
    if (
      typeof item.image !== "string" || item.image.length > maxEmbedImage ||
      !pngBase64.test(item.image)
    ) throw new Failure("rejected");
    return { image: item.image };
  });
  return { requestId, kind, inputs: checked };
}

/** What the model is told a text is: the form it was trained to match. A
 * picture carries no such prefix. */
export function promptFor(kind: EmbedKind, text: string): string {
  return kind === "query" ? `task: search result | query: ${text}` : `title: none | text: ${text}`;
}

/** About how many tokens a text is. */
export const textTokens = (text: string) => Math.ceil(text.length / 4);

/** What the provider will charge, in micro-USD, rounded up. */
export function embedCost(config: EmbedConfig, inputs: readonly EmbedInput[]): number {
  let micro = 0;
  for (const input of inputs) {
    micro += input.image !== undefined
      ? config.imageMicro
      : textTokens(promptFor("document", input.text ?? "")) * config.textMicroPerMillion / 1e6;
  }
  return Math.ceil(micro);
}

/** Tokens, pictures counted as the provider counts them (about 1,000 each). */
export function embedTokens(inputs: readonly EmbedInput[]): number {
  return inputs.reduce(
    (sum, input) => sum + (input.image !== undefined ? 1000 : textTokens(input.text ?? "")),
    0,
  );
}

export function providerEmbedRequest(
  config: EmbedConfig,
  key: string,
  request: EmbedRequest,
): { url: string; headers: Record<string, string>; body: unknown } {
  return {
    url:
      `https://generativelanguage.googleapis.com/v1beta/models/${config.model}:batchEmbedContents`,
    headers: { "x-goog-api-key": key },
    body: {
      requests: request.inputs.map((input) => ({
        model: `models/${config.model}`,
        content: {
          parts: [
            input.image !== undefined
              ? { inline_data: { mime_type: "image/png", data: input.image } }
              : { text: promptFor(request.kind, input.text ?? "") },
          ],
        },
        output_dimensionality: embedDimensions,
      })),
    },
  };
}

/** The vectors of a provider answer, each as little-endian float32 in base64:
 * a quarter of the size of JSON numbers. Anything unexpected is a server error
 * and is not charged. */
export function readEmbeddings(body: any, count: number): string[] {
  const list = body?.embeddings;
  if (!Array.isArray(list) || list.length !== count) throw new Failure("server", 503);
  return list.map((entry: any) => {
    const values = entry?.values;
    if (
      !Array.isArray(values) || values.length !== embedDimensions ||
      !values.every((v: unknown) => typeof v === "number" && Number.isFinite(v))
    ) throw new Failure("server", 503);
    const bytes = new Uint8Array(new Float32Array(values).buffer);
    let text = "";
    for (const byte of bytes) text += String.fromCharCode(byte);
    return btoa(text);
  });
}
