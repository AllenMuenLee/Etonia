import { createRemoteJWKSet, jwtVerify } from "jose";
import { admin, endpoint, Failure, json, readBody, secret } from "../_shared/common.ts";
import { appleVerifier, applySnapshots, verifyApple, verifyGoogle } from "../_shared/stores.ts";

const googleKeys = createRemoteJWKSet(new URL("https://www.googleapis.com/oauth2/v3/certs"));
Deno.serve(endpoint(async (req) => {
  const body = await readBody(req);
  const db = admin();
  let snapshots;
  if (typeof body.signedPayload === "string") {
    const verifier = appleVerifier();
    const notification = await verifier.verifyAndDecodeNotification(body.signedPayload);
    if (!notification.data?.signedTransactionInfo) return json({ received: true });
    const transaction = await verifier.verifyAndDecodeTransaction(
      notification.data.signedTransactionInfo,
    );
    if (!transaction.originalTransactionId) throw new Failure("rejected");
    snapshots = await verifyApple(transaction.originalTransactionId);
  } else {
    const token = req.headers.get("authorization")?.match(/^Bearer (.+)$/i)?.[1];
    if (!token) throw new Failure("unauthorized", 401);
    const { payload } = await jwtVerify(token, googleKeys, {
      audience: secret("GOOGLE_PUSH_AUDIENCE"),
      issuer: ["https://accounts.google.com", "accounts.google.com"],
    });
    if (
      payload.email !== secret("GOOGLE_PUSH_SERVICE_ACCOUNT_EMAIL") ||
      payload.email_verified !== true
    ) {
      throw new Failure("unauthorized", 401);
    }
    const event = JSON.parse(atob(body.message?.data ?? ""));
    if (event.packageName !== secret("GOOGLE_PACKAGE_NAME")) throw new Failure("rejected");
    if (event.testNotification) return json({ received: true });
    const tokenId = event.subscriptionNotification?.purchaseToken ??
      event.voidedPurchaseNotification?.purchaseToken;
    if (typeof tokenId !== "string") return json({ received: true });
    snapshots = await verifyGoogle(tokenId);
  }
  for (const snapshot of snapshots) await applySnapshots(db, snapshot.userId, [snapshot]);
  return json({ received: true });
}));
