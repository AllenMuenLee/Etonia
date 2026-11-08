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
  billingModel,
  combineSteps,
  configuredDrawingModel,
  type MeteredUsage,
  meterPass,
  modelConfig,
  outputBudget,
  providerAnswer,
  providerRequest,
  parseModelCatalog,
  readProviderStream,
  requestModel,
  stepMessage,
  twoStep,
  validateInput,
} from "../_shared/ai_policy.ts";
import {
  buildCatalog,
  type Decision,
  type DenyReason,
  type Effort,
  efforts,
  escalate,
  estimateInputTokens,
  failureCode,
  pairKey,
  parseRoutingRequest,
  planFromState,
  route,
  type RouteContext,
  type RouterModel,
  type RouterOverride,
  type Task,
} from "../_shared/ai_router.ts";
import { reconcile } from "../_shared/stores.ts";
import { describePass, type PassUsage } from "../_shared/ai_usage.ts";
import {
  isPlaceholderPng,
  studyDifficulty,
  studyOutputCeiling,
  studyQuestionKind,
  usableStudyResponse,
} from "../_shared/study_policy.ts";

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

/** Providers that just refused a request, and until when. Per instance and
 * short: it only steers the next requests away from an outage. */
const outages = new Map<string, number>();
const outageMs = 60_000;
const providersDown = () => {
  const now = Date.now();
  return [...outages].filter(([, until]) => until > now).map(([provider]) => provider);
};

/** A router refusal as the error the app already understands. */
function denial(reason: DenyReason): Failure {
  const code = failureCode(reason);
  return new Failure(code, code === "rejected" ? 400 : code === "server" ? 503 : 409);
}

/** Measured per-model strengths, from the evals, over the baseline. */
function routerOverrides(): Record<string, RouterOverride> {
  const raw = Deno.env.get("AI_ROUTER_CONFIG");
  if (!raw) return {};
  try {
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) throw new Error();
    return parsed;
  } catch {
    throw new Failure("not_configured", 503);
  }
}

const effortRank = (effort: Effort) => efforts.indexOf(effort);

Deno.serve(endpoint(async (req) => {
  const db = admin();
  const user = await userFor(req, db);
  await rpc(db, "billing_rate_limit", { p_user: user });
  const input = validateInput(await readBody(req, null));
  const catalog = parseModelCatalog(
    secret("AI_MODEL_CONFIG"),
    Deno.env.get("AI_MODEL_CONFIG_OVERRIDES"),
  );
  const routed = input.model === "auto";
  if (!routed && input.routing !== undefined) throw new Failure("rejected");
  // Live store verification fails closed, including renewals, refunds and expiry.
  await reconcile(db, user);

  // A routed request names no model: the router picks the cheapest capable
  // (model, effort). The task, effort setting and the models the user left on
  // come from the app. Everything it needs is read before anything is reserved.
  const routing = routed ? parseRoutingRequest(input.routing) : undefined;
  let routerCatalog: RouterModel[] = [];
  let context: RouteContext | undefined;
  let decision: Decision | undefined;
  if (routing) {
    const state = await rpc(db, "billing_state", { p_user: user });
    if (state.activePlan == null && state.grantedPurchaseId == null) {
      throw new Failure("plan_required", 409);
    }
    routerCatalog = buildCatalog(catalog, routerOverrides());
    const task: Task = input.task === "testGrading"
      ? "test.grading"
      : routing.task ?? "editor.answer";
    const withPicture = task.startsWith("editor.") || task === "test.grading";
    const placeholder = isPlaceholderPng(input.selectedImage);
    const needsVision = !placeholder || (routing.needsVision ?? withPicture);
    context = {
      task,
      setting: routing.setting,
      plan: planFromState(state),
      creditsMicro: Number(state.remainingCreditsMicroUsd ?? 0),
      allowed: routing.allowed,
      unhealthyProviders: providersDown(),
      previous: routing.previous,
      hints: {
        difficulty: studyDifficulty(
          task,
          input,
          routing.difficulty ?? 2,
          needsVision,
          routing.diagrams,
        ),
        needsVision,
        studyPolicyVersion: input.responseFormat ? input.studyPolicyVersion : undefined,
        studyQuestionKind: task.startsWith("study.")
          ? studyQuestionKind(input.prompt, input.history)
          : undefined,
        diagrams: routing.diagrams,
        inputTokens: estimateInputTokens([
          input.prompt,
          input.systemInstruction,
          input.notationInstruction,
          input.noteMetadata,
          input.selectedSvg,
          JSON.stringify(input.history ?? []),
        ], input.notationImage ? 2 : placeholder ? 0 : 1) + (placeholder ? 64 : 0),
        cacheablePrefixTokens: estimateInputTokens([
          input.systemInstruction,
          JSON.stringify(input.history ?? []),
        ], 0),
      },
    };
    const chosen = route(routerCatalog, context);
    if (!chosen.ok) throw denial(chosen.reason);
    decision = chosen;
  }
  // Read-only selection uses exactly the same input, billing state, catalog and
  // provider health as execution. Return before any reservation/provider call.
  if (input.routeOnly) {
    if (!decision) throw new Failure("rejected");
    return json({
      routePreview: true,
      servedBy: { model: decision.alias, effort: decision.effort },
    });
  }
  const tried: string[] = decision ? [pairKey(decision.alias, decision.effort)] : [];
  let escalations = 0;

  // The answer model is the router's pick, or the user's for an older app.
  // Notation/animation is controlled by the server environment, with Luna as
  // the default.
  let modelAlias = decision?.alias ?? requestModel(input, Deno.env.get("AI_NOTATION_MODEL"));
  let effort: Effort | undefined = decision?.effort;
  let model = modelConfig(catalog, modelAlias);
  let key = secret(providerKeys[model.provider]);
  const two = twoStep(model, input);
  let drawerAlias = two ? configuredDrawingModel(Deno.env.get("AI_NOTATION_MODEL")) : undefined;
  let drawerEffort: Effort | undefined;
  if (two && context) {
    // The configured drawing model, unless the user turned it off or it cannot
    // be paid for (a paid plan out of credits keeps drawing on an unlimited one).
    const base: RouteContext = { ...context, task: "editor.notation", setting: "medium" };
    const configured = context.allowed && !context.allowed.includes(drawerAlias!)
      ? undefined
      : route(routerCatalog, { ...base, allowed: [drawerAlias!] });
    const chosen = configured?.ok ? configured : route(routerCatalog, base);
    if (!chosen.ok) throw denial(chosen.reason);
    drawerAlias = chosen.alias;
    drawerEffort = chosen.effort;
  }
  const drawer = drawerAlias ? modelConfig(catalog, drawerAlias) : undefined;
  const drawerKey = drawer ? secret(providerKeys[drawer.provider]) : "";
  // The database decides what is unlimited from the model and effort it is
  // given. Older apps name a model and no effort: medium, as before.
  const billedEffort: Effort = !effort
    ? "medium"
    : drawerEffort && effortRank(drawerEffort) > effortRank(effort)
    ? drawerEffort
    : effort;
  // If remaining token balance > 0 (or the request is unlimited), always accept
  // the request without holding/deducting balance upfront.
  await rpc(db, "ai_reserve", {
    p_user: user,
    p_request: input.requestId,
    p_model: billingModel(modelAlias, drawerAlias),
    p_effort: billedEffort,
  });
  const passes: PassUsage[] = [];
  const settle = async (cost: number, tokensIn = 0, tokensOut = 0, release = false) => {
    await rpc(db, "ai_settle_usage", {
      p_user: user,
      p_request: input.requestId,
      p_cost: cost,
      p_input: tokensIn,
      p_output: tokensOut,
      p_release: release,
      p_task: context?.task ?? (input.task === "testGrading" ? "test.grading" : "editor.answer"),
      p_turn: input.turnId ?? input.requestId,
      p_effort: effort ?? "medium",
      p_passes: passes,
    });
    // Only what the router decided and what it cost, never what was asked.
    if (!release && decision && context) {
      console.log(JSON.stringify({
        event: "ai_route",
        task: context.task,
        setting: context.setting,
        plan: context.plan,
        model: modelAlias,
        effort,
        drawer: drawerAlias,
        drawerEffort,
        billing: decision.billing,
        capable: decision.capable,
        escalations,
        inputTokens: tokensIn,
        outputTokens: tokensOut,
        cost,
      }));
    }
  };
  /** What the app is told about who answered, for "show the model used". */
  const servedBy = () => routed ? { model: modelAlias, effort } : undefined;
  /** Moves a routed request to the next pair after [cause], if that pair is
   * billed the way the reservation was: otherwise the user would be charged
   * for a pair the reservation called free, or the reverse. */
  const retry = (failed: Decision, cause: "refused" | "unusable"): boolean => {
    if (!context || !decision || escalations >= 2) return false;
    const next = cause === "refused"
      ? route(routerCatalog, {
        ...context,
        unhealthyProviders: providersDown(),
        exclude: tried,
      })
      : escalate(routerCatalog, { ...context, exclude: tried }, failed);
    if (!next.ok || next.billing !== decision.billing) return false;
    const nextModel = modelConfig(catalog, next.alias);
    let nextKey: string;
    try {
      nextKey = secret(providerKeys[nextModel.provider]);
    } catch {
      return false;
    }
    tried.push(pairKey(next.alias, next.effort));
    decision = next;
    modelAlias = next.alias;
    effort = next.effort;
    model = nextModel;
    key = nextKey;
    escalations++;
    return true;
  };
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
      console.warn(JSON.stringify({
        event: "ai_provider_refused",
        provider: answerer.provider,
        model: answerer.model,
        status: response.status,
      }));
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
    const started = Date.now();
    let spent: MeteredUsage | undefined;
    let first: Awaited<ReturnType<typeof ask>>;
    for (;;) {
      // If the user's remaining balance is above 0 (or the request is
      // unlimited), the request is accepted with the model's full output budget.
      const maxOutput = studyOutputCeiling(context?.task, outputBudget(model, two), effort);
      first = await ask(
        providerRequest(model, input, maxOutput, key, two ? { step: "text" } : undefined, effort),
        model,
      );
      if (!first.result) {
        // A provider that is down is skipped by the next requests, and this one
        // moves to the next pair if it can.
        if (first.refused === 429 || (first.refused ?? 0) >= 500) {
          outages.set(model.provider, Date.now() + outageMs);
          if (decision && retry(decision, "refused")) continue;
        }
        break;
      }
      spent = meterPass(spent, model, first.result);
      passes.push(describePass(modelAlias, model, effort ?? "medium", "answer", first.result));
      // A failure the server can see itself: an empty answer, or words that
      // cannot be read from the first step of a notation request.
      const text = first.result.answer;
      let usable = typeof text === "string" && text.trim() !== "";
      if (usable && two) {
        try {
          stepMessage(text);
        } catch {
          usable = false;
        }
      }
      if (usable) usable = usableStudyResponse(input, context?.task, text);
      if (first.result.finishReason === "length" || first.result.finishReason === "MAX_TOKENS") {
        usable = false;
      }
      if (!usable && decision && retry(decision, "unusable")) continue;
      if (!usable) {
        await settle(spent.cost, spent.inputTokens, spent.outputTokens);
        settled = true;
        throw new Failure("server", 503);
      }
      break;
    }
    if (!first.result) {
      // A definitive rejection has no answer to bill, unless an earlier attempt
      // of this request was already paid for.
      if (spent) await settle(spent.cost, spent.inputTokens, spent.outputTokens);
      else await settle(0, 0, 0, true);
      settled = true;
      throw new Failure(first.refused === 429 ? "rate_limited" : "server", 503);
    }
    let usage: MeteredUsage = spent!;
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
              outputBudget(drawer, false),
              drawerKey,
              {
                step: "notation",
                message,
                visual: input.animationAllowed === true ? undefined : "static",
              },
              drawerEffort,
            ),
            drawer,
            Math.max(5000, 105000 - (Date.now() - started)),
            onText,
          );
          if (second.result) {
            usage = meterPass(usage, drawer, second.result);
            passes.push(
              describePass(
                drawerAlias!,
                drawer,
                drawerEffort ?? "medium",
                "notation",
                second.result,
              ),
            );
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
          servedBy: servedBy(),
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
      servedBy: servedBy(),
      responseFormat: input.responseFormat,
    });
  } catch (error) {
    if (!sent && !settled) await settle(0, 0, 0, true);
    // A timeout, missing usage, or settlement failure leaves the reservation
    // pending. No automatic refund/retry: the provider may have charged already.
    // Only metadata survives for operator reconciliation, never the prompt.
    throw error;
  }
}));
