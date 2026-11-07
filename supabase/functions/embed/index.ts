import {
  admin,
  endpoint,
  Failure,
  json,
  readBody,
  rpc,
  secret,
  userFor,
} from "../_shared/common.ts";
import {
  embedConfig,
  embedCost,
  embedDimensions,
  embedTokens,
  maxEmbedBody,
  providerEmbedRequest,
  readEmbeddings,
  validateEmbed,
} from "../_shared/embed_policy.ts";
import { reconcile } from "../_shared/stores.ts";

/**
 * Turns the text or picture of a chunk of the user's notes into a vector and
 * hands it back. Stateless: nothing sent here is stored or logged, the app
 * keeps the vectors, and only the cost is recorded against the account.
 */
Deno.serve(endpoint(async (req) => {
  const db = admin();
  const user = await userFor(req, db);
  const request = validateEmbed(await readBody(req, maxEmbedBody));
  const config = embedConfig(Deno.env.get("AI_EMBED_CONFIG"));
  const key = secret("GEMINI_API_KEY");
  // Live store verification fails closed, as for an answer.
  await reconcile(db, user);
  await rpc(db, "embed_admit", { p_user: user });

  let answer: unknown;
  try {
    const sent = providerEmbedRequest(config, key, request);
    const response = await fetch(sent.url, {
      method: "POST",
      headers: { ...sent.headers, "Content-Type": "application/json" },
      body: JSON.stringify(sent.body),
      signal: AbortSignal.timeout(30000),
      redirect: "error",
    });
    if (!response.ok) throw new Failure("server", 503);
    answer = await response.json();
  } catch (error) {
    throw error instanceof Failure ? error : new Failure("server", 503);
  }
  const embeddings = readEmbeddings(answer, request.inputs.length);
  // Charged only for what was delivered.
  await rpc(db, "embed_settle", {
    p_user: user,
    p_request: request.requestId,
    p_cost: embedCost(config, request.inputs),
    p_input: embedTokens(request.inputs),
  });
  return json({ dimensions: embedDimensions, embeddings });
}));
