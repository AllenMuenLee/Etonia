# AI request rejection investigation

Follow-up resolution on November 7, 2026: production had advanced to AI function
version 55, but still lacked the visual-description billing migration. The
22:27:41 UTC HTTP 503 followed a Haiku reservation that remained pending;
`ai_settle_usage` did not accept `study.describe`. Applied migrations
`202611090001` and `202611100001`, enabled the balanced `flash` model through
`AI_MODEL_CONFIG_OVERRIDES`, and deployed the updated AI function.

Verified the deployed service using a temporary synthetic account: Flash route
preview, Flash text answer, and Haiku visual description all returned HTTP 200.
Both inference requests reached `settled` with the expected model/task metadata.
The temporary account was deleted after verification. Five direct Gemini tests
also passed: Flash text, medium/high JSON with images, streamed SVG, and Argon
JSON. The earlier Gemini quota error did not recur. The original findings below
describe the earlier deployment state.

Investigated November 7, 2026 using production Supabase logs, the downloaded
deployed function bundle, read-only database queries, local tests, and synthetic
provider requests. No user note content was read or used in provider checks.

## Latest failure

The latest recorded AI failures were HTTP 400 at 22:10:54.575,
22:10:54.906, and 22:10:55.166 UTC (17:10:54–55 Toronto time).
The preceding `study.plan` succeeded on Haiku at 22:10:53.366 UTC.
The same sequence occurred around 22:10:20 UTC.

Production runs AI function version 54, updated at 20:28:38.050 UTC.
Its deployed validators differ from the current app:

| Request | Current app | Deployed version 54 |
| --- | --- | --- |
| Route preview | Sends top-level `routeOnly: true` | Rejects this unknown field |
| Visual description | Sends routing task `study.describe` | Task is absent from the accepted task list |

Both failures were reproduced against JavaScript validators extracted from the
deployed bundle, using synthetic input. An ordinary existing answer request was
accepted as a control. The local validators accept the new requests.

The controller tolerates a rejected route preview and falls back to the visual
reader. That reader then sends `study.describe`, which version 54 rejects too.
For a structured request, the client's legacy response-format retry preserves
the routing task, so that retry also fails. This explains the cluster of three
HTTP 400s. The request sequence is inferred from the current client code and the
reproduction; production logs do not retain request bodies or validation reasons.

`BackendAiClient` maps backend `rejected` to the displayed message
“The AI service could not accept the request.” These validation failures happen
before a provider request or credit reservation.

## Provider APIs

The deployed bundle and current implementation both use the corresponding native
APIs, with provider-specific message, image, effort, and response handling:

| Provider | API | Authentication |
| --- | --- | --- |
| Anthropic | `https://api.anthropic.com/v1/messages` | `x-api-key`, `anthropic-version: 2023-06-01` |
| OpenAI | `https://api.openai.com/v1/chat/completions` | Bearer authorization |
| Gemini | `https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` | `x-goog-api-key` |

Drawing uses streaming Messages/Chat Completions, or Gemini
`:streamGenerateContent?alt=sse`. The Flutter direct clients also use these APIs;
the normal editor and Study Desk instantiate `BackendAiClient`.

Synthetic generation requests used the actual `modelConfig` and `providerRequest`
functions, low effort, a valid blank 64×64 PNG, and a 1,024-token ceiling.

| Local configured model | Generation result |
| --- | --- |
| `claude-haiku-5-5` | HTTP 200, nonempty answer |
| `claude-sonnet-5-5` | HTTP 200, nonempty answer |
| `claude-opus-5-5` | HTTP 200, nonempty answer |
| `gpt-6-luna` | HTTP 200, nonempty answer |
| `gpt-6.1-sol` | HTTP 200, nonempty answer |
| `gpt-6-astra` | HTTP 200, nonempty answer |
| `gemini-4-argon` | HTTP 429, `RESOURCE_EXHAUSTED`, free-tier quota limit 0 |

Model metadata requests succeeded for all seven models. The three tested API
keys match the production secrets. The local model catalog's digest differs
from production, so these checks establish acceptance of the listed local
model configurations, not identity of the entire deployed catalog. Gemini's
quota response prevents a successful generation/payload compatibility check.

## Release requirements and verification

Production's latest recorded migration is `202611080001_ai_usage_breakdown`.
A read-only check of `public.ai_settle_usage` confirms it does not yet accept
`study.describe`. Release both the current AI function and
`supabase/migrations/202611090001_visual_description_usage.sql`; deploying the
function alone leaves visual-description settlement unsupported.

Separately, resolve the Gemini project's quota/billing before expecting Argon
generation to succeed. Its HTTP 429 is distinct from the latest local backend
validation rejection.

Verification: 44 backend policy/router tests passed. The five selected Flutter
test files produced 108 passes and one existing failure in
`openai_ai_client_test.dart:189`: an assertion expects old note-metadata wording
(`you are not shown the whole sheet`). All eight visual-pipeline tests passed.
Application code, production functions, migrations, and secrets were unchanged
during this investigation.

API references: [OpenAI Docs: Chat Completions](https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create),
[Anthropic Messages](https://platform.claude.com/docs/en/api/messages),
[Gemini Generate Content](https://ai.google.dev/api/generate-content).
