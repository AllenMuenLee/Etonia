import { Buffer } from "node:buffer";
import {
  AppStoreServerAPIClient,
  Environment,
  SignedDataVerifier,
} from "@apple/app-store-server-library";
import { importPKCS8, SignJWT } from "jose";
import {
  Admin,
  decryptLocator,
  digest,
  encryptLocator,
  Failure,
  fetchJson,
  rpc,
  secret,
} from "./common.ts";

export interface Snapshot {
  platform: string;
  productId: string;
  chainKey: string;
  transactionKey: string;
  locatorCiphertext: string;
  expiresAt: string;
  active: boolean;
  status: string;
  autoRenew: boolean;
  observedAt: string;
  userId: string;
  needsAcknowledgement?: boolean;
}
export function appleVerifier() {
  const environment = secret("APPLE_ENVIRONMENT") === "Sandbox"
    ? Environment.SANDBOX
    : Environment.PRODUCTION;
  const roots = (JSON.parse(secret("APPLE_ROOT_CERTS_BASE64")) as string[]).map((s) =>
    Buffer.from(s, "base64")
  );
  return new SignedDataVerifier(
    roots,
    true,
    environment,
    secret("APPLE_BUNDLE_ID"),
    environment === Environment.PRODUCTION ? Number(secret("APPLE_APP_ID")) : undefined,
  );
}
export async function verifyApple(locator: string): Promise<Snapshot[]> {
  if (!/^\d{1,30}$/.test(locator)) throw new Failure("rejected");
  const observedAt = new Date().toISOString();
  const environment = secret("APPLE_ENVIRONMENT") === "Sandbox"
    ? Environment.SANDBOX
    : Environment.PRODUCTION;
  const client = new AppStoreServerAPIClient(
    secret("APPLE_PRIVATE_KEY").replaceAll("\\n", "\n"),
    secret("APPLE_KEY_ID"),
    secret("APPLE_ISSUER_ID"),
    secret("APPLE_BUNDLE_ID"),
    environment,
  );
  const verifier = appleVerifier();
  const response = await client.getAllSubscriptionStatuses(locator);
  const snapshots: Snapshot[] = [];
  for (const group of response.data ?? []) {
    for (const item of group.lastTransactions ?? []) {
      if (!item.signedTransactionInfo) continue;
      const transaction = await verifier.verifyAndDecodeTransaction(item.signedTransactionInfo);
      const renewal = item.signedRenewalInfo
        ? await verifier.verifyAndDecodeRenewalInfo(item.signedRenewalInfo)
        : null;
      if (
        !transaction.appAccountToken || !transaction.originalTransactionId ||
        !transaction.transactionId ||
        !transaction.productId || !transaction.expiresDate
      ) throw new Failure("purchase_owner", 403);
      const expires = item.status === 4
        ? (renewal?.gracePeriodExpiresDate ?? transaction.expiresDate)
        : transaction.expiresDate;
      snapshots.push({
        platform: "app_store",
        productId: transaction.productId,
        chainKey: `apple:${environment}:${transaction.originalTransactionId}`,
        transactionKey: `apple:${environment}:${transaction.transactionId}`,
        locatorCiphertext: await encryptLocator(transaction.originalTransactionId),
        expiresAt: new Date(expires).toISOString(),
        active: [1, 4].includes(item.status ?? 0) && !transaction.revocationDate &&
          expires > Date.now(),
        status: transaction.revocationDate ? "revoked" : String(item.status),
        autoRenew: renewal?.autoRenewStatus === 1,
        observedAt,
        userId: transaction.appAccountToken.toLowerCase(),
      });
    }
  }
  if (!snapshots.length) throw new Failure("verification_failed", 409);
  return snapshots;
}

let googleAuth: { token: string; expires: number } | undefined;
async function googleToken(): Promise<string> {
  if (googleAuth && googleAuth.expires > Date.now() + 60000) return googleAuth.token;
  const account = JSON.parse(secret("GOOGLE_SERVICE_ACCOUNT_JSON"));
  const jwt = await new SignJWT({ scope: "https://www.googleapis.com/auth/androidpublisher" })
    .setProtectedHeader({ alg: "RS256" }).setIssuer(account.client_email)
    .setAudience("https://oauth2.googleapis.com/token").setIssuedAt().setExpirationTime("1h")
    .sign(await importPKCS8(account.private_key, "RS256"));
  const token = await fetchJson("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer",
      assertion: jwt,
    }),
  });
  googleAuth = { token: token.access_token, expires: Date.now() + token.expires_in * 1000 };
  return googleAuth.token;
}
export async function verifyGoogle(locator: string): Promise<Snapshot[]> {
  if (!locator || locator.length > 8192) throw new Failure("rejected");
  const observedAt = new Date().toISOString();
  const purchase = await fetchJson(
    `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${
      encodeURIComponent(secret("GOOGLE_PACKAGE_NAME"))
    }/purchases/subscriptionsv2/tokens/${encodeURIComponent(locator)}`,
    {
      headers: { Authorization: `Bearer ${await googleToken()}` },
    },
  );
  if (purchase.testPurchase && Deno.env.get("ALLOW_GOOGLE_TEST_PURCHASES") !== "true") {
    throw new Failure("verification_failed", 403);
  }
  const owner = purchase.externalAccountIdentifiers?.obfuscatedExternalAccountId;
  if (typeof owner !== "string") throw new Failure("purchase_owner", 403);
  const eligible = [
    "SUBSCRIPTION_STATE_ACTIVE",
    "SUBSCRIPTION_STATE_IN_GRACE_PERIOD",
    "SUBSCRIPTION_STATE_CANCELED",
  ];
  const lines = (purchase.lineItems ?? []).filter((line: any) =>
    line.latestSuccessfulOrderId && line.expiryTime
  );
  // A deferred replacement is not an entitlement until it has a successful order.
  lines.sort((a: any, b: any) => Date.parse(b.expiryTime) - Date.parse(a.expiryTime));
  if (!lines.length) throw new Failure("verification_failed", 409);
  const line = lines[0];
  return [{
    platform: "google_play",
    productId: line.productId,
    chainKey: `google:${await digest(locator)}`,
    transactionKey: `google:${line.latestSuccessfulOrderId}`,
    locatorCiphertext: await encryptLocator(locator),
    expiresAt: line.expiryTime,
    active: eligible.includes(purchase.subscriptionState) &&
      Date.parse(line.expiryTime) > Date.now(),
    status: purchase.subscriptionState,
    autoRenew: line.autoRenewingPlan?.autoRenewEnabled === true,
    observedAt,
    userId: owner.toLowerCase(),
    needsAcknowledgement: purchase.acknowledgementState === "ACKNOWLEDGEMENT_STATE_PENDING" &&
      eligible.includes(purchase.subscriptionState),
  }];
}
export async function verifyStore(platform: string, locator: string): Promise<Snapshot[]> {
  if (platform === "app_store") return await verifyApple(locator);
  if (platform === "google_play") return await verifyGoogle(locator);
  throw new Failure("rejected");
}
export async function applySnapshots(db: Admin, owner: string, snapshots: Snapshot[]) {
  // Validate every owner before making any change. Legacy unbound purchases
  // require an explicit administrator migration; never let the first caller claim them.
  if (snapshots.some((s) => s.userId !== owner)) throw new Failure("purchase_owner", 403);
  for (const snapshot of snapshots) {
    await rpc(db, "billing_apply", { p_user: owner, p_snapshot: snapshot });
    if (snapshot.platform === "google_play" && snapshot.needsAcknowledgement) {
      const token = await decryptLocator(snapshot.locatorCiphertext);
      const response = await fetch(
        `https://androidpublisher.googleapis.com/androidpublisher/v3/applications/${
          encodeURIComponent(secret("GOOGLE_PACKAGE_NAME"))
        }/purchases/subscriptions/${encodeURIComponent(snapshot.productId)}/tokens/${
          encodeURIComponent(token)
        }:acknowledge`,
        {
          method: "POST",
          headers: {
            Authorization: `Bearer ${await googleToken()}`,
            "Content-Type": "application/json",
          },
          body: "{}",
          signal: AbortSignal.timeout(20000),
          redirect: "error",
        },
      );
      await response.body?.cancel();
      if (!response.ok) throw new Failure("verification_failed", 503);
    }
  }
}
export async function reconcile(db: Admin, owner: string) {
  const locators = await rpc(db, "billing_locators", { p_user: owner });
  for (const saved of locators) {
    await applySnapshots(
      db,
      owner,
      await verifyStore(saved.platform, await decryptLocator(saved.locatorCiphertext)),
    );
  }
}
