import { accountFor, admin, deviceIdOf, endpoint, Failure, json, readBody, rpc } from "../_shared/common.ts";
import { applySnapshots, reconcile, verifyStore } from "../_shared/stores.ts";
import { canRevokeAppleSignIn, revokeAppleSignIn } from "../_shared/apple_sign_in.ts";

Deno.serve(endpoint(async (req) => {
  const db = admin();
  const account = await accountFor(req, db);
  const user = account.id;
  await rpc(db, "billing_rate_limit", { p_user: user });
  const body = await readBody(req);
  if (body.action === "delete_account") {
    // Deleting the auth user cascades to every billing and analytics row of
    // the account; App Store subscriptions are cancelled by the user with
    // Apple. Anonymous device accounts have nothing to delete.
    if (account.anonymous) throw new Failure("unauthorized", 401);
    const code = body.appleAuthorizationCode;
    if (typeof code === "string" && code.length <= 1024 && canRevokeAppleSignIn()) {
      // Best effort: the account is deleted even if Apple is unreachable.
      try {
        await revokeAppleSignIn(code);
      } catch (_) {
        // Nothing is logged; see the privacy boundary in supabase/README.md.
      }
    }
    const { error } = await db.auth.admin.deleteUser(user);
    if (error) throw new Failure("server", 500);
    return json({ deleted: true });
  }
  await rpc(db, "billing_touch", {
    p_user: user,
    p_anonymous: account.anonymous,
    p_device: deviceIdOf(body.deviceId),
  });
  if (body.action === "verify") {
    // Purchases are bound to a Google account so they survive reinstalls.
    if (account.anonymous) throw new Failure("unauthorized", 401);
    const locator = body.platform === "app_store" ? body.purchaseId : body.verificationData;
    if (typeof locator !== "string" || typeof body.productId !== "string") {
      throw new Failure("rejected");
    }
    const snapshots = await verifyStore(body.platform, locator);
    if (!snapshots.some((s) => s.productId === body.productId)) {
      throw new Failure("verification_failed", 409);
    }
    await applySnapshots(db, user, snapshots);
  } else if (body.action === "redeem") {
    if (typeof body.code !== "string" || body.code.length > 64) throw new Failure("rejected");
    return json(
      await rpc(db, "billing_redeem_gift", {
        p_user: user,
        p_anonymous: account.anonymous,
        p_code: body.code,
      }),
    );
  } else if (body.action === "status") {
    if (!account.anonymous) await reconcile(db, user);
  } else throw new Failure("rejected");
  return json(await rpc(db, "billing_state", { p_user: user }));
}));
