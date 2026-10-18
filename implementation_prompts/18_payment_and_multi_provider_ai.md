# Implementation Prompt 18: Subscription Plans, Payment Page, Multi-Provider AI (Gemini, OpenAI, Claude), and Android/Apple In-App Purchases

You are extending **Greatnote**, a Flutter tablet note application for Android and iPadOS. The app already includes a multi-page vector ink editor, a selection-aware multimodal AI assistant (`AiAssistantPanel`, `AiAssistantController`, `AiClient`, `GeminiAiClient`), animated vector AI notations (`AiNotation`), and a persisted library (`LibraryScreen`). Preserve all existing editor, ink, notation, library, and cloud backup behaviors.

## Product outcome

Implement a complete subscription, AI credit metering, multi-provider model routing, and native In-App Purchase (IAP) system:

1. **Three Subscription Plans (`$4.99`, `$12.99`, and `$29.99`):**
   - **All 3 plans** include **Unlimited** access to **Haiku** and **Luna**.
   - **`$4.99` Plan (Starter):**
     - Unlimited **Haiku** and **Luna**.
     - **`$1.20` of AI credits** for **Sonnet** and **Sol** combined (`Opus`, `Argon`, and `Astra` are locked on this plan).
   - **`$12.99` Plan (Pro):**
     - Unlimited **Haiku** and **Luna**.
     - **`$5.00` of AI credits** for **Sonnet**, **Sol**, **Opus**, **Argon**, and **Astra** combined.
   - **`$29.99` Plan (Max):**
     - Unlimited **Haiku** and **Luna**.
     - **`$15.00` of AI credits** for all models mentioned above (**Sonnet**, **Sol**, **Opus**, **Argon**, and **Astra** combined).
2. **Payment Page (`PaymentPage` / `SubscriptionSheet`):**
   - Add a dedicated, responsive Payment Page accessible from both the Library top bar and the Editor's AI Assistant panel (model picker / credit badge / upgrade prompt).
   - Display the three plans with high contrast in both light and dark modes, current active plan status, remaining AI credit balance (`$X.XX` of `$1.20` / `$5.00` / `$15.00`), eligible models per tier, native Android/iOS purchase actions, and **Restore Purchases**.
3. **Multi-Provider AI Setup (Gemini, OpenAI, and Claude):**
   - Extend the AI layer beyond `GeminiAiClient` by implementing `OpenAiClient` and `ClaudeAiClient` (plus a unified `MultiProviderAiClient` router) supporting all 7 models (`Haiku`, `Luna`, `Sonnet`, `Sol`, `Opus`, `Argon`, `Astra`) with multimodal PNG inputs (selected ink + whole-note image for notation) and streaming version-2 JSON responses.
4. **Android (Google Play Billing) and Apple (StoreKit) In-App Purchases & `dart_defines.json`:**
   - Wire Android and Apple in-app purchases behind an injectable `InAppPurchaseGateway` abstraction and read all required API keys, model IDs, and store product IDs from `dart_defines.json` via `--dart-define-from-file=dart_defines.json`.

---

## Start with the current architecture

Before editing, inspect:
- `lib/features/editor/ai/ai_client.dart`
- `lib/features/editor/ai/ai_config.dart`
- `lib/features/editor/ai/gemini_ai_client.dart`
- `lib/features/editor/ai/ai_assistant_controller.dart`
- `lib/features/editor/widgets/ai_assistant_panel.dart`
- `lib/features/editor/editor_screen.dart`
- `lib/features/library/library_screen.dart`
- `tool/run.ps1` and `tool/run.sh`
- `test/helpers/ai_fakes.dart`

---

## 1. Plans, Models, and AI Credit Metering

Create `lib/features/payment/payment_models.dart` and `lib/features/payment/subscription_controller.dart`:

### Model catalog (`AiModelTier`)
Define the 7 user-facing models and map each to its provider (`AiProvider.gemini`, `AiProvider.openai`, `AiProvider.claude`), default underlying provider model ID (overridable via `dart_defines.json`), credit cost policy, and minimum required plan:

| Model | Provider | Tier Type | Access Policy | Default Provider Model ID (overridable) |
| :--- | :--- | :--- | :--- | :--- |
| **Luna** | Gemini | Unlimited tier | Unlimited on `$4.99`, `$12.99`, `$29.99` | `gemini-2.5-flash-lite` |
| **Haiku** | Claude | Unlimited tier | Unlimited on `$4.99`, `$12.99`, `$29.99` | `claude-haiku-4-5` |
| **Sol** | Gemini | Standard credit tier | Shares `$1.20` (`$4.99`), `$5.00` (`$12.99`), or `$15.00` (`$29.99`) pool | `gemini-2.5-flash` |
| **Sonnet** | Claude | Standard credit tier | Shares `$1.20` (`$4.99`), `$5.00` (`$12.99`), or `$15.00` (`$29.99`) pool | `claude-sonnet-4-5` |
| **Argon** | Gemini | Frontier credit tier | Locked on `$4.99`; shares `$5.00` (`$12.99`) or `$15.00` (`$29.99`) pool | `gemini-2.5-pro` |
| **Opus** | Claude | Frontier credit tier | Locked on `$4.99`; shares `$5.00` (`$12.99`) or `$15.00` (`$29.99`) pool | `claude-opus-4-5` |
| **Astra** | OpenAI | Frontier credit tier | Locked on `$4.99`; shares `$5.00` (`$12.99`) or `$15.00` (`$29.99`) pool | `gpt-4.1` / `o3` |

### Subscription plans (`SubscriptionPlan`)
Define the 3 plans with exact entitlements:

1. **`SubscriptionPlan.starter499` (`$4.99`)**:
   - Price label: `$4.99 / month`
   - Unlimited models: `{AiModelId.haiku, AiModelId.luna}`
   - Credit-metered models: `{AiModelId.sonnet, AiModelId.sol}`
   - Locked models: `{AiModelId.opus, AiModelId.argon, AiModelId.astra}`
   - Included AI credits: **`$1.20`** (`1,200,000` micro-dollars) combined for `Sonnet` and `Sol`.
2. **`SubscriptionPlan.pro1299` (`$12.99`)**:
   - Price label: `$12.99 / month`
   - Unlimited models: `{AiModelId.haiku, AiModelId.luna}`
   - Credit-metered models: `{AiModelId.sonnet, AiModelId.sol, AiModelId.opus, AiModelId.argon, AiModelId.astra}`
   - Locked models: `{}`
   - Included AI credits: **`$5.00`** (`5,000,000` micro-dollars) combined for `Sonnet`, `Sol`, `Opus`, `Argon`, and `Astra`.
3. **`SubscriptionPlan.max2999` (`$29.99`)**:
   - Price label: `$29.99 / month`
   - Unlimited models: `{AiModelId.haiku, AiModelId.luna}`
   - Credit-metered models: `{AiModelId.sonnet, AiModelId.sol, AiModelId.opus, AiModelId.argon, AiModelId.astra}`
   - Locked models: `{}`
   - Included AI credits: **`$15.00`** (`15,000,000` micro-dollars) combined for `Sonnet`, `Sol`, `Opus`, `Argon`, and `Astra`.

### Credit accounting & enforcement
- Store credit balances in integer micro-dollars (`1 USD = 1,000,000 micro-dollars`) to prevent floating-point rounding drift, and persist subscription state and remaining credit balance locally alongside the library so it survives app restarts.
- When a plan is purchased or renewed:
  - Set `activePlan` to the purchased plan and grant its full credit allocation (`$1.20`, `$5.00`, or `$15.00`).
- Before sending an `AiRequest`:
  - Verify that the user has an active plan that unlocks the selected model.
  - If the selected model is `Haiku` or `Luna` and any plan (`$4.99`, `$12.99`, `$29.99`) is active, allow the request immediately with `$0.00` credit deduction, even if the user's metered credit balance is `$0.00`.
  - If the selected model is metered (`Sonnet`, `Sol`, `Opus`, `Argon`, `Astra`):
    - Check that the active plan includes that model (e.g. `Opus`, `Argon`, and `Astra` require `$12.99` or `$29.99`) and that `remainingCreditsMicroUsd > 0`.
    - If locked or out of credits, return a typed `AiFailure` (`AiFailureKind.planRequired` or `AiFailureKind.insufficientCredits`) with a clear user-facing message and an action button in `AiAssistantPanel` to open the Payment Page or switch to unlimited `Haiku` / `Luna`.
- After a successful metered `AiResult`:
  - Compute the request's cost in micro-dollars from the provider's reported `inputTokens` and `outputTokens` (falling back to deterministic character/image token estimation if usage metadata is omitted) using a configurable per-model token rate table in `PaymentConfig`, and deduct from `remainingCreditsMicroUsd` (clamped at `0`).

---

## 2. Payment Page & Model Selector UI

Create `lib/features/payment/payment_page.dart`:

- **Entry points:**
  - **Library Screen:** Add a **Plans & Credits** button/pill in the library header bar showing the current plan or remaining AI credits (minimum `48 x 48` touch target, tooltip, and semantic label).
  - **AI Assistant Panel:**
    - Add an accessible **Model Selector** dropdown/chip in `AiAssistantPanel` header allowing the user to pick between `Haiku`, `Luna`, `Sonnet`, `Sol`, `Opus`, `Argon`, and `Astra`. Show `Unlimited` next to `Haiku` and `Luna`, and show a lock badge next to `Opus`, `Argon`, and `Astra` when on the `$4.99` plan.
    - Display a compact **Credits** pill in the panel header (e.g., `$1.20 left`, `$5.00 left`, or `Upgrade`) that opens `PaymentPage`.
- **Payment Page layout & high contrast:**
  - Ensure high contrast between text color and background color across all cards, badges, prices, and feature lists in both light and dark themes (`AppColors`).
  - On expanded/medium tablet layouts (`800 x 1280`, `1194 x 834`), lay out the three plan cards (`$4.99`, `$12.99`, `$29.99`) in a responsive multi-column grid; on compact widths (`390 x 844`), stack them cleanly in a scrollable list without overflow.
  - Each plan card must clearly display:
    - Plan title and monthly price (`$4.99`, `$12.99`, `$29.99`) — using the live localized store price when available from the store and falling back to the configured price label.
    - **Unlimited Haiku & Luna** badge.
    - Exact AI credit allowance and eligible models:
      - `$4.99`: `$1.20 AI credits for Sonnet & Sol combined`
      - `$12.99`: `$5.00 AI credits for Sonnet, Sol, Opus, Argon & Astra combined`
      - `$29.99`: `$15.00 AI credits for all models (Sonnet, Sol, Opus, Argon & Astra combined)`
    - Primary action button (`Subscribe`, `Current Plan`, `Upgrade`, or `Switch Plan`) with a minimum `48 x 48` interactive target.
  - Include a **Current Subscription & Credit Meter** banner at the top showing the active plan, remaining credits (`$X.XX / $Y.YY`), a determinate progress bar, and a **Restore Purchases** button.
  - Show non-destructive loading states during store queries/purchases and clear inline error banners if a purchase is cancelled or fails.

---

## 3. Multi-Provider AI: Gemini, OpenAI, and Claude

Extend `lib/features/editor/ai/` so that Gemini, OpenAI, and Claude all implement `AiClient` (or a provider-specific client wrapped by a routing `MultiProviderAiClient`):

### Common contract across all 3 providers
- Every provider client (`GeminiAiClient`, `OpenAiClient`, `ClaudeAiClient`) must:
  - Accept an `AiRequest` (containing `systemInstruction`, `imagePng` for selected ink, optional `noteImage` + metadata when `notationEnabled` is true, and chronological `messages`).
  - Stream partial assistant text via `AiPartialCallback` (`AiAssistantResponse.partialMessageState`) as tokens arrive.
  - Enforce the same version-2 JSON response contract (`{"version":2,"message":"...","notation":...}`) so both chat markdown/LaTeX and handwritten canvas `AiNotation` work identically regardless of whether the user selects `Luna`, `Sol`, `Argon` (Gemini), `Haiku`, `Sonnet`, `Opus` (Claude), or `Astra` (OpenAI).
  - Report token usage (`AiTokenUsage(inputTokens, outputTokens)`) on `AiSuccess` so `SubscriptionController` can deduct accurate credits.
  - Map HTTP errors (`401`/`403` -> `unauthorized`, `429` -> `rateLimited`, `>=500` -> `server`, timeouts -> `timeout`, network -> `network`, content filter -> `blocked`, invalid JSON -> `malformed`) without ever logging or exposing API keys, base64 images, or raw response bodies.

### OpenAI client (`lib/features/editor/ai/openai_ai_client.dart`)
- Endpoint: `POST https://api.openai.com/v1/chat/completions` (configurable base URL).
- Headers:
  - `Content-Type: application/json`
  - `Authorization: Bearer <openaiApiKey>`
- Request payload:
  - `model`: resolved OpenAI model ID for `Astra` (e.g. `gpt-4.1`).
  - `stream`: `true`, `stream_options`: `{"include_usage": true}`.
  - `response_format`: `{"type": "json_object"}` (or `json_schema` using `aiResponseJsonSchema(notationConfig)`).
  - `messages`:
    - `system` message with `request.systemInstruction`.
    - `user` and `assistant` turns in chronological order, attaching the selected ink PNG as `{"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}` on the first user message, and attaching the whole-note PNG + note metadata on the final user message when `request.noteImage != null`.
- Stream reader:
  - Parse `data: {...}` SSE lines until `data: [DONE]`, accumulating `choices[0].delta.content`, invoking `onPartial`, extracting `usage.prompt_tokens` / `usage.completion_tokens`, and parsing the final JSON via `AiAssistantResponse.parse`.

### Claude client (`lib/features/editor/ai/claude_ai_client.dart`)
- Endpoint: `POST https://api.anthropic.com/v1/messages` (configurable base URL).
- Headers:
  - `Content-Type: application/json`
  - `x-api-key: <claudeApiKey>`
  - `anthropic-version: 2023-06-01`
- Request payload:
  - `model`: resolved Claude model ID for `Haiku`, `Sonnet`, or `Opus`.
  - `max_tokens`: `notationConfig.maxOutputTokens` (clamped to the model's supported output limit).
  - `stream`: `true`.
  - `system`: `request.systemInstruction`.
  - `messages`:
    - `user` and `assistant` turns in chronological order, with the selected ink PNG encoded as `{"type": "image", "source": {"type": "base64", "media_type": "image/png", "data": "..."}}` in the first user turn and the whole-note PNG + metadata in the final user turn when `request.noteImage != null`.
- Stream reader:
  - Parse SSE `content_block_delta` (`delta.type == 'text_delta'`), `message_start` (`message.usage.input_tokens`), `message_delta` (`usage.output_tokens`, `stop_reason`), and `error` events, invoking `onPartial` and parsing the completed JSON via `AiAssistantResponse.parse`.

---

## 4. Android & Apple In-App Purchase Setup and `dart_defines.json`

### `dart_defines.json` configuration contract
Centralize all compile-time/runtime secrets and store identifiers in `dart_defines.json` (which is gitignored and passed automatically by `tool/run.ps1` and `tool/run.sh`). Support reading the following keys via `String.fromEnvironment`:

```json
{
  "GEMINI_API_KEY": "<gemini-api-key>",
  "Claude_API_KEY": "<claude-api-key>",
  "Openai_API_KEY": "<openai-api-key>",
  "GEMINI_MODEL": "gemini-2.5-flash",
  "GEMINI_THINKING_LEVEL": "MINIMAL",
  "LUNA_MODEL_ID": "gemini-2.5-flash-lite",
  "SOL_MODEL_ID": "gemini-2.5-flash",
  "ARGON_MODEL_ID": "gemini-2.5-pro",
  "HAIKU_MODEL_ID": "claude-haiku-4-5",
  "SONNET_MODEL_ID": "claude-sonnet-4-5",
  "OPUS_MODEL_ID": "claude-opus-4-5",
  "ASTRA_MODEL_ID": "gpt-4.1",
  "IAP_ANDROID_PLAN_499_ID": "greatnote_plan_499_monthly",
  "IAP_ANDROID_PLAN_1299_ID": "greatnote_plan_1299_monthly",
  "IAP_ANDROID_PLAN_2999_ID": "greatnote_plan_2999_monthly",
  "IAP_IOS_PLAN_499_ID": "com.greatnote.app.plan.499.monthly",
  "IAP_IOS_PLAN_1299_ID": "com.greatnote.app.plan.1299.monthly",
  "IAP_IOS_PLAN_2999_ID": "com.greatnote.app.plan.2999.monthly",
  "IAP_ANDROID_PACKAGE_NAME": "com.greatnote.app",
  "IAP_IOS_BUNDLE_ID": "com.greatnote.app"
}
```

- **Compatibility requirement for key names:** In `AiApiConfig.fromEnvironment()`, read `Claude_API_KEY` (falling back to `CLAUDE_API_KEY` / `ANTHROPIC_API_KEY` if empty) and `Openai_API_KEY` (falling back to `OPENAI_API_KEY` if empty) so existing local `dart_defines.json` files work out of the box without renaming keys.
- Never log or commit real keys from `dart_defines.json`.

### Native Android and Apple In-App Purchase integration
1. **Dependency & Platform Configuration:**
   - Add `in_app_purchase` to `pubspec.yaml`.
   - **Android (`android/app/src/main/AndroidManifest.xml`):** Ensure `<uses-permission android:name="com.android.vending.BILLING" />` is declared.
   - **iOS / iPadOS:** Ensure the Runner target is ready for StoreKit (`In-App Purchase` capability).
2. **Injectable `InAppPurchaseGateway` (`lib/features/payment/in_app_purchase_gateway.dart`):**
   - Put all store interactions behind an abstract `InAppPurchaseGateway` interface:
     - `Future<bool> isAvailable()`
     - `Future<List<StoreProduct>> queryProducts(Set<String> productIds)`
     - `Stream<List<StorePurchaseUpdate>> get purchaseUpdates`
     - `Future<void> buySubscription(StoreProduct product)`
     - `Future<void> restorePurchases()`
     - `Future<void> completePurchase(StorePurchaseUpdate purchase)`
   - Provide `PlatformInAppPurchaseGateway` backed by `InAppPurchase.instance` (resolving Android vs. iOS product IDs from `PaymentConfig.fromEnvironment()`).
   - Handle the full purchase stream lifecycle (`pending`, `purchased`, `restored`, `error`, `canceled`), calling `completePurchase` when `pendingCompletePurchase` is true and granting/restoring the matching `SubscriptionPlan` (`$4.99`, `$12.99`, or `$29.99`) and its AI credits.

---

## Automated Tests

Tests must never make real network calls, require real API keys, or touch native store channels. Add fakes in `test/helpers/ai_fakes.dart` and `test/helpers/payment_fakes.dart`:

1. **Plan entitlements & AI credit metering tests (`test/features/payment/subscription_controller_test.dart`):**
   - `$4.99` plan grants unlimited `Haiku` and `Luna` (`$0` deducted per turn), `$1.20` combined credits for `Sonnet` and `Sol`, and blocks `Opus`, `Argon`, and `Astra` with `AiFailureKind.planRequired`;
   - `$12.99` plan grants unlimited `Haiku` and `Luna` plus `$5.00` combined credits across `Sonnet`, `Sol`, `Opus`, `Argon`, and `Astra`;
   - `$29.99` plan grants unlimited `Haiku` and `Luna` plus `$15.00` combined credits across `Sonnet`, `Sol`, `Opus`, `Argon`, and `Astra`;
   - when metered credits are exhausted (`$0.00`), `Sonnet`/`Sol`/`Opus`/`Argon`/`Astra` requests fail with `AiFailureKind.insufficientCredits`, while `Haiku` and `Luna` continue working without interruption;
   - upgrading or restoring a plan updates the active tier and credit balance and persists across controller reloads.
2. **OpenAI & Claude client tests (`test/features/editor/openai_ai_client_test.dart`, `test/features/editor/claude_ai_client_test.dart`):**
   - verify endpoint URLs, headers (`Authorization: Bearer ...` for OpenAI; `x-api-key` and `anthropic-version` for Claude), model IDs, base64 image serialization (both selected ink and whole-note image with metadata), SSE streaming partial callbacks, structured version-2 JSON notation parsing, token usage extraction, and error mapping (`401`, `429`, `500`, timeout, malformed JSON);
   - verify `MultiProviderAiClient` routes `Luna`/`Sol`/`Argon` to Gemini, `Haiku`/`Sonnet`/`Opus` to Claude, and `Astra` to OpenAI;
   - verify no error or `toString()` output leaks API keys or base64 image data.
3. **In-App Purchase & Payment Page widget tests (`test/features/payment/payment_page_test.dart`):**
   - renders all 3 plans (`$4.99`, `$12.99`, `$29.99`) with their exact credit descriptions (`$1.20`, `$5.00`, `$15.00`) and unlimited `Haiku` & `Luna` badges;
   - purchasing each plan via `FakeInAppPurchaseGateway` transitions through `pending` -> `purchased`, completes the transaction, activates the plan, and updates the credit meter;
   - `Restore Purchases` restores a previous subscription cleanly;
   - responsive layout fits without overflow at `390 x 844`, `800 x 1280`, and `1194 x 834` in both light and dark themes with high text/background contrast and `48 x 48` minimum touch targets.

Run formatting, static analysis, and tests:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
```
