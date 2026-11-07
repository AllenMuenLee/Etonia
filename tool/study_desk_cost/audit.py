"""Offline LLMLingua experiment; optional paid replay of synthetic answer requests.

Run capture_test.dart first. Never reads or transmits real notes. The billing
snapshot, if present, is an aggregate export made separately with read-only SQL.
"""
import argparse
import concurrent.futures
import json
from pathlib import Path
import re
import time
import urllib.error
import urllib.request


ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build/study_desk_cost_audit"
MODEL = "microsoft/llmlingua-2-bert-base-multilingual-cased-meetingbank"
SUFFIX = ("\nUse the supplied conversation, current question, and attached source content as evidence. "
          "Ground references to the user's work in that supplied content.")
BLANK = ("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAACklEQVR4nGP4DwABAQEAsTj2"
         "FAAAAABJRU5ErkJggg==")


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def local_environment():
    result = {}
    for line in (ROOT / "supabase/.env.local").read_text(encoding="utf-8-sig").splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            key, value = line.split("=", 1)
            result[key.strip()] = value.strip().strip("'\"")
    return result


def source_parts(prompt):
    # Keep framing, source identifiers, and the question byte-for-byte intact.
    match = re.search(r"\[Source [^\n]+\]\n", prompt)
    question = prompt.rfind("\n\nQuestion: ")
    if not match or question <= match.end():
        return prompt, "", ""
    return prompt[:match.end()], prompt[match.end():question], prompt[question:]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--live-answer-model", help="Spend API credit replaying synthetic answers (OpenAI aliases only).")
    parser.add_argument("--effort", default="low", choices=["low", "medium", "high"])
    args = parser.parse_args()
    import tiktoken
    import torch
    from llmlingua import PromptCompressor

    # A proxy for text size, not an exact counter for the deployed models.
    encoding = tiktoken.get_encoding("o200k_base")
    count = lambda text: len(encoding.encode(text))
    start = time.perf_counter()
    device = "cuda" if torch.cuda.is_available() else "cpu"
    compressor = PromptCompressor(
        model_name=MODEL, device_map=device,
        model_config={"trust_remote_code": False}, use_llmlingua2=True,
    )
    load_seconds = time.perf_counter() - start
    captures = read_json(OUT / "captured_requests.json")
    measurements, cache = [], {}
    for request in captures:
        if request["task"] == "study.suggestions":
            continue  # This test compresses retrieved notes only.
        prefix, source, suffix = source_parts(request["prompt"])
        if not source:
            raise ValueError(f"No source text in {request['fixture']}")
        for rate in (0.5, 0.25):
            key = (source, rate)
            if key not in cache:
                start = time.perf_counter()
                result = compressor.compress_prompt(
                    source, rate=rate, force_reserve_digit=True,
                    force_tokens=["\n", ".", "not", "never", "only", "cannot", "must", ">", "<", "=", "+", "-", "^", "不", "不能"],
                )
                cache[key] = (result["compressed_prompt"], time.perf_counter() - start)
            compressed, seconds = cache[key]
            after = prefix + compressed + suffix
            original_total = count(request["systemInstruction"] + SUFFIX) + count(request["prompt"])
            compressed_total = count(request["systemInstruction"] + SUFFIX) + count(after)
            row = {
                "fixture": request["fixture"], "task": request["task"], "retention_target": rate,
                "source_tokens_before": count(source), "source_tokens_after": count(compressed),
                "text_input_tokens_before": original_total, "text_input_tokens_after": compressed_total,
                "source_reduction": 1 - count(compressed) / count(source),
                "whole_text_input_reduction": 1 - compressed_total / original_total,
                "compression_seconds": seconds, "compressed_prompt": after,
            }
            measurements.append(row)
            print(json.dumps({k: v for k, v in row.items() if k != "compressed_prompt"}), flush=True)

    report = {"model": MODEL, "device": device, "load_seconds": load_seconds,
              "tokenizer_proxy": "o200k_base; excludes image/chat framing tokens",
              "scope": "Synthetic fixtures, fresh conversations, source text only; no downstream quality certification",
              "measurements": measurements}
    (OUT / "compression_results.json").write_text(json.dumps(report, indent=2, ensure_ascii=False), encoding="utf-8")

    if not args.live_answer_model:
        return
    # Paid replay uses a fixed model/effort for a controlled comparison. It
    # bypasses routing and billing RPCs and is not a whole-session benchmark.
    env = local_environment()
    config = json.loads(env["AI_MODEL_CONFIG"])[args.live_answer_model]
    if config["provider"] != "openai":
        raise ValueError("Live replay currently supports OpenAI aliases only")
    jobs = []
    for request in captures:
        if request["task"] != "study.answer":
            continue
        compressed = next(r for r in measurements if r["fixture"] == request["fixture"]
                          and r["task"] == "study.answer" and r["retention_target"] == 0.5)
        for variant, prompt in (("baseline", request["prompt"]), ("compressed", compressed["compressed_prompt"])):
            jobs.append((request, variant, prompt))

    def replay(job):
        request, variant, prompt = job
        body = {
            "model": config["model"], "store": False, "max_completion_tokens": 4096,
            "reasoning_effort": args.effort,
            "messages": [{"role": "system", "content": request["systemInstruction"] + SUFFIX},
                         {"role": "user", "content": [
                             {"type": "image_url", "image_url": {"url": "data:image/png;base64," + BLANK, "detail": "high"}},
                             {"type": "text", "text": prompt}]}],
        }
        req = urllib.request.Request("https://api.openai.com/v1/chat/completions",
                                     data=json.dumps(body).encode(), method="POST",
                                     headers={"Authorization": "Bearer " + env["OPENAI_API_KEY"], "Content-Type": "application/json"})
        start = time.perf_counter()
        try:
            with urllib.request.urlopen(req, timeout=180) as response:
                result = json.load(response)
        except urllib.error.HTTPError as error:
            # Do not log provider responses or credentials.
            return {"fixture": request["fixture"], "variant": variant, "http_error": error.code}
        usage = result["usage"]
        cached = usage.get("prompt_tokens_details", {}).get("cached_tokens", 0)
        input_cost = ((usage["prompt_tokens"] - cached) * config["inputMicroPerKilo"]
                      + cached * config.get("cachedInputMicroPerKilo", config["inputMicroPerKilo"])) / 1e9
        output_cost = usage["completion_tokens"] * config["outputMicroPerKilo"] / 1e9
        return {"fixture": request["fixture"], "variant": variant, "model": config["model"],
                "effort": args.effort, "usage": usage, "input_cost_usd": input_cost,
                "output_cost_usd": output_cost, "total_cost_usd": input_cost + output_cost,
                "latency_seconds": time.perf_counter() - start,
                "finish_reason": result["choices"][0].get("finish_reason"),
                "answer": result["choices"][0]["message"]["content"]}

    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as executor:
        live = list(executor.map(replay, jobs))
    (OUT / "live_replay_results.json").write_text(json.dumps(live, indent=2, ensure_ascii=False), encoding="utf-8")
    for row in live:
        print(json.dumps({k: v for k, v in row.items() if k != "answer"}), flush=True)


if __name__ == "__main__":
    main()
