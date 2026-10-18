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
  combineSteps,
  costOf,
  modelConfig,
  outputBudget,
  providerAnswer,
  providerRequest,
  stepMessage,
  twoStep,
  validateInput,
} from "../_shared/ai_policy.ts";
import { reconcile } from "../_shared/stores.ts";

Deno.serve(endpoint(async (req) => {
  const db = admin();
  const user = await userFor(req, db);
  await rpc(db, "billing_rate_limit", { p_user: user });
  const input = validateInput(await readBody(req, 6200000));
  const model = modelConfig(JSON.parse(secret("AI_MODEL_CONFIG")), input.model);
  const key = secret(
    {
      openai: "OPENAI_API_KEY",
      claude: "ANTHROPIC_API_KEY",
      gemini: "GEMINI_API_KEY",
    }[model.provider],
  );
  // Live store verification fails closed, including renewals, refunds and expiry.
  await reconcile(db, user);
  const reservation = await rpc(db, "ai_reserve", {
    p_user: user,
    p_request: input.requestId,
    p_model: input.model,
  });
  const settle = (cost: number, tokensIn = 0, tokensOut = 0, release = false) =>
    rpc(db, "ai_settle", {
      p_user: user,
      p_request: input.requestId,
      p_cost: cost,
      p_input: tokensIn,
      p_output: tokensOut,
      p_release: release,
    });
  let sent = false;
  let settled = false;
  /** Sends one provider request: its answer and usage, or null when the
   * provider refused it outright (nothing to bill). Never retried. */
  const ask = async (provider: ReturnType<typeof providerRequest>, timeoutMs = 90000) => {
    sent = true;
    const response = await fetch(provider.url, {
      method: "POST",
      headers: { ...provider.headers, "Content-Type": "application/json" },
      body: JSON.stringify(provider.body),
      signal: AbortSignal.timeout(timeoutMs),
      redirect: "error",
    });
    if (!response.ok) {
      await response.body?.cancel();
      return { refused: response.status };
    }
    return {
      result: providerAnswer(
        model,
        await readBody(
          new Request("https://local.invalid", {
            method: "POST",
            body: response.body,
            duplex: "half",
          } as RequestInit),
          512000,
        ),
      ),
    };
  };
  try {
    const maxOutput = outputBudget(model, input, reservation.reserved, reservation.unlimited);
    const two = twoStep(model, input);
    const started = Date.now();
    const first = await ask(
      providerRequest(model, input, maxOutput, key, two ? { step: "text" } : undefined),
    );
    if (!first.result) {
      // A definitive rejection has no answer to bill.
      await settle(0, 0, 0, true);
      settled = true;
      throw new Failure(first.refused === 429 ? "rate_limited" : "server", 503);
    }
    let tokensIn = first.result.input;
    let tokensOut = first.result.output;
    let answer = first.result.answer;
    if (two && typeof answer === "string" && answer) {
      // Step 2: the notation, following the explanation. Its failure costs
      // only the drawing: the words are kept.
      let message: string;
      try {
        message = stepMessage(answer);
      } catch (error) {
        await settle(costOf(model, tokensIn, tokensOut), tokensIn, tokensOut);
        settled = true;
        throw error;
      }
      let notationAnswer: string | undefined;
      try {
        // Within the app's wait for the whole answer, so the words still
        // arrive when the drawing runs long.
        const second = await ask(
          providerRequest(model, input, maxOutput, key, { step: "notation", message }),
          Math.max(5000, 105000 - (Date.now() - started)),
        );
        if (second.result) {
          tokensIn += second.result.input;
          tokensOut += second.result.output;
          notationAnswer = second.result.answer;
        }
      } catch {
        // Timed out or unreadable: words without a drawing. Its usage, if
        // any, is unknown and not billed.
      }
      answer = combineSteps(message, notationAnswer);
    }
    const cost = costOf(model, tokensIn, tokensOut);
    await settle(cost, tokensIn, tokensOut);
    settled = true;
    if (typeof answer !== "string" || !answer) throw new Failure("server", 503);
    return json({
      answer,
      usage: { inputTokens: tokensIn, outputTokens: tokensOut },
    });
  } catch (error) {
    if (!sent && !settled) await settle(0, 0, 0, true);
    // A timeout, missing usage, or settlement failure leaves the reservation
    // pending. No automatic refund/retry: the provider may have charged already.
    // Only metadata survives for operator reconciliation, never the prompt.
    throw error;
  }
}));
