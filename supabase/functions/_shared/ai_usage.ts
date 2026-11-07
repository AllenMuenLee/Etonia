import { costOf, type ModelConfig, type ProviderEffort } from "./ai_policy.ts";
import { Failure } from "./common.ts";

/** Only controlled dimensions and numbers cross the persistence boundary. */
export interface PassUsage {
  model: string;
  providerModel: string;
  provider: ModelConfig["provider"];
  effort: ProviderEffort;
  kind: "answer" | "notation";
  inputTokens: number;
  outputTokens: number;
  cachedTokens: number;
  cacheWriteTokens: number;
  reasoningTokens: number | null;
  imageTokens: number | null;
  inputCostMicro: number;
  outputCostMicro: number;
  roundingCostMicro: number;
  costMicro: number;
  inputRate: number;
  cachedRate: number;
  writeRate: number;
  outputRate: number;
}

export function describePass(
  alias: string,
  model: ModelConfig,
  effort: ProviderEffort,
  kind: PassUsage["kind"],
  usage: {
    input: number;
    output: number;
    cached: number;
    cacheWrites: number;
    reasoning?: number | null;
    imageTokens?: number | null;
  },
): PassUsage {
  // costOf validates the billing counts before any metadata is constructed.
  const costMicro = costOf(model, usage.input, usage.output, usage.cached, usage.cacheWrites);
  const optionalCount = (value: number | null | undefined, maximum: number) => {
    if (value == null) return null;
    if (!Number.isSafeInteger(value) || value < 0 || value > maximum) {
      throw new Failure("server", 503);
    }
    return value;
  };
  const cachedRate = model.cachedInputMicroPerKilo ?? model.inputMicroPerKilo;
  const writeRate = model.cacheWriteMicroPerKilo ??
    model.inputMicroPerKilo * (model.provider === "claude" ? 1.25 : 1);
  const inputCostMicro =
    ((usage.input - usage.cached - usage.cacheWrites) * model.inputMicroPerKilo +
      usage.cached * cachedRate + usage.cacheWrites * writeRate) / 1000;
  const outputCostMicro = usage.output * model.outputMicroPerKilo / 1000;
  return {
    model: alias,
    providerModel: model.model,
    provider: model.provider,
    effort,
    kind,
    inputTokens: usage.input,
    outputTokens: usage.output,
    cachedTokens: usage.cached,
    cacheWriteTokens: usage.cacheWrites,
    reasoningTokens: optionalCount(usage.reasoning, usage.output),
    imageTokens: optionalCount(usage.imageTokens, usage.input),
    inputCostMicro,
    outputCostMicro,
    roundingCostMicro: Math.max(0, costMicro - inputCostMicro - outputCostMicro),
    costMicro,
    inputRate: model.inputMicroPerKilo,
    cachedRate,
    writeRate,
    outputRate: model.outputMicroPerKilo,
  };
}
