import { importPKCS8, SignJWT } from "jose";
import { fetchJson, secret } from "./common.ts";

// Revokes Sign in with Apple tokens when an account is deleted, as Apple
// requires. Needs a Sign in with Apple key: APPLE_SIGN_IN_KEY_ID,
// APPLE_SIGN_IN_PRIVATE_KEY, APPLE_TEAM_ID, and APPLE_BUNDLE_ID as the
// client ID (native sign-in uses the bundle ID).

/** Whether this deployment has the key to revoke Apple tokens. */
export function canRevokeAppleSignIn(): boolean {
  return ["APPLE_SIGN_IN_KEY_ID", "APPLE_SIGN_IN_PRIVATE_KEY", "APPLE_TEAM_ID"]
    .every((name) => !!Deno.env.get(name));
}

/** The short-lived client secret Apple's REST API takes in place of a password. */
async function clientSecret(): Promise<string> {
  const key = await importPKCS8(secret("APPLE_SIGN_IN_PRIVATE_KEY"), "ES256");
  return await new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: secret("APPLE_SIGN_IN_KEY_ID") })
    .setIssuer(secret("APPLE_TEAM_ID"))
    .setIssuedAt()
    .setExpirationTime("5m")
    .setAudience("https://appleid.apple.com")
    .setSubject(secret("APPLE_BUNDLE_ID"))
    .sign(key);
}

function form(fields: Record<string, string>): RequestInit {
  return {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams(fields),
  };
}

/**
 * Trades [authorizationCode], fresh from the app, for the account's Apple
 * tokens and revokes them, so Apple no longer lists Etonia as signed in.
 */
export async function revokeAppleSignIn(authorizationCode: string): Promise<void> {
  const clientId = secret("APPLE_BUNDLE_ID");
  const tokens = await fetchJson(
    "https://appleid.apple.com/auth/token",
    form({
      client_id: clientId,
      client_secret: await clientSecret(),
      code: authorizationCode,
      grant_type: "authorization_code",
    }),
  );
  const refresh = typeof tokens.refresh_token === "string" ? tokens.refresh_token : null;
  const token = refresh ?? tokens.access_token;
  if (typeof token !== "string") return;
  const response = await fetch("https://appleid.apple.com/auth/revoke", {
    ...form({
      client_id: clientId,
      client_secret: await clientSecret(),
      token,
      token_type_hint: refresh ? "refresh_token" : "access_token",
    }),
    signal: AbortSignal.timeout(20000),
    redirect: "error",
  });
  await response.body?.cancel();
}
