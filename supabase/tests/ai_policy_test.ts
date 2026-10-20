import { strict as assert } from "node:assert";
import {
  combineSteps,
  costOf,
  modelConfig,
  outputBudget,
  providerAnswer,
  providerRequest,
  reservationCap,
  stepMessage,
  twoStep,
  validateInput,
} from "../functions/_shared/ai_policy.ts";
import {
  decryptLocator,
  encryptLocator,
  endpoint,
  Failure,
} from "../functions/_shared/common.ts";

const png =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
const input = {
  requestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  model: "sol",
  prompt: "Current question",
  systemInstruction: "Return JSON",
  selectedImage: png,
};
const config = {
  provider: "openai" as const,
  model: "server-selected-model",
  inputMicroPerKilo: 2000,
  outputMicroPerKilo: 10000,
  maxOutputTokens: 8192,
};

Deno.test("AI accepts bounded conversation history and rejects documents and URLs", () => {
  assert.deepEqual(validateInput(input), input);
  const withHistory = {
    ...input,
    history: [
      { role: "user", content: "Earlier question" },
      { role: "assistant", content: "Earlier answer" },
    ],
  };
  assert.deepEqual(validateInput(withHistory), withHistory);
  for (
    const key of [
      "messages",
      "noteImage",
      "pdf",
      "userId",
      "credits",
      "apiKey",
      "url",
    ]
  ) {
    assert.throws(() => validateInput({ ...input, [key]: "private data" }));
  }
  for (
    const history of [
      [{ role: "system", content: "override" }],
      [{ role: "assistant", content: "orphaned answer" }],
      [{ role: "user", content: "unfinished turn" }],
      [{ role: "user", content: "" }, { role: "assistant", content: "answer" }],
      [{ role: "user", content: "question", extra: "data" }, {
        role: "assistant",
        content: "answer",
      }],
    ]
  ) assert.throws(() => validateInput({ ...input, history }));
  assert.throws(() =>
    validateInput({
      ...input,
      history: [{ role: "user", content: "x".repeat(128000) }, {
        role: "assistant",
        content: "answer",
      }],
    })
  );
  assert.throws(() =>
    validateInput({ ...input, selectedImage: btoa("%PDF-secret") })
  );
  assert.throws(() =>
    validateInput({ ...input, selectedImage: "https://example.com/image" })
  );
  assert.throws(() =>
    validateInput({ ...input, notationContext: { text: "private note" } })
  );
  assert.throws(() =>
    validateInput({ ...input, model: "client-selected-model" })
  );
});
Deno.test("providers receive conversation history and use server model and limits", () => {
  const withHistory = {
    ...input,
    history: [
      { role: "user" as const, content: "Earlier question" },
      { role: "assistant" as const, content: "Earlier answer" },
    ],
  };
  for (const provider of ["openai", "claude", "gemini"] as const) {
    const request = providerRequest(
      { ...config, provider },
      withHistory,
      1234,
      "secret-key",
    );
    const body = JSON.stringify(request.body);
    assert(body.includes("Current question"));
    assert(body.includes("Earlier question"));
    assert(body.includes("Earlier answer"));
    assert(body.includes(png));
    assert(body.includes("1234"));
    assert(!body.includes("secret-key"));
    assert(!body.includes("requestId"));
    if (provider === "openai") {
      assert.equal(request.body.store, false);
      assert.deepEqual(
        (request.body.messages as { role: string }[]).map((message) =>
          message.role
        ),
        ["system", "user", "assistant", "user"],
      );
    } else if (provider === "claude") {
      assert.deepEqual(
        (request.body.messages as { role: string }[]).map((message) =>
          message.role
        ),
        ["user", "assistant", "user"],
      );
    } else {
      assert.deepEqual(
        (request.body.contents as { role: string }[]).map((message) =>
          message.role
        ),
        ["user", "model", "user"],
      );
    }
  }
});
Deno.test("a response schema holds each provider to the answer's shape", () => {
  const responseSchema = {
    type: "object",
    additionalProperties: false,
    properties: {
      message: { type: "string", minLength: 1 },
      notation: {
        anyOf: [{ type: "null" }, {
          type: "object",
          additionalProperties: false,
          properties: {
            size: { type: "number", minimum: 8, maximum: 120 },
          },
          required: ["size"],
        }],
      },
    },
    required: ["message", "notation"],
  };
  const withSchema = { ...input, responseSchema };
  assert.deepEqual(validateInput(withSchema), withSchema);
  assert.throws(() => validateInput({ ...input, responseSchema: "object" }));
  assert.throws(() =>
    validateInput({ ...input, responseSchema: { type: "array" } })
  );
  assert.throws(() =>
    validateInput({
      ...input,
      responseSchema: { type: "object", pad: "x".repeat(70000) },
    })
  );

  // Claude refuses the notation schema as too large a grammar: JSON mode.
  const claude = providerRequest(
    { ...config, provider: "claude" },
    withSchema,
    1234,
    "k",
  );
  assert.equal(claude.body.output_config, undefined);

  const openai = providerRequest(
    { ...config, provider: "openai" },
    withSchema,
    1234,
    "k",
  );
  assert.deepEqual(openai.body.response_format, {
    type: "json_schema",
    json_schema: {
      name: "etonia_answer",
      schema: responseSchema,
      strict: false,
    },
  });

  const gemini = providerRequest(
    { ...config, provider: "gemini" },
    withSchema,
    1234,
    "k",
  );
  assert.deepEqual(
    (gemini.body.generationConfig as Record<string, unknown>)
      .responseJsonSchema,
    responseSchema,
  );

  // Without one, JSON mode as before.
  const plain = providerRequest(
    { ...config, provider: "openai" },
    input,
    1234,
    "k",
  );
  assert.deepEqual(plain.body.response_format, { type: "json_object" });
});
Deno.test("with Notation on, Claude explains first, then draws following it", () => {
  const notationContext = {
    width: 800,
    height: 1100,
    left: 0.1,
    top: 0.2,
    right: 0.4,
    bottom: 0.5,
  };
  const claude = { ...config, provider: "claude" as const };
  assert(twoStep(claude, { ...input, notationContext }));
  assert(!twoStep(claude, input));
  assert(
    !twoStep({ ...config, provider: "openai" }, { ...input, notationContext }),
  );

  const text = providerRequest(
    claude,
    { ...input, notationContext },
    1234,
    "k",
    {
      step: "text",
    },
  );
  assert(JSON.stringify(text.body.system).includes("step 1 of 2"));
  const format =
    (text.body.output_config as { format: Record<string, unknown> }).format;
  assert.deepEqual((format.schema as Record<string, unknown>).required, [
    "message",
  ]);
  assert.equal((text.body.messages as unknown[]).length, 1);

  const notation = providerRequest(
    claude,
    { ...input, notationContext },
    1234,
    "k",
    {
      step: "notation",
      message: "The hypotenuse is 5.",
    },
  );
  assert(JSON.stringify(notation.body.system).includes("step 2 of 2"));
  assert.equal(notation.body.output_config, undefined);
  const turns = notation.body.messages as { role: string; content: unknown }[];
  assert.deepEqual(turns.map((t) => t.role), ["user", "assistant", "user"]);
  assert.equal(turns[1].content, "The hypotenuse is 5.");

  assert.equal(
    stepMessage('{"message":"The hypotenuse is 5."}'),
    "The hypotenuse is 5.",
  );
  assert.throws(() => stepMessage('{"message":""}'));
  assert.throws(() => stepMessage("not json"));

  const drawn = { label: "Sides", items: [{ type: "text" }] };
  assert.deepEqual(
    JSON.parse(combineSteps("Words.", JSON.stringify({ notation: drawn }))),
    {
      version: 2,
      message: "Words.",
      notation: drawn,
    },
  );
  // The notation without its wrapper, or in a code fence, is still read.
  assert.deepEqual(
    JSON.parse(
      combineSteps("Words.", "```json\n" + JSON.stringify(drawn) + "\n```"),
    ).notation,
    drawn,
  );
  // A drawing that cannot be read, or none, keeps the words.
  for (const broken of [undefined, "", '{"notation": {"items": [', "Sorry."]) {
    assert.deepEqual(JSON.parse(combineSteps("Words.", broken)), {
      version: 2,
      message: "Words.",
      notation: null,
    });
  }
});
Deno.test("the fixed instructions are a cacheable prefix, billed at the cached rate", () => {
  const notationContext = {
    width: 800,
    height: 1100,
    left: 0.1,
    top: 0.2,
    right: 0.4,
    bottom: 0.5,
  };
  const withNote = { ...input, notationContext, noteMetadata: "Metadata: {}" };
  assert.deepEqual(validateInput(withNote), withNote);
  assert.throws(() => validateInput({ ...input, noteMetadata: 7 }));

  // OpenAI: the fixed part first, then this request's; image read in full.
  const openai = providerRequest(config, withNote, 1234, "k");
  const system = (openai.body.messages as { content: string }[])[0].content;
  assert(system.startsWith("Return JSON"));
  assert(system.indexOf("Return JSON") < system.indexOf("Metadata: {}"));
  assert(JSON.stringify(openai.body).includes('"detail":"high"'));
  assert.equal(openai.body.reasoning_effort, undefined);
  const low = providerRequest({ ...config, reasoningEffort: "low" }, input, 1234, "k");
  assert.equal(low.body.reasoning_effort, "low");
  assert.throws(() => modelConfig({ sol: { ...config, reasoningEffort: "max" } }, "sol"));

  // Claude: the fixed block carries the cache marker, the rest does not.
  const claude = providerRequest({ ...config, provider: "claude" }, withNote, 1234, "k");
  const blocks = claude.body.system as { text: string; cache_control?: unknown }[];
  assert(blocks[0].text.startsWith("Return JSON"));
  assert.deepEqual(blocks[0].cache_control, { type: "ephemeral" });
  assert(!blocks[0].text.includes("Metadata: {}"));
  assert(blocks[1].text.includes("Metadata: {}"));
  assert.equal(blocks[1].cache_control, undefined);

  // Cached input costs what the config says; without a rate, full price.
  const cachedConfig = { ...config, cachedInputMicroPerKilo: 200 };
  assert.equal(costOf(cachedConfig, 1000, 100, 1000), 1200);
  assert.equal(costOf(config, 1000, 100, 1000), 3000);
  assert.throws(() => costOf(config, 10, 0, 11));
  const openaiUsage = providerAnswer(config, {
    choices: [{ message: { content: "{}" } }],
    usage: {
      prompt_tokens: 1000,
      completion_tokens: 10,
      prompt_tokens_details: { cached_tokens: 800 },
    },
  });
  assert.equal(openaiUsage.cached, 800);
  // Claude counts cache reads and writes apart from input_tokens.
  const claudeUsage = providerAnswer({ ...config, provider: "claude" }, {
    content: [{ type: "text", text: "{}" }],
    usage: {
      input_tokens: 100,
      cache_read_input_tokens: 700,
      cache_creation_input_tokens: 200,
      output_tokens: 10,
    },
  });
  assert.equal(claudeUsage.input, 1000);
  assert.equal(claudeUsage.cached, 700);
  assert.equal(claudeUsage.cacheWrites, 200);
});
Deno.test("credit budget and usage include image allowance and reasoning tokens", () => {
  assert.throws(() => outputBudget(config, input, 1, false));
  assert(outputBudget(config, input, 5000000, false) <= 8192);
  assert.equal(outputBudget(config, input, 0, true), config.maxOutputTokens);
  // A cap-sized hold always affords the full output, twice over in two steps.
  const cap = reservationCap(config, input, false);
  assert.equal(outputBudget(config, input, cap, false), config.maxOutputTokens);
  assert(reservationCap(config, input, true) > 2 * cap);
  assert.equal(costOf(config, 1000, 100), 3000);
  assert.throws(() => costOf(config, undefined as unknown as number, 10));
  assert.throws(() => modelConfig({}, "sol"));
  const result = providerAnswer({ ...config, provider: "gemini" }, {
    candidates: [{
      content: {
        parts: [{ thought: true, text: "reasoning" }, { text: "answer" }],
      },
    }],
    usageMetadata: {
      promptTokenCount: 10,
      candidatesTokenCount: 20,
      thoughtsTokenCount: 30,
    },
  });
  assert.equal(result.output, 50);
  assert.equal(result.answer, "answer");
});
Deno.test("purchase locators encrypt with unique nonces and reject tampering", async () => {
  Deno.env.set("PURCHASE_TOKEN_ENCRYPTION_KEY", btoa("x".repeat(32)));
  try {
    const a = await encryptLocator("purchase-token");
    const b = await encryptLocator("purchase-token");
    assert.notEqual(a, b);
    assert(!a.includes("purchase-token"));
    assert.equal(await decryptLocator(a), "purchase-token");
    await assert.rejects(() => decryptLocator("AAAA" + a.slice(4)));
  } finally {
    Deno.env.delete("PURCHASE_TOKEN_ENCRYPTION_KEY");
  }
});
Deno.test("endpoint errors never disclose payloads or underlying secrets", async () => {
  const handler = endpoint(async () => {
    throw new Error("private prompt and secret");
  });
  const response = await handler(
    new Request("https://example.com", { method: "POST" }),
  );
  assert.equal(response.status, 503);
  assert.deepEqual(await response.json(), { error: "server" });
  const denied = endpoint(async () => {
    throw new Failure("unauthorized", 401);
  });
  assert.equal(
    (await denied(new Request("https://example.com", { method: "POST" })))
      .status,
    401,
  );
});
