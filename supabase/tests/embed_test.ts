import { strict as assert } from "node:assert";
import { Failure } from "../functions/_shared/common.ts";
import {
  defaultEmbedConfig,
  embedConfig,
  embedCost,
  embedDimensions,
  promptFor,
  providerEmbedRequest,
  readEmbeddings,
  validateEmbed,
} from "../functions/_shared/embed_policy.ts";

const id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const png =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2FAAAAABJRU5ErkJggg==";

const rejected = (body: Record<string, unknown>) =>
  assert.throws(
    () => validateEmbed(body),
    (error) => error instanceof Failure && error.code === "rejected",
  );

Deno.test("an embedding request is checked before anything is sent on", () => {
  const ok = validateEmbed({
    requestId: id,
    kind: "document",
    inputs: [{ text: "hi" }, { image: png }],
  });
  assert.equal(ok.inputs.length, 2);
  rejected({ requestId: "nope", kind: "document", inputs: [{ text: "hi" }] });
  rejected({ requestId: id, kind: "other", inputs: [{ text: "hi" }] });
  rejected({ requestId: id, kind: "document", inputs: [] });
  rejected({ requestId: id, kind: "document", inputs: Array(17).fill({ text: "x" }) });
  rejected({ requestId: id, kind: "document", inputs: [{ text: "x", image: png }] });
  rejected({ requestId: id, kind: "document", inputs: [{}] });
  rejected({ requestId: id, kind: "document", inputs: [{ text: "  " }] });
  rejected({ requestId: id, kind: "document", inputs: [{ text: "x".repeat(6001) }] });
  rejected({ requestId: id, kind: "document", inputs: [{ image: "not a png" }] });
  rejected({ requestId: id, kind: "query", inputs: [{ image: png }] });
  rejected({ requestId: id, kind: "document", inputs: [{ text: "x" }], model: "other" });
  rejected({ requestId: id, kind: "document", inputs: [{ text: "x", extra: 1 }] });
});

Deno.test("each input is its own embedding, with the prompt its kind needs", () => {
  const request = validateEmbed({ requestId: id, kind: "query", inputs: [{ text: "flip flop" }] });
  const sent = providerEmbedRequest(defaultEmbedConfig, "key", request) as any;
  assert.ok(sent.url.endsWith("models/gemini-embedding-2:batchEmbedContents"));
  assert.equal(sent.headers["x-goog-api-key"], "key");
  assert.equal(sent.body.requests.length, 1);
  assert.equal(sent.body.requests[0].output_dimensionality, embedDimensions);
  assert.equal(
    sent.body.requests[0].content.parts[0].text,
    "task: search result | query: flip flop",
  );
  const documents = providerEmbedRequest(
    defaultEmbedConfig,
    "key",
    validateEmbed({ requestId: id, kind: "document", inputs: [{ text: "a" }, { image: png }] }),
  ) as any;
  assert.equal(documents.body.requests[0].content.parts[0].text, promptFor("document", "a"));
  assert.deepEqual(documents.body.requests[1].content.parts[0], {
    inline_data: { mime_type: "image/png", data: png },
  });
});

Deno.test("what the provider answers is read strictly, as float32 in base64", () => {
  const values = Array.from({ length: embedDimensions }, (_, i) => i / 1000);
  const [first] = readEmbeddings({ embeddings: [{ values }] }, 1);
  const bytes = Uint8Array.from(atob(first), (c) => c.charCodeAt(0));
  const decoded = new Float32Array(bytes.buffer);
  assert.equal(decoded.length, embedDimensions);
  assert.ok(Math.abs(decoded[500] - 0.5) < 1e-6);
  const bad = (body: unknown, count = 1) =>
    assert.throws(
      () => readEmbeddings(body, count),
      (error) => error instanceof Failure && error.code === "server",
    );
  bad({});
  bad({ embeddings: [] });
  bad({ embeddings: [{ values: [1, 2, 3] }] });
  bad({ embeddings: [{ values }] }, 2);
  bad({ embeddings: [{ values: values.map(() => "x") }] });
});

Deno.test("cost is the provider's price, rounded up, and configurable", () => {
  // A picture is 120 micro-USD; 4,000 characters of text 1,005 tokens with its prompt, at $0.20 a million.
  assert.equal(embedCost(defaultEmbedConfig, [{ image: png }]), 120);
  assert.equal(embedCost(defaultEmbedConfig, [{ text: "x".repeat(4000) }]), 201);
  assert.equal(embedCost({ ...defaultEmbedConfig, imageMicro: 200 }, [{ image: png }]), 200);
  assert.equal(embedConfig(undefined).model, "gemini-embedding-2");
  assert.equal(embedConfig('{"imageMicro": 5}').imageMicro, 5);
  assert.throws(() => embedConfig("{nope"), (error) => error instanceof Failure);
  assert.throws(() => embedConfig('{"model":"a b"}'), (error) => error instanceof Failure);
});
