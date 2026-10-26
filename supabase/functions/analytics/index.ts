import {
  accountFor,
  admin,
  deviceIdOf,
  endpoint,
  Failure,
  json,
  readBody,
  rpc,
} from "../_shared/common.ts";

const eventNames = new Set([
  "app_open",
  "sign_in",
  "note_created",
  "note_opened",
  "note_imported",
  "note_exported",
  "paywall_viewed",
  "purchase_started",
  "backup_enabled",
]);
const platforms = new Set([
  "android",
  "ios",
  "macos",
  "windows",
  "linux",
  "web",
  "unknown",
]);
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const version = /^[0-9A-Za-z.+_-]{1,32}$/;
const detail = /^[a-z0-9][a-z0-9_.-]{0,39}$/;
const eventDetails: Record<string, Set<string>> = {
  note_imported: new Set(["pdf", "goodnotes"]),
  note_exported: new Set(["pdf", "svg"]),
  purchase_started: new Set([
    "starter699_monthly",
    "starter699_yearly",
    "pro1499_monthly",
    "pro1499_yearly",
    "max2499_monthly",
    "max2499_yearly",
  ]),
};

Deno.serve(endpoint(async (req) => {
  const db = admin();
  const account = await accountFor(req, db);
  const body = await readBody(req, 2048);
  if (
    typeof body.eventId !== "string" || !uuid.test(body.eventId) ||
    typeof body.sessionId !== "string" || !uuid.test(body.sessionId) ||
    typeof body.name !== "string" || !eventNames.has(body.name) ||
    typeof body.platform !== "string" || !platforms.has(body.platform) ||
    (body.appVersion != null &&
      (typeof body.appVersion !== "string" || !version.test(body.appVersion))) ||
    (body.detail != null &&
      (typeof body.detail !== "string" || !detail.test(body.detail)))
  ) {
    throw new Failure("rejected");
  }
  const allowedDetails = eventDetails[body.name];
  if (
    (allowedDetails && !allowedDetails.has(body.detail)) ||
    (!allowedDetails && body.detail != null)
  ) {
    throw new Failure("rejected");
  }
  // Keep account/device identity in sync even when no billing screen is opened.
  // This is the same idempotent touch used by the billing endpoint.
  await rpc(db, "billing_touch", {
    p_user: account.id,
    p_anonymous: account.anonymous,
    p_device: deviceIdOf(body.deviceId),
  });
  const accepted = await rpc(db, "analytics_ingest", {
    p_user: account.id,
    p_anonymous: account.anonymous,
    p_device: deviceIdOf(body.deviceId),
    p_event: body.eventId,
    p_session: body.sessionId,
    p_name: body.name,
    p_platform: body.platform,
    p_version: body.appVersion ?? null,
    p_detail: body.detail ?? null,
  });
  return json({ accepted });
}));
