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
  answerReserve,
  combineSteps,
  costOf,
  drawingModel,
  modelConfig,
  outputBudget,
  providerAnswer,
  providerRequest,
  reservationCap,
  stepMessage,
  twoStep,
  validateInput,
} from "../_shared/ai_policy.ts";
import { reconcile } from "../_shared/stores.ts";

const providerKeys = {
  openai: "OPENAI_API_KEY",
  claude: "ANTHROPIC_API_KEY",
  gemini: "GEMINI_API_KEY",
};

Deno.serve(endpoint(async (req) => {
  const db = admin();
  const user = await userFor(req, db);
  await rpc(db, "billing_rate_limit", { p_user: user });
  const input = validateInput(await readBody(req, null));
  const catalog = JSON.parse(secret("AI_MODEL_CONFIG"));
  const model = modelConfig(catalog, input.model);
  const key = secret(providerKeys[model.provider]);
  // With Notation on, the user's model writes the words and a cheap fixed
  // model turns them into the drawing.
  const two = twoStep(model, input);
  const drawer = two ? modelConfig(catalog, drawingModel) : undefined;
  const drawerKey = drawer ? secret(providerKeys[drawer.provider]) : "";
  // Live store verification fails closed, including renewals, refunds and expiry.
  await reconcile(db, user);
  const reservation = await rpc(db, "ai_reserve", {
    p_user: user,
    p_request: input.requestId,
    p_model: input.model,
    p_max: reservationCap(model, input, drawer),
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
  const ask = async (
    provider: ReturnType<typeof providerRequest>,
    answerer: typeof model,
    timeoutMs = 90000,
  ) => {
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
        answerer,
        await readBody(
          new Request("https://local.invalid", {
            method: "POST",
            body: response.body,
            duplex: "half",
          } as RequestInit),
          null,
        ),
      ),
    };
  };
  try {
    // The drawing step is paid for out of the hold too, so the answer gets
    // what is left of it.
    const answerHold = drawer && !reservation.unlimited
      ? answerReserve(reservation.reserved, drawer, input)
      : reservation.reserved;
    const maxOutput = outputBudget(model, input, answerHold, reservation.unlimited, two);
    const started = Date.now();
    const first = await ask(
      providerRequest(model, input, maxOutput, key, two ? { step: "text" } : undefined),
      model,
    );
    if (!first.result) {
      // A definitive rejection has no answer to bill.
      await settle(0, 0, 0, true);
      settled = true;
      throw new Failure(first.refused === 429 ? "rate_limited" : "server", 503);
    }
    let tokensIn = first.result.input;
    let tokensOut = first.result.output;
    let cost = costOf(
      model,
      tokensIn,
      tokensOut,
      first.result.cached,
      first.result.cacheWrites,
    );
    let answer = first.result.answer;
    if (drawer && typeof answer === "string" && answer) {
      // The user's model has written the words from the clean crop; the
      // drawing model reads them with the gridded crop and draws them.
      let message: string;
      try {
        message = stepMessage(answer);
      } catch (error) {
        await settle(cost, tokensIn, tokensOut);
        settled = true;
        throw error;
      }
      let notationAnswer: string | undefined;
      try {
        // Within the app's wait for the whole answer, so the words still
        // arrive when the drawing runs long.
        const second = await ask(
          providerRequest(
            drawer,
            input,
            outputBudget(drawer, input, 0, true),
            drawerKey,
            {
              step: "notation",
              message,
              visual: input.animationAllowed === true ? undefined : "static",
            },
          ),
          drawer,
          Math.max(5000, 105000 - (Date.now() - started)),
        );
        if (second.result) {
          const { input: used, output, cached, cacheWrites } = second.result;
          cost += costOf(drawer, used, output, cached, cacheWrites);
          tokensIn += used;
          tokensOut += output;
          notationAnswer = second.result.answer;
        }
      } catch {
        // Timed out or unreadable: words without a drawing. Its usage, if
        // any, is unknown and not billed.
      }
      answer = combineSteps(message, notationAnswer);
    }
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
