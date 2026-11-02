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
  billingModel,
  combineSteps,
  configuredDrawingModel,
  meterPass,
  modelConfig,
  outputBudget,
  providerAnswer,
  providerRequest,
  readProviderStream,
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

function eventStream(
  message: string,
  finish: (send: (event: Record<string, unknown>) => void) => Promise<Record<string, unknown>>,
): Response {
  const encoder = new TextEncoder();
  let open = true;
  return new Response(
    new ReadableStream<Uint8Array>({
      async start(controller) {
        const send = (event: Record<string, unknown>) => {
          if (!open) return;
          try {
            controller.enqueue(
              encoder.encode(`data: ${JSON.stringify(event)}\n\n`),
            );
          } catch {
            open = false;
          }
        };
        // Phase one is useful on its own. Deliver it before waiting for the
        // separate notation model and keep doing the billed work even if the
        // client disconnects after receiving the words.
        send({ type: "message", message });
        try {
          send({ type: "result", ...await finish(send) });
        } catch (error) {
          send({
            type: "error",
            error: error instanceof Failure ? error.code : "server",
          });
        } finally {
          if (open) controller.close();
        }
      },
      cancel() {
        open = false;
      },
    }),
    {
      headers: {
        "Content-Type": "text/event-stream",
        "Cache-Control": "no-store",
        "Connection": "keep-alive",
      },
    },
  );
}

Deno.serve(endpoint(async (req) => {
  const db = admin();
  const user = await userFor(req, db);
  await rpc(db, "billing_rate_limit", { p_user: user });
  const input = validateInput(await readBody(req, null));
  const catalog = JSON.parse(secret("AI_MODEL_CONFIG"));
  const model = modelConfig(catalog, input.model);
  const key = secret(providerKeys[model.provider]);
  // The answer model is user-selected. Notation/animation is controlled only
  // by the server environment, with Luna as the default.
  const two = twoStep(model, input);
  const drawerAlias = two ? configuredDrawingModel(Deno.env.get("AI_NOTATION_MODEL")) : undefined;
  const drawer = drawerAlias ? modelConfig(catalog, drawerAlias) : undefined;
  const drawerKey = drawer ? secret(providerKeys[drawer.provider]) : "";
  // Live store verification fails closed, including renewals, refunds and expiry.
  await reconcile(db, user);
  const reservation = await rpc(db, "ai_reserve", {
    p_user: user,
    p_request: input.requestId,
    p_model: billingModel(input.model, drawerAlias),
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
    onText?: (text: string) => void,
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
    if (onText && response.body) {
      return { result: await readProviderStream(answerer, response.body, onText) };
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
    let usage = meterPass(undefined, model, first.result);
    let answer = first.result.answer;
    if (drawer && typeof answer === "string" && answer) {
      // The user's model has written the words from the clean crop; the
      // drawing model reads them with the same crop, plus its page-coordinate
      // SVG for positions, and draws them.
      let message: string;
      try {
        message = stepMessage(answer);
      } catch (error) {
        await settle(usage.cost, usage.inputTokens, usage.outputTokens);
        settled = true;
        throw error;
      }
      const finishNotation = async (onText: (text: string) => void = () => {}) => {
        let notationAnswer: string | undefined;
        try {
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
            onText,
          );
          if (second.result) {
            usage = meterPass(usage, drawer, second.result);
            notationAnswer = second.result.answer;
          }
        } catch {
          // Timed out or unreadable: keep the completed words. Its usage, if
          // any, is unknown and not billed.
        }
        answer = combineSteps(message, notationAnswer);
        await settle(usage.cost, usage.inputTokens, usage.outputTokens);
        settled = true;
        return {
          answer,
          usage: { inputTokens: usage.inputTokens, outputTokens: usage.outputTokens },
        };
      };
      if (req.headers.get("accept")?.includes("text/event-stream")) {
        return eventStream(message, (send) => {
          if (input.liveNotation !== true) return finishNotation();
          // An element can only have ended at a ">", so nothing new can be
          // drawn before one: the pieces between are sent together.
          let unsent = "";
          return finishNotation((text) => {
            unsent += text;
            if (text.includes(">")) {
              send({ type: "notation", delta: unsent });
              unsent = "";
            }
          });
        });
      }
      await finishNotation();
    }
    if (!settled) {
      await settle(usage.cost, usage.inputTokens, usage.outputTokens);
      settled = true;
    }
    if (typeof answer !== "string" || !answer) throw new Failure("server", 503);
    return json({
      answer,
      usage: { inputTokens: usage.inputTokens, outputTokens: usage.outputTokens },
    });
  } catch (error) {
    if (!sent && !settled) await settle(0, 0, 0, true);
    // A timeout, missing usage, or settlement failure leaves the reservation
    // pending. No automatic refund/retry: the provider may have charged already.
    // Only metadata survives for operator reconciliation, never the prompt.
    throw error;
  }
}));
