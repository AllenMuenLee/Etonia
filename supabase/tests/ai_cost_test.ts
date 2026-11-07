import { strict as assert } from "node:assert";
import {
  costOf,
  modelConfig,
  providerAnswer,
  providerRequest,
  reservationCap,
  validateInput,
} from "../functions/_shared/ai_policy.ts";
import { describePass } from "../functions/_shared/ai_usage.ts";

const config = {
  provider: "openai" as const,
  model: "gpt-6.1-sol",
  inputMicroPerKilo: 2000,
  outputMicroPerKilo: 10000,
  maxOutputTokens: 16384,
};
const input = {
  requestId: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  model: "auto",
  prompt: "What is a latch?",
  systemInstruction: "Teach and cite the supplied evidence.",
  selectedImage:
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg==",
};

Deno.test("known Standard model prices include cache reads/writes and preserve overrides", () => {
  const sol = modelConfig({ sol: config }, "sol");
  assert.equal(sol.cachedInputMicroPerKilo, 100);
  assert.equal(sol.cacheWriteMicroPerKilo, 2500);
  assert.equal(costOf(sol, 2000, 100, 1000, 500), 3350);
  assert.equal(
    modelConfig({ sol: { ...config, cachedInputMicroPerKilo: 50 } }, "sol").cachedInputMicroPerKilo,
    50,
  );
  assert.equal(
    modelConfig({ sol: { ...config, inputMicroPerKilo: 1900 } }, "sol").cacheMode,
    undefined,
  );
  assert.throws(() => modelConfig({ sol: { ...config, cacheWriteMicroPerKilo: -1 } }, "sol"));
  assert(reservationCap(sol, input) > reservationCap(config, input));
  const haiku = {
    provider: "claude" as const,
    model: "claude-haiku-5-5",
    inputMicroPerKilo: 100,
    outputMicroPerKilo: 500,
    maxOutputTokens: 16384,
  };
  assert.equal(modelConfig({ haiku }, "haiku").cachedInputMicroPerKilo, 10);
  assert.equal(
    modelConfig({ haiku: { ...haiku, cachedInputMicroPerKilo: 75 } }, "haiku")
      .cachedInputMicroPerKilo,
    75,
  );
  assert.equal(
    modelConfig({ haiku: { ...haiku, model: "unknown-haiku" } }, "haiku").cachedInputMicroPerKilo,
    undefined,
  );
});

Deno.test("cache boundary ends at stable developer instructions, not retrieved source data", () => {
  const sol = modelConfig({ sol: config }, "sol");
  const sent = providerRequest(sol, { ...input, responseFormat: "text" }, 4096, "secret");
  assert.deepEqual(sent.body.prompt_cache_options, { mode: "explicit" });
  const messages = sent.body.messages as any[];
  assert.equal(messages[0].role, "developer");
  assert.deepEqual(messages[0].content[0].prompt_cache_breakpoint, { mode: "explicit" });
  assert(!JSON.stringify(messages[0]).includes(input.prompt));
  assert(!JSON.stringify(messages.slice(1)).includes("prompt_cache_breakpoint"));
  const json = providerRequest(sol, { ...input, responseFormat: "json" }, 4096, "secret");
  assert.deepEqual(json.body.response_format, { type: "json_object" });
  const old = providerRequest(
    { ...config, model: "gpt-4.1", cacheMode: "explicit" },
    input,
    4096,
    "secret",
  );
  assert.equal(old.body.prompt_cache_options, undefined);
});

Deno.test("OpenAI write/reasoning subtotals are recorded without double-counting completion tokens", () => {
  const model = modelConfig({ sol: config }, "sol");
  const usage = providerAnswer(model, {
    choices: [{ message: { content: "Answer" }, finish_reason: "stop" }],
    usage: {
      prompt_tokens: 2000,
      completion_tokens: 100,
      prompt_tokens_details: { cached_tokens: 1000, cache_write_tokens: 500, image_tokens: 10 },
      completion_tokens_details: { reasoning_tokens: 60 },
    },
  });
  const pass = describePass("sol", model, "low", "answer", usage);
  assert.equal(pass.inputCostMicro, 2350);
  assert.equal(pass.outputCostMicro, 1000);
  assert.equal(pass.costMicro, 3350);
  assert.equal(pass.reasoningTokens, 60);
  assert.equal(pass.outputTokens, 100);
  assert.equal(pass.imageTokens, 10);
  assert.equal(Object.keys(pass).length, 19);
  assert(!JSON.stringify(pass).includes("Answer"));
  assert.throws(() => describePass("sol", model, "low", "answer", { ...usage, reasoning: 101 }));
});

Deno.test("fractional input/output costs plus rounding reconcile exactly to billed total", () => {
  const model = { ...config, inputMicroPerKilo: 100, outputMicroPerKilo: 500 };
  const pass = describePass("luna", model, "low", "answer", {
    input: 1,
    output: 1,
    cached: 0,
    cacheWrites: 0,
  });
  assert.equal(pass.costMicro, 1);
  assert.equal(pass.inputCostMicro + pass.outputCostMicro + pass.roundingCostMicro, 1);
});

Deno.test("plain transport and opaque turn IDs validate, but cannot request drawing/grading", () => {
  assert.equal(
    validateInput({ ...input, responseFormat: "json", turnId: input.requestId }).responseFormat,
    "json",
  );
  assert.throws(() => validateInput({ ...input, turnId: "a question or a title" }));
  assert.throws(() => validateInput({ ...input, responseFormat: "html" }));
  assert.throws(() => validateInput({ ...input, responseFormat: "text", task: "testGrading" }));
});
