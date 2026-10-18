import { createClient } from "@supabase/supabase-js";

export class Failure extends Error {
  constructor(public code: string, public status = 400) {
    super(code);
  }
}
export function secret(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Failure("not_configured", 503);
  return value;
}
export function admin() {
  return createClient(secret("SUPABASE_URL"), secret("SUPABASE_SERVICE_ROLE_KEY"), {
    auth: { persistSession: false, autoRefreshToken: false },
  });
}
export type Admin = ReturnType<typeof admin>;
export async function userFor(req: Request, db: Admin): Promise<string> {
  const account = await accountFor(req, db);
  if (account.anonymous) throw new Failure("unauthorized", 401);
  return account.id;
}
// Anonymous (device-only, not yet Google) sessions included. Callers decide
// what an anonymous account may do; it never owns purchases or AI access.
export async function accountFor(
  req: Request,
  db: Admin,
): Promise<{ id: string; anonymous: boolean }> {
  const token = req.headers.get("authorization")?.match(/^Bearer (.+)$/i)?.[1];
  if (!token) throw new Failure("unauthorized", 401);
  const { data, error } = await db.auth.getUser(token);
  if (error || !data.user) throw new Failure("unauthorized", 401);
  return { id: data.user.id, anonymous: data.user.is_anonymous === true };
}
const uuidPattern = /^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
// The app's random per-install device ID, or null when absent or malformed.
export function deviceIdOf(value: unknown): string | null {
  return typeof value === "string" && uuidPattern.test(value) ? value : null;
}
export async function rpc(db: Admin, name: string, args: Record<string, unknown>): Promise<any> {
  const { data, error } = await db.rpc(name, args);
  if (error) {
    const codes = [
      "plan_required",
      "insufficient_credits",
      "rate_limited",
      "request_in_progress",
      "purchase_owner",
    ];
    const code = codes.find((c) => error.message === c);
    throw new Failure(code ?? "server", code === "rate_limited" ? 429 : code ? 409 : 503);
  }
  return data;
}
export function json(data: unknown, status = 200): Response {
  return Response.json(data, { status, headers: { "Cache-Control": "no-store" } });
}
export function endpoint(handler: (req: Request) => Promise<Response>) {
  return async (req: Request): Promise<Response> => {
    if (req.method !== "POST") return json({ error: "rejected" }, 405);
    try {
      return await handler(req);
    } catch (error) {
      // Never log request bodies, receipts, tokens, provider answers or errors.
      return error instanceof Failure
        ? json({ error: error.code }, error.status)
        : json({ error: "server" }, 503);
    }
  };
}
export async function readBody(req: Request, maxBytes = 65536): Promise<Record<string, any>> {
  if (!req.body) throw new Failure("rejected");
  const reader = req.body.getReader();
  const parts: Uint8Array[] = [];
  let size = 0;
  while (true) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.length;
    if (size > maxBytes) {
      await reader.cancel();
      throw new Failure("rejected", 413);
    }
    parts.push(value);
  }
  const bytes = new Uint8Array(size);
  let offset = 0;
  for (const part of parts) {
    bytes.set(part, offset);
    offset += part.length;
  }
  try {
    const body = JSON.parse(new TextDecoder().decode(bytes));
    if (!body || typeof body !== "object" || Array.isArray(body)) throw 0;
    return body;
  } catch {
    throw new Failure("rejected");
  }
}
export async function fetchJson(url: string, init: RequestInit = {}): Promise<any> {
  const response = await fetch(url, {
    ...init,
    signal: AbortSignal.timeout(20000),
    redirect: "error",
  });
  if (!response.ok) throw new Failure("verification_failed", 503);
  return await response.json();
}

function bytes64(text: string): Uint8Array<ArrayBuffer> {
  return Uint8Array.from(atob(text), (c) => c.charCodeAt(0));
}
async function encryptionKey(): Promise<CryptoKey> {
  const bytes = bytes64(secret("PURCHASE_TOKEN_ENCRYPTION_KEY"));
  if (bytes.length !== 32) throw new Failure("not_configured", 503);
  return await crypto.subtle.importKey("raw", bytes, "AES-GCM", false, ["encrypt", "decrypt"]);
}
export async function encryptLocator(text: string): Promise<string> {
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const encrypted = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    await encryptionKey(),
    new TextEncoder().encode(text),
  );
  const bytes = new Uint8Array(12 + encrypted.byteLength);
  bytes.set(iv);
  bytes.set(new Uint8Array(encrypted), 12);
  return btoa(String.fromCharCode(...bytes));
}
export async function decryptLocator(text: string): Promise<string> {
  const bytes = bytes64(text);
  return new TextDecoder().decode(
    await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes.slice(0, 12) },
      await encryptionKey(),
      bytes.slice(12),
    ),
  );
}
export async function digest(text: string): Promise<string> {
  return Array.from(
    new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(text))),
  )
    .map((b) => b.toString(16).padStart(2, "0")).join("");
}
