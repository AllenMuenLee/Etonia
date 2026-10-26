import { strict as assert } from "node:assert";
import {
  billingModel,
  combineSteps,
  configuredDrawingModel,
  drawingRequest,
  costOf,
  modelConfig,
  outputBudget,
  providerAnswer,
  providerRequest,
  answerReserve,
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
  systemInstruction: "Return SVG",
  selectedImage: png,
};
const config = {
  provider: "openai" as const,
  model: "server-selected-model",
  inputMicroPerKilo: 2000,
  outputMicroPerKilo: 10000,
  maxOutputTokens: 8192,
};

Deno.test("AI accepts complete conversation history and rejects documents and URLs", () => {
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
  const longHistory = {
    ...input,
    history: [{ role: "user" as const, content: "x".repeat(128000) }, {
      role: "assistant" as const,
      content: "answer",
    }],
  };
  assert.throws(() => validateInput(longHistory));
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
Deno.test("providers request SVG text without a JSON response schema", () => {
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
  const largeSchema = {
    ...input,
    responseSchema: { type: "object", pad: "x".repeat(70000) },
  };
  assert.deepEqual(validateInput(largeSchema), largeSchema);

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
  assert.equal(openai.body.response_format, undefined);

  const gemini = providerRequest(
    { ...config, provider: "gemini" },
    withSchema,
    1234,
    "k",
  );
  const generation = gemini.body.generationConfig as Record<string, unknown>;
  assert.equal(generation.responseMimeType, "text/plain");
  assert.equal(generation.responseJsonSchema, undefined);

  // The legacy client field is accepted for compatibility, but never reaches
  // a provider now that the response contract is SVG.
  const plain = providerRequest(
    { ...config, provider: "openai" },
    input,
    1234,
    "k",
  );
  assert.equal(plain.body.response_format, undefined);
});
Deno.test("with Notation on, the chosen model writes the words and a second model draws them", () => {
  const notationContext = {
    width: 800,
    height: 1100,
    left: 0.1,
    top: 0.2,
    right: 0.4,
    bottom: 0.5,
  };
  const claude = { ...config, provider: "claude" as const };
  const openai = { ...config, provider: "openai" as const };
  const gemini = { ...config, provider: "gemini" as const };
  const notationOptions = {
    notationInstruction: "Notation is on. Return the drawing SVG.",
    animationAllowed: true,
    notationImage: png,
  };
  assert(twoStep(claude, { ...input, ...notationOptions, notationContext }));
  assert(!twoStep(claude, input));
  assert(twoStep(
    { ...config, provider: "openai" },
    { ...input, ...notationOptions, notationContext },
  ));
  assert.throws(() =>
    validateInput({
      ...input,
      ...notationOptions,
      notationContext,
      notationModel: "luna",
    })
  );
  assert.equal(configuredDrawingModel(undefined), "luna");
  assert.equal(configuredDrawingModel("  astra  "), "astra");
  assert.throws(() => configuredDrawingModel("unknown"));
  assert.equal(billingModel("luna", "sol"), "sol");
  assert.equal(billingModel("astra", "luna"), "astra");
  assert.equal(billingModel("haiku", "luna"), "haiku");

  for (const provider of ["openai", "claude", "gemini"] as const) {
    const routed = {
      ...input,
      ...notationOptions,
      notationContext,
      noteMetadata: "EXPENSIVE_NOTE_METADATA",
    };
    const firstBody = JSON.stringify(
      providerRequest(
        { ...config, provider },
        routed,
        1234,
        "k",
        { step: "text" },
      ).body,
    );
    assert(firstBody.includes("Return SVG"));
    assert(!firstBody.includes("Notation is on"));
    assert(!firstBody.includes("EXPENSIVE_NOTE_METADATA"));

    const drawingBody = JSON.stringify(
      providerRequest(
        { ...config, provider },
        routed,
        1234,
        "k",
        { step: "notation", message: "Answer.", visual: "static" },
      ).body,
    );
    assert(drawingBody.includes("Notation is on"));
    assert(drawingBody.includes("EXPENSIVE_NOTE_METADATA"));
  }

  const text = providerRequest(
    claude,
    { ...input, ...notationOptions, notationContext },
    1234,
    "k",
    {
      step: "text",
    },
  );
  assert(JSON.stringify(text.body.system).includes("Answer fully"));
  assert.equal(text.body.output_config, undefined);
  assert.equal((text.body.messages as unknown[]).length, 1);

  const notation = providerRequest(
    claude,
    { ...input, ...notationOptions, notationContext },
    1234,
    "k",
    {
      step: "notation",
      message: "The hypotenuse is 5.",
      visual: "static",
    },
  );
  assert(
    JSON.stringify(notation.body.system).includes("self-contained SVG"),
  );
  // Only the drawing pass asks for high effort.
  assert.deepEqual(notation.body.output_config, { effort: "high" });
  const turns = notation.body.messages as { role: string; content: unknown }[];
  assert.deepEqual(turns.map((t) => t.role), ["user", "assistant", "user"]);
  assert.equal(turns[1].content, "The hypotenuse is 5.");

  // The drawing step is told what the user asked, on every provider, and
  // a follow-up keeps the requests that came before it.
  {
    const asked = {
      ...input,
      ...notationOptions,
      notationContext,
      prompt: "complete the inverted op amp",
      history: [
        { role: "user" as const, content: "what is this?" },
        { role: "assistant" as const, content: "A triangle." },
      ],
    };
    for (const model of [claude, openai, gemini]) {
      const body = JSON.stringify(
        providerRequest(model, asked, 1234, "k", {
          step: "notation",
          message: "Answer.",
        }).body,
      );
      assert(body.includes('The user asked: \\"complete the inverted op amp\\"'));
      assert(body.includes('\\"what is this?\\"'));
      assert(!body.includes("A triangle."));
      assert(body.includes("actively look for a useful note-grounded visual"));
      assert(body.includes("connect the annotation to the user's actual notes"));
      assert(body.includes("point a leader arrow at the relevant ink"));
      assert(body.includes("Animation is optional and the default is static"));
      assert(body.includes("physical motion, propagation or flow"));
      assert(body.includes("Never animate content merely to reveal it"));
      assert(body.includes("If uncertain, keep everything static"));
    }
    const staticText = drawingRequest(asked, "static");
    assert(staticText.includes("adding only what is missing"));
    assert(staticText.includes("connect the annotation to the user's actual notes"));
    assert(!staticText.includes("animate"));
    // An overlong question is clipped, so the drawing prompt stays bounded:
    // 2738 characters here with the current instructions.
    assert(
      drawingRequest({ ...asked, prompt: "x".repeat(5000) }).length < 2750,
    );
  }

  const answerSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" viewBox="0 0 1 1"><title>Answer</title><desc data-etonia-role="message">The hypotenuse is 5.</desc></svg>';
  assert.equal(
    stepMessage(answerSvg),
    "The hypotenuse is 5.",
  );
  assert.throws(() => stepMessage('<svg viewBox="0 0 1 1"><desc data-etonia-role="message"></desc></svg>'));
  assert.throws(() => stepMessage("not svg"));
  assert.equal(
    stepMessage('```svg\n<svg viewBox="0 0 1 1"><desc data-etonia-role="message">Flow.</desc></svg>\n```'),
    "Flow.",
  );

  const drawn =
    '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" viewBox="0 0 10 10"><desc data-etonia-role="message">Draft.</desc><path d="M0 0L10 10"/></svg>';
  const combined = combineSteps("Words & symbols.", drawn);
  assert(combined.includes('<path d="M0 0L10 10"/>'));
  assert(combined.includes("Words &amp; symbols."));
  assert(!combined.includes("Draft."));
  assert(combineSteps("Words.", `\`\`\`svg\n${drawn}\n\`\`\``).includes("<path"));

  // A drawing that cannot be read, or none, becomes a message-only SVG.
  for (const broken of [undefined, "", "<svg><path", "Sorry."]) {
    const fallback = combineSteps("Words.", broken);
    assert(fallback.startsWith("<svg"));
    assert(fallback.includes('data-etonia-role="message">Words.</desc>'));
    assert(!fallback.includes("<path"));
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
  const withNote = {
    ...input,
    notationContext,
    noteMetadata: "Metadata: {}",
    notationInstruction: "Notation is on.",
    animationAllowed: true,
    notationImage: png,
  };
  assert.deepEqual(validateInput(withNote), withNote);
  assert.throws(() => validateInput({ ...input, noteMetadata: 7 }));

  // OpenAI: the fixed part first, then this request's; image read in full.
  const openai = providerRequest(config, withNote, 1234, "k", {
    step: "notation",
    message: "Answer.",
    visual: "static",
  });
  const system = (openai.body.messages as { content: string }[])[0].content;
  assert(system.startsWith("Notation is on."));
  assert(system.indexOf("Notation is on.") < system.indexOf("Metadata: {}"));
  assert(JSON.stringify(openai.body).includes('"detail":"high"'));
  assert.equal(openai.body.reasoning_effort, "high");
  // A stale AI_MODEL_CONFIG may still carry the removed reasoningEffort
  // field; answers keep the provider default regardless.
  const legacy = { ...config, reasoningEffort: "low" };
  const defaultEffort = providerRequest(
    legacy,
    input,
    1234,
    "k",
  );
  assert.equal(defaultEffort.body.reasoning_effort, undefined);

  // Claude: the fixed block carries the cache marker, the rest does not.
  const claude = providerRequest(
    { ...config, provider: "claude" },
    withNote,
    1234,
    "k",
    { step: "notation", message: "Answer.", visual: "static" },
  );
  const blocks = claude.body.system as {
    text: string;
    cache_control?: unknown;
  }[];
  assert(blocks[0].text.startsWith("Notation is on."));
  assert.deepEqual(blocks[0].cache_control, { type: "ephemeral" });
  assert(!blocks[0].text.includes("Metadata: {}"));
  assert(blocks[1].text.includes("Metadata: {}"));
  assert.equal(blocks[1].cache_control, undefined);
  assert.deepEqual(claude.body.thinking, { type: "adaptive" });
  assert.deepEqual(claude.body.output_config, { effort: "high" });
  const claudeDefault = providerRequest(
    { ...config, provider: "claude" },
    input,
    1234,
    "k",
  );
  assert.equal(claudeDefault.body.thinking, undefined);
  assert.equal(claudeDefault.body.output_config, undefined);

  const gemini = providerRequest(
    { ...config, provider: "gemini" },
    withNote,
    1234,
    "k",
    { step: "notation", message: "Answer.", visual: "static" },
  );
  assert.deepEqual(
    (gemini.body.generationConfig as Record<string, unknown>).thinkingConfig,
    { thinkingLevel: "HIGH" },
  );
  const geminiDefault = providerRequest(
    { ...legacy, provider: "gemini" as const },
    input,
    1234,
    "k",
  );
  assert.equal(
    (geminiDefault.body.generationConfig as Record<string, unknown>)
      .thinkingConfig,
    undefined,
  );

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
  assert.equal(
    outputBudget({ ...config, maxOutputTokens: 64000 }, input, 0, true),
    16384,
  );
  // A cap-sized hold always affords the full output.
  const cap = reservationCap(config, input);
  assert.equal(outputBudget(config, input, cap, false), config.maxOutputTokens);
  // With Notation on, the hold also covers the cheaper drawing model, and
  // the answer is left what remains, which still affords its full output.
  const drawer = {
    ...config,
    inputMicroPerKilo: 100,
    outputMicroPerKilo: 500,
    maxOutputTokens: 16384,
  };
  const noted = {
    ...input,
    notationContext: {
      width: 800,
      height: 1100,
      left: 0.1,
      top: 0.2,
      right: 0.4,
      bottom: 0.5,
    },
    notationInstruction: "N".repeat(40000),
    noteMetadata: "M".repeat(40000),
    responseSchema: { type: "object", pad: "x".repeat(40000) },
  };
  const both = reservationCap(config, noted, drawer);
  // The notation grammar and note are read by the drawer, not billed at the
  // answering model's price, so this costs far less than the old two passes
  // of the answering model.
  assert(both < 2 * reservationCap(config, noted));
  assert(both > reservationCap(config, input));
  const left = answerReserve(both, drawer, noted);
  assert.equal(outputBudget(config, noted, left, false, true), 8192);
  assert.equal(outputBudget(config, noted, 0, true, true), 8192);
  assert.throws(() =>
    outputBudget(config, noted, answerReserve(0, drawer, noted), false, true)
  );
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
