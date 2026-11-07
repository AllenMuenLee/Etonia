import { strict as assert } from "node:assert";
import {
  answerParagraphs,
  answerReserve,
  billingModel,
  combineSteps,
  configuredDrawingModel,
  costOf,
  drawingRequest,
  meterPass,
  modelConfig,
  outputBudget,
  providerAnswer,
  providerRequest,
  readProviderStream,
  requestModel,
  reservationCap,
  stepMessage,
  twoStep,
  validateInput,
} from "../functions/_shared/ai_policy.ts";
import { decryptLocator, encryptLocator, endpoint, Failure } from "../functions/_shared/common.ts";

const png =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=";
const selectedSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 800 1100" ' +
  'data-etonia-coordinate-space="note" data-etonia-selection-bounds="80 220 240 330">' +
  '<path data-etonia-kind="existing-ink" d="M80 220 L320 550"/></svg>';
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

Deno.test("chat instructions focus on the answer without exposing the drawing workflow", () => {
  for (const provider of ["openai", "claude", "gemini"] as const) {
    const request = providerRequest(
      { ...config, provider },
      {
        ...input,
        notationInstruction: "DRAWING_ONLY_INSTRUCTIONS",
        selectedSvg,
        notationContext: { width: 800, height: 1100, left: 0, top: 0, right: 1, bottom: 1 },
      },
      8192,
      "server-key",
      { step: "text" },
    );
    const body = JSON.stringify(request.body);
    assert(body.includes("complete explanation in the message desc"));
    assert(body.includes("subject title"));
    assert(!/separate step|drawing|notation|annotation|do not|never|cannot/i.test(body));
    assert(!body.includes("data-etonia-kind"));
  }
});

Deno.test("test grading uses the server notation model in a single metered pass", () => {
  const grading = validateInput({
    ...input,
    task: "testGrading",
    selectedSvg,
    notationContext: { width: 800, height: 1100, left: 0, top: 0, right: 1, bottom: 1 },
  });
  assert.equal(requestModel(grading, "haiku"), "haiku");
  assert.equal(requestModel(grading, undefined), "luna");
  assert.equal(requestModel(validateInput(input), "haiku"), "sol");
  assert.equal(twoStep(config, grading), false);
  const sent = providerRequest(config, grading, 8192, "server-key").body as any;
  assert.equal(sent.stream, false);
  assert.ok(
    sent.messages.at(-1).content.some((part: any) =>
      part.type === "text" && part.text.includes('data-etonia-kind="existing-ink"')
    ),
  );
  assert.ok(!sent.messages[0].content.includes("A separate step draws"));
  assert.throws(() => validateInput({ ...input, task: "unknown" }));
  assert.throws(() => requestModel(grading, "client-model"));
});

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
  assert.throws(() => validateInput({ ...input, selectedImage: btoa("%PDF-secret") }));
  assert.throws(() => validateInput({ ...input, selectedImage: "https://example.com/image" }));
  assert.deepEqual(
    validateInput({
      ...input,
      selectedSvg,
      notationContext: {
        width: 800,
        height: 1100,
        left: 0.1,
        top: 0.2,
        right: 0.4,
        bottom: 0.5,
      },
    }),
    {
      ...input,
      selectedSvg,
      notationContext: {
        width: 800,
        height: 1100,
        left: 0.1,
        top: 0.2,
        right: 0.4,
        bottom: 0.5,
      },
    },
  );
  for (
    const invalidSvg of [
      "https://example.com/note.svg",
      '<svg viewBox="0 0 1 1"><script>alert(1)</script></svg>',
      '<svg viewBox="0 0 1 1" data-etonia-coordinate-space="note" ' +
      'data-etonia-selection-bounds="0 0 1 1"><image href="https://example.com/x.png"/></svg>',
    ]
  ) assert.throws(() => validateInput({ ...input, selectedSvg: invalidSvg }));
  assert.throws(() => validateInput({ ...input, notationContext: { text: "private note" } }));
  assert.throws(() => validateInput({ ...input, model: "client-selected-model" }));
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
        (request.body.messages as { role: string }[]).map((message) => message.role),
        ["system", "user", "assistant", "user"],
      );
    } else if (provider === "claude") {
      assert.deepEqual(
        (request.body.messages as { role: string }[]).map((message) => message.role),
        ["user", "assistant", "user"],
      );
    } else {
      assert.deepEqual(
        (request.body.contents as { role: string }[]).map((message) => message.role),
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
  assert.throws(() => validateInput({ ...input, responseSchema: { type: "array" } }));
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
    selectedSvg,
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
    assert(firstBody.includes(png));
    assert(!firstBody.includes("existing-ink"));

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
    assert(drawingBody.includes("existing-ink"));
    assert(drawingBody.includes("ANNOTATION INPUT"));
    assert(drawingBody.includes('QUESTION: \\"Current question\\"'));
    assert(drawingBody.includes('[P1] \\"Answer.\\"'));
    // Handwriting cannot be read from paths: the crop comes with the SVG,
    // the question, and the answer, all in one turn.
    assert(drawingBody.includes(png));
    assert(drawingBody.includes("Read what is written"));
    assert(
      drawingBody.indexOf(png) < drawingBody.indexOf("existing-ink") &&
        drawingBody.indexOf("existing-ink") < drawingBody.indexOf("ANNOTATION INPUT"),
    );
  }

  // An SVG with the crop embedded is not sent the picture twice.
  const rasterSvg = selectedSvg.replace(
    "<path",
    `<image href="data:image/png;base64,${png}" x="0" y="0" width="1" height="1"/><path`,
  );
  const rasterDrawing = JSON.stringify(
    providerRequest(
      claude,
      { ...input, ...notationOptions, selectedSvg: rasterSvg, notationContext },
      1234,
      "k",
      { step: "notation", message: "Answer." },
    ).body,
  );
  assert.equal(rasterDrawing.split(png).length, 2);
  assert(rasterDrawing.includes('href=\\"attached:selected-image\\"'));

  const text = providerRequest(
    claude,
    { ...input, ...notationOptions, notationContext },
    1234,
    "k",
    {
      step: "text",
    },
  );
  assert(JSON.stringify(text.body.system).includes("Answer the question fully"));
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
  // Only the drawing pass asks for an effort, and streams.
  assert.deepEqual(notation.body.output_config, { effort: "medium" });
  assert.equal(notation.body.stream, true);
  const turns = notation.body.messages as { role: string; content: unknown }[];
  assert.deepEqual(turns.map((t) => t.role), ["user"]);
  const notationPayload = JSON.stringify(turns[0].content);
  assert(notationPayload.includes("existing-ink"));
  assert(notationPayload.includes('QUESTION: \\"Current question\\"'));
  assert(notationPayload.includes('[P1] \\"The hypotenuse is 5.\\"'));

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
      assert(body.includes('QUESTION: \\"complete the inverted op amp\\"'));
      assert(body.includes('[P1] \\"Answer.\\"'));
      assert(body.includes("existing-ink"));
      assert(body.includes('\\"what is this?\\"'));
      assert(!body.includes("A triangle."));
      assert(body.includes("Interact with the selected SVG"));
      assert(body.includes("annotate the note or add animation to it"));
      assert(body.includes("annotate directly on the user's strokes"));
      assert(body.includes("preserve their original note and keep it readable"));
      assert(body.includes("Set data-etonia-paragraph"));
      // How to annotate is the model's choice.
      assert(!body.includes("default is static"));
      assert(!body.includes("Keep its words few"));
    }
    const staticText = drawingRequest(asked, "static");
    assert(staticText.includes("annotate the note"));
    assert(staticText.includes("annotate directly on the user's strokes"));
    assert(!staticText.includes("animat"));
    // An overlong question is clipped, so the drawing prompt stays bounded:
    // Under 3000 characters here with the current instructions.
    assert(
      drawingRequest({ ...asked, prompt: "x".repeat(5000) }).length < 3000,
    );
  }

  const answerSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" viewBox="0 0 1 1"><title>Answer</title><desc data-etonia-role="message">The hypotenuse is 5.</desc></svg>';
  assert.equal(
    stepMessage(answerSvg),
    "The hypotenuse is 5.",
  );
  assert.throws(() =>
    stepMessage('<svg viewBox="0 0 1 1"><desc data-etonia-role="message"></desc></svg>')
  );
  assert.throws(() => stepMessage("not svg"));
  assert.equal(
    stepMessage(
      '```svg\n<svg viewBox="0 0 1 1"><desc data-etonia-role="message">Flow.</desc></svg>\n```',
    ),
    "Flow.",
  );

  const drawn =
    '<svg xmlns="http://www.w3.org/2000/svg" data-etonia-version="1" viewBox="0 0 10 10"><desc data-etonia-role="message">Draft.</desc><path d="M0 0L10 10"/></svg>';
  const combined = combineSteps("Words & symbols.", drawn);
  assert(combined.includes('<path d="M0 0L10 10"/>'));
  assert(combined.includes("Words &amp; symbols."));
  assert(!combined.includes("Draft."));
  assert(combineSteps("Words.", `\`\`\`svg\n${drawn}\n\`\`\``).includes("<path"));
  assert(combineSteps("Words.", `<?xml version="1.0"?>\n${drawn}`).includes("<path"));

  // A drawing that cannot be read, or none, becomes a message-only SVG.
  for (const broken of [undefined, "", "<svg", "Sorry."]) {
    const fallback = combineSteps("Words.", broken);
    assert(fallback.startsWith("<svg"));
    assert(fallback.includes('data-etonia-role="message">Words.</desc>'));
    assert(!fallback.includes("<path"));
  }
  const truncated = drawn.replace(/<\/svg>$/, '<path d="M1');
  const recoverable = combineSteps("Words.", truncated);
  assert(recoverable.includes('<path d="M0 0L10 10"/>'));
  assert(recoverable.includes('data-etonia-role="message">Words.</desc>'));
  assert(recoverable.endsWith('<path d="M1'));
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
    selectedSvg,
  };
  assert.deepEqual(validateInput(withNote), withNote);
  assert.throws(() => validateInput({ ...input, noteMetadata: 7 }));

  // OpenAI: the fixed part first, then this request's crop and SVG context.
  const openai = providerRequest(config, withNote, 1234, "k", {
    step: "notation",
    message: "Answer.",
    visual: "static",
  });
  const system = (openai.body.messages as { content: string }[])[0].content;
  assert(system.startsWith("Notation is on."));
  assert(system.indexOf("Notation is on.") < system.indexOf("Metadata: {}"));
  assert(JSON.stringify(openai.body).includes("existing-ink"));
  assert(JSON.stringify(openai.body).includes('"image_url"'));
  assert.equal(openai.body.reasoning_effort, "medium");
  assert.equal(openai.body.stream, true);
  assert.deepEqual(openai.body.stream_options, { include_usage: true });
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
  assert.deepEqual(claude.body.output_config, { effort: "medium" });
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
    { thinkingLevel: "MEDIUM" },
  );
  assert(gemini.url.endsWith(":streamGenerateContent?alt=sse"));
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
  assert.equal(outputBudget(config, input, 1, false), config.maxOutputTokens);
  assert.equal(outputBudget(config, input, 5000000, false), config.maxOutputTokens);
  assert.equal(outputBudget(config, input, 0, true), config.maxOutputTokens);
  assert.equal(
    outputBudget({ ...config, maxOutputTokens: 64000 }, input, 0, true),
    16384,
  );
  // A remaining balance above 0 affords the full output.
  const cap = reservationCap(config, input);
  assert.equal(outputBudget(config, input, cap, false), config.maxOutputTokens);
  // With Notation on, the drawing model handles the drawing pass, and
  // the answer affords its full text output cap.
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
  assert.equal(outputBudget(config, noted, answerReserve(0, drawer, noted), false, true), 8192);
  // A sixth of the $0.50 free credit still pays for a Sonnet-priced
  // notation request with a realistic note: the crop's allowance must not
  // swallow the whole balance before any output is afforded.
  const sonnet = {
    ...config,
    inputMicroPerKilo: 2000,
    outputMicroPerKilo: 10000,
    maxOutputTokens: 16384,
  };
  const everyday = {
    ...noted,
    notationInstruction: "N".repeat(6000),
    noteMetadata: "M".repeat(8000),
    responseSchema: undefined,
  };
  const low = Math.min(80000, reservationCap(sonnet, everyday, drawer));
  assert(outputBudget(sonnet, everyday, answerReserve(low, drawer, everyday), false, true) >= 1024);
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
Deno.test("answer and notation passes are each charged at their own model rates", () => {
  const answer = {
    ...config,
    inputMicroPerKilo: 2000,
    outputMicroPerKilo: 10000,
  };
  const notation = {
    ...config,
    inputMicroPerKilo: 100,
    outputMicroPerKilo: 500,
  };
  const answerUsage = { input: 100, output: 20, cached: 0, cacheWrites: 0 };
  const notationUsage = { input: 300, output: 40, cached: 0, cacheWrites: 0 };

  const first = meterPass(undefined, answer, answerUsage);
  const both = meterPass(first, notation, notationUsage);

  assert.deepEqual(both, { cost: 450, inputTokens: 400, outputTokens: 60 });
  assert.equal(
    both.cost,
    costOf(answer, 100, 20) + costOf(notation, 300, 40),
  );
  // Combining the tokens and applying either model's rate would be wrong.
  assert.notEqual(both.cost, costOf(answer, 400, 60));
  assert.notEqual(both.cost, costOf(notation, 400, 60));
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

function sseBody(text: string, chunkSize = 7): ReadableStream<Uint8Array> {
  const bytes = new TextEncoder().encode(text);
  let offset = 0;
  return new ReadableStream({
    pull(controller) {
      if (offset >= bytes.length) return controller.close();
      controller.enqueue(bytes.slice(offset, offset += chunkSize));
    },
  });
}
const sse = (...events: unknown[]) =>
  events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
const streamModel = {
  model: "m",
  inputMicroPerKilo: 1000,
  outputMicroPerKilo: 1000,
  maxOutputTokens: 100,
};

Deno.test("a streamed drawing reads as the whole answer would, on every provider", async () => {
  const pieces: string[] = [];
  const openai = await readProviderStream(
    { ...streamModel, provider: "openai" },
    sseBody(
      sse(
        { choices: [{ delta: { content: "<svg>" } }] },
        { choices: [{ delta: { content: "</svg>" } }] },
        {
          choices: [],
          usage: {
            prompt_tokens: 10,
            completion_tokens: 4,
            prompt_tokens_details: { cached_tokens: 2 },
          },
        },
      ) + "data: [DONE]\n\n",
    ),
    (text) => pieces.push(text),
  );
  assert.deepEqual(pieces, ["<svg>", "</svg>"]);
  assert.deepEqual(openai, {
    answer: "<svg></svg>",
    input: 10,
    output: 4,
    cached: 2,
    cacheWrites: 0,
    reasoning: 0,
    imageTokens: null,
    finishReason: null,
  });

  const claude = await readProviderStream(
    { ...streamModel, provider: "claude" },
    sseBody(
      "event: message_start\n" +
        sse(
          {
            type: "message_start",
            message: {
              usage: {
                input_tokens: 5,
                cache_read_input_tokens: 3,
                cache_creation_input_tokens: 2,
                output_tokens: 1,
              },
            },
          },
          { type: "content_block_delta", delta: { type: "thinking_delta", thinking: "hm" } },
          { type: "content_block_delta", delta: { type: "text_delta", text: "<svg/>" } },
          { type: "message_delta", usage: { output_tokens: 9 } },
          { type: "message_stop" },
        ),
    ),
    () => {},
  );
  assert.deepEqual(claude, {
    answer: "<svg/>",
    input: 10,
    output: 9,
    cached: 3,
    cacheWrites: 2,
    reasoning: null,
    imageTokens: null,
    finishReason: null,
  });

  const gemini = await readProviderStream(
    { ...streamModel, provider: "gemini" },
    sseBody(
      sse(
        { candidates: [{ content: { parts: [{ text: "hm", thought: true }] } }] },
        { candidates: [{ content: { parts: [{ text: "<svg/>" }] } }] },
        {
          usageMetadata: {
            promptTokenCount: 6,
            candidatesTokenCount: 2,
            thoughtsTokenCount: 3,
          },
        },
      ),
    ),
    () => {},
  );
  assert.deepEqual(gemini, {
    answer: "<svg/>",
    cached: 0,
    cacheWrites: 0,
    input: 6,
    output: 5,
    reasoning: 3,
    imageTokens: null,
    finishReason: null,
  });
});

Deno.test("liveNotation is a boolean that only goes with a notation request", () => {
  const notationContext = {
    width: 800,
    height: 1100,
    left: 0.1,
    top: 0.2,
    right: 0.4,
    bottom: 0.5,
  };
  const withNote = { ...input, notationInstruction: "Draw", notationContext };
  assert.equal(validateInput({ ...withNote, liveNotation: true }).liveNotation, true);
  assert.throws(() => validateInput({ ...withNote, liveNotation: "yes" }), Failure);
  assert.throws(() => validateInput({ ...input, liveNotation: true }), Failure);
});

Deno.test("a broken drawing stream has no answer to bill", async () => {
  await assert.rejects(
    readProviderStream(
      { ...streamModel, provider: "claude" },
      sseBody(sse({ type: "error", error: { type: "overloaded_error" } })),
      () => {},
    ),
    Failure,
  );
  await assert.rejects(
    readProviderStream(
      { ...streamModel, provider: "openai" },
      sseBody("data: {not json\n\n"),
      () => {},
    ),
  );
  // Cut off before its usage, it reports none, like a whole answer without.
  const cut = await readProviderStream(
    { ...streamModel, provider: "openai" },
    sseBody(sse({ choices: [{ delta: { content: "<svg>" } }] })),
    () => {},
  );
  assert.equal(cut.input, undefined);
});

Deno.test("the service numbers an answer's paragraphs as the app does", () => {
  // The same cases as test/features/editor/ai/ai_citation_test.dart: the
  // number on a drawn stroke must find the same paragraph in both.
  const numbering: [string, number][] = [
    ["One.\n\nTwo.", 2],
    ["One.\n\n\n\nTwo.\n", 2],
    ["One.\nStill one.", 1],
    ["One.\n\n```\ncode\n\nmore code\n```\n\nThree.", 3],
    ["One.\n\n$$\na\n\nb\n$$\n\nThree.", 3],
    ["One.\n\n$$a$$\n\nThree.", 3],
    ['One.\n\n<svg viewBox="0 0 10 10">\n\n<circle r="2"/>\n</svg>\n\nThree.', 3],
    ["One.\n\n```svg\n<svg>\n\n</svg>\n```\n\nThree.", 3],
    ["One.\n\n[[L5-L9]]\n\nTwo.", 2],
    ["[[L5-L9]]\n\nOne.", 1],
    ["One.\n\n[[C 1 2 3 4]]\n\nTwo.", 2],
    ["", 0],
  ];
  for (const [answer, count] of numbering) {
    assert.equal(answerParagraphs(answer).length, count, JSON.stringify(answer));
  }
  // A citation alone on a line stays with the paragraph it follows.
  assert.deepEqual(answerParagraphs("One.\n\n[[L5-L9]]\n\nTwo."), [
    "One. [[L5-L9]]",
    "Two.",
  ]);
});

Deno.test("only the drawing is told how to cite, and the words never get the lines", () => {
  const cited = validateInput({
    ...input,
    notationContext: { width: 800, height: 1100, left: 0.1, top: 0.2, right: 0.4, bottom: 0.5 },
    notationInstruction: "Notation is on",
    selectedSvg,
    sourceLines: "L5-L9 note 80 220 240 30",
  });
  const model = {
    provider: "claude",
    model: "m",
    inputMicroPerKilo: 1,
    outputMicroPerKilo: 1,
    maxOutputTokens: 1024,
  } as const;
  const words = JSON.stringify(providerRequest(model, cited, 256, "k", { step: "text" }).body);
  // An older app still sends them; they go no further.
  assert(!words.includes("SOURCE LINES"));
  assert(!words.includes("L5-L9 note 80 220 240 30"));
  assert(!words.includes('data-etonia-role=\\"citation\\"'));

  const drawing = JSON.stringify(
    providerRequest(model, cited, 256, "k", {
      step: "notation",
      message: "First.\n\nSecond.",
    }).body,
  );
  assert(!drawing.includes("SOURCE LINES"));
  assert(drawing.includes("[P1]"));
  assert(drawing.includes("[P2]"));
  assert(drawing.includes("data-etonia-paragraph"));
  assert(drawing.includes('data-etonia-role=\\"citation\\"'));
  assert(drawing.includes("[[L12-L30]]"));

  // A request with Notation off has no drawing, and so cites nothing.
  const plain = validateInput({ ...input, sourceLines: "L5 note 1 2 3 4" });
  assert(!JSON.stringify(providerRequest(model, plain, 256, "k").body).includes("SOURCE LINES"));
  // Lines that go nowhere cost nothing, so nothing is held for them.
  const priced = { ...model, inputMicroPerKilo: 1000 };
  assert.equal(
    reservationCap(priced, cited, priced),
    reservationCap(priced, { ...cited, sourceLines: undefined }, priced),
  );
});

Deno.test("lines an older app sends must still be a short string", () => {
  assert.throws(() => validateInput({ ...input, sourceLines: 5 }));
  assert.throws(() => validateInput({ ...input, sourceLines: "x".repeat(16001) }));
});

Deno.test("a routed request is told how hard to think, and an older one is not", () => {
  const plain = (provider: "openai" | "claude" | "gemini", effort?: "low" | "high") =>
    providerRequest({ ...config, provider }, input, 8192, "server-key", undefined, effort)
      .body as any;
  assert.equal(plain("openai").reasoning_effort, undefined);
  assert.equal(plain("openai", "high").reasoning_effort, "high");
  assert.equal(plain("claude").thinking, undefined);
  assert.deepEqual(plain("claude", "low").output_config, { effort: "low" });
  assert.equal(plain("gemini").generationConfig.thinkingConfig, undefined);
  assert.equal(plain("gemini", "high").generationConfig.thinkingConfig.thinkingLevel, "HIGH");
  // The drawing pass keeps medium unless it was routed to another level.
  const drawing = (effort?: "low") =>
    providerRequest(config, input, 8192, "server-key", {
      step: "notation",
      message: "words",
    }, effort).body as any;
  assert.equal(drawing().reasoning_effort, "medium");
  assert.equal(drawing("low").reasoning_effort, "low");
  // Models are picked by the router when the app says `auto`.
  assert.equal(
    validateInput({ ...input, model: "auto", routing: { effort: "low" } }).model,
    "auto",
  );
  assert.throws(() => validateInput({ ...input, model: "gpt-5" }));
});

Deno.test("a Claude answer never sends an empty system block", () => {
  const claude = {
    provider: "claude" as const,
    model: "claude-test",
    inputMicroPerKilo: 1,
    outputMicroPerKilo: 1,
    maxOutputTokens: 1024,
  };
  const input = {
    requestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
    model: "auto",
    prompt: "hi",
    systemInstruction: "be brief",
    selectedImage: "iVBORw0KGgo=",
  } as any;
  for (
    const step of [undefined, { step: "text" }, {
      step: "notation",
      visual: "static",
      message: "x",
    }]
  ) {
    const sent = providerRequest(claude, input, 512, "key", step as any, "low");
    const blocks = (sent.body as any).system as { text: string }[];
    assert.ok(blocks.length >= 1);
    for (const block of blocks) assert.ok(block.text.trim().length > 0, JSON.stringify(step));
  }
});
