import { PGlite } from "npm:@electric-sql/pglite@0.3.14";
import { strict as assert } from "node:assert";

const user = "11111111-1111-4111-8111-111111111111";
const other = "22222222-2222-4222-8222-222222222222";
const req1 = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const req2 = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

/** A database with Supabase's roles and every migration applied in order. */
async function migrated(): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role;
    create schema auth; create table auth.users(id uuid primary key);
    insert into auth.users values ('${user}'), ('${other}');`);
  const folder = new URL("../migrations/", import.meta.url);
  const names = [];
  for await (const entry of Deno.readDir(folder)) {
    if (entry.name.endsWith(".sql")) names.push(entry.name);
  }
  for (const name of names.sort()) {
    await db.exec(await Deno.readTextFile(new URL(name, folder)));
  }
  return db;
}

Deno.test("free credit: one time, Google accounts only, once per device", async () => {
  const db = await migrated();
  try {
    const third = "33333333-3333-4333-8333-333333333333";
    const phone = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const tablet = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee";
    await db.exec(`insert into auth.users values ('${third}')`);
    await db.exec("set role service_role");
    const touch = (id: string, anonymous: boolean, device: string | null) =>
      db.query("select public.billing_touch($1, $2, $3)", [id, anonymous, device]);
    const state = async (id: string) =>
      (await db.query<{ s: any }>("select public.billing_state($1) s", [id])).rows[0].s;
    const reserve = (id: string, request: string, model: string) =>
      db.query("select public.ai_reserve($1,$2,$3) r", [id, request, model]);
    const settle = (id: string, request: string, cost: number) =>
      db.query("select public.ai_settle($1,$2,$3,10,10,false)", [id, request, cost]);

    // Anonymous device accounts, and calls without a device, get nothing.
    await touch(user, true, phone);
    await touch(user, false, null);
    assert.equal((await state(user)).remainingCreditsMicroUsd, 0);
    await assert.rejects(() => reserve(user, req1, "haiku"), /plan_required/);

    // After Google sign-in on the device: $0.50, once.
    await touch(user, false, phone);
    await touch(user, false, phone);
    await touch(user, false, tablet);
    const granted = await state(user);
    assert.equal(granted.plan, "free");
    assert.equal(granted.activePlan, null);
    assert.equal(granted.remainingCreditsMicroUsd, 500000);
    assert.equal(granted.freeCreditMicroUsd, 500000);
    // Tablet was not consumed, phone was.
    await touch(third, false, tablet);
    assert.equal((await state(third)).remainingCreditsMicroUsd, 500000);
    await touch(other, false, phone);
    assert.equal((await state(other)).remainingCreditsMicroUsd, 0);

    // Free credit pays for Haiku/Luna/Sonnet/Sol, never frontier models.
    await assert.rejects(() => reserve(user, req1, "opus"), /plan_required/);
    const held = (await reserve(user, req1, "haiku")).rows[0] as { r: any };
    assert.deepEqual(held.r, { reserved: 500000, unlimited: false });
    await settle(user, req1, 450000);
    assert.equal((await state(user)).remainingCreditsMicroUsd, 50000);
    await reserve(user, req2, "sonnet");
    await settle(user, req2, 999999); // Capped at what was reserved.
    assert.equal((await state(user)).remainingCreditsMicroUsd, 0);
    await assert.rejects(
      () => reserve(user, "cccccccc-cccc-4ccc-8ccc-cccccccccccc", "luna"),
      /insufficient_credits/,
    );
    await touch(user, false, phone); // Spent credit never refills.
    assert.equal((await state(user)).remainingCreditsMicroUsd, 0);
  } finally {
    await db.close();
  }
});

Deno.test("Postgres billing: permissions, ownership, renewals, expiry and atomic credits", async () => {
  const db = await migrated();
  try {
    const snapshot = (tx = "first", active = true, future = true) => ({
      platform: "google_play",
      productId: "etonia_plan_1299_monthly",
      chainKey: "google:chain",
      transactionKey: `google:${tx}`,
      locatorCiphertext: "encrypted",
      active,
      expiresAt: new Date(Date.now() + (future ? 86400000 : -86400000)).toISOString(),
      status: active ? "active" : "revoked",
      autoRenew: true,
      observedAt: new Date().toISOString(),
    });
    const apply = (s: ReturnType<typeof snapshot>, owner = user) =>
      db.query(
        "select public.billing_apply($1, $2::jsonb)",
        [owner, JSON.stringify(s)],
      );
    const state = async () =>
      (await db.query<{ state: any }>(
        "select public.billing_state($1) state",
        [user],
      )).rows[0].state;
    const reserve = (id = req1, model = "sol", max: number | null = null) =>
      db.query(
        "select public.ai_reserve($1,$2,$3,$4)",
        [user, id, model, max],
      );
    const settle = (id = req1, release = false) =>
      db.query(
        "select public.ai_settle($1,$2,100000,100,100,$3)",
        [user, id, release],
      );

    await db.exec("set role authenticated");
    await assert.rejects(() => state(), /permission denied/);
    await assert.rejects(() => apply(snapshot()), /permission denied/);
    await assert.rejects(
      () => db.query("select * from billing_private.grants"),
      /permission denied/,
    );
    await assert.rejects(
      () => db.query("select public.billing_touch($1, true, null)", [user]),
      /permission denied/,
    );
    await db.exec("reset role; set role service_role");
    assert.equal((await state()).activePlan, null);
    assert.equal((await state()).plan, "free");
    await assert.rejects(() => reserve(), /plan_required/); // Free never unlocks AI.
    await apply(snapshot());
    assert.equal((await state()).plan, "pro1299");
    assert.equal((await state()).remainingCreditsMicroUsd, 4000000);
    // Requests run alongside each other, each holding only its own cap.
    await reserve(req1, "sol", 1000000);
    await reserve(req2, "sol", 1000000);
    assert.equal((await state()).remainingCreditsMicroUsd, 2000000);
    await settle();
    assert.equal((await state()).remainingCreditsMicroUsd, 2900000);
    await settle();
    assert.equal((await state()).remainingCreditsMicroUsd, 2900000);
    await settle(req2, true);
    assert.equal((await state()).remainingCreditsMicroUsd, 3900000);
    await apply(snapshot());
    assert.equal((await state()).remainingCreditsMicroUsd, 3900000);
    await assert.rejects(() => reserve(), /request_in_progress/);
    await assert.rejects(() => reserve(crypto.randomUUID(), "sol", 0), /rejected/);
    // At most four at once; one stuck pending for ten minutes stops counting
    // toward that, though it keeps its hold for an administrator.
    const running = [1, 2, 3, 4].map(() => crypto.randomUUID());
    for (const id of running) await reserve(id, "sol", 1000);
    await assert.rejects(() => reserve(crypto.randomUUID(), "sol", 1000), /request_in_progress/);
    await db.exec(`reset role; update billing_private.requests
      set created_at = now() - interval '11 minutes' where request_id = '${running[0]}';
      set role service_role`);
    const after = crypto.randomUUID();
    await reserve(after, "sol", 1000);
    for (const id of [...running.slice(1), after]) await settle(id, true);
    assert.equal((await state()).remainingCreditsMicroUsd, 3899000);
    await assert.rejects(() => apply(snapshot(), other), /purchase_owner/);
    const last = crypto.randomUUID();
    await reserve(last); // Without a cap, the whole balance is held.
    assert.equal((await state()).remainingCreditsMicroUsd, 0);
    await apply(snapshot("renewal"));
    assert.equal((await state()).remainingCreditsMicroUsd, 4000000);
    await settle(last, true); // Old request must never add credits to a new grant.
    assert.equal((await state()).remainingCreditsMicroUsd, 4000000);
    await apply(snapshot("renewal", false));
    assert.equal((await state()).activePlan, null);
    await assert.rejects(() => reserve("cccccccc-cccc-4ccc-8ccc-cccccccccccc"), /plan_required/);
    await apply(snapshot("renewal", true, false));
    assert.equal((await state()).activePlan, null);
    const starter = { ...snapshot("starter"), productId: "etonia_plan_499_monthly" };
    await apply(starter);
    await assert.rejects(
      () => reserve("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "astra"),
      /plan_required/,
    );
    await reserve("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "haiku");
    assert.equal((await state()).remainingCreditsMicroUsd, 1200000);
    // A device seen first anonymously, then under a Google account.
    const device = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    await db.query("select public.billing_touch($1, true, $2)", [other, device]);
    // The dashboard reads the view as an administrator, not as service_role.
    const plans = async () => {
      await db.exec("reset role");
      const rows = (await db.query<{ user_id: string; is_anonymous: boolean; plan: string; devices: number }>(
        "select user_id, is_anonymous, plan, devices::int from billing_private.account_plans order by user_id",
      )).rows;
      await db.exec("set role service_role");
      return rows;
    };
    assert.deepEqual(await plans(), [
      { user_id: user, is_anonymous: false, plan: "starter499", devices: 0 },
      { user_id: other, is_anonymous: true, plan: "free", devices: 1 },
    ]);
    await db.query("select public.billing_touch($1, false, $2)", [user, device]);
    await db.query("select public.billing_touch($1, false, null)", [other]);
    assert.deepEqual(await plans(), [
      { user_id: user, is_anonymous: false, plan: "starter499", devices: 1 },
      { user_id: other, is_anonymous: false, plan: "free", devices: 0 },
    ]);
    await db.exec("reset role");
    await assert.rejects(
      () => db.query("insert into billing_private.products values ('app_store', 'x', 'free', 0, 1)"),
      /products_paid_plan/,
    );
    const tables = (await db.query<{ table_name: string }>(
      "select table_name from information_schema.tables where table_schema = 'billing_private'",
    )).rows.map((r) => r.table_name).sort();
    assert.deepEqual(tables, [
      "account_plans",
      "accounts",
      "devices",
      "gift_codes",
      "gift_redemptions",
      "grants",
      "plans",
      "products",
      "rate_buckets",
      "requests",
      "subscription_events",
      "subscriptions",
    ]);
  } finally {
    await db.close();
  }
});

Deno.test("gift codes: $3 of free credit per account, all free credit lasts a month", async () => {
  const db = await migrated();
  try {
    const phone = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    await db.exec(`insert into billing_private.accounts(user_id) values ('${user}'), ('${other}');
      insert into billing_private.gift_codes(code, max_redemptions) values ('WELCOME3', 1);`);
    await db.exec("set role service_role");
    const state = async (id: string) =>
      (await db.query<{ s: any }>("select public.billing_state($1) s", [id])).rows[0].s;
    const redeem = (id: string, anonymous: boolean, code: string) =>
      db.query<{ s: any }>("select public.billing_redeem_gift($1,$2,$3) s", [id, anonymous, code]);

    await assert.rejects(() => redeem(user, true, "WELCOME3"), /unauthorized/);
    await assert.rejects(() => redeem(user, false, "NOPE-NOPE"), /invalid_code/);

    // Free credit ($0.50) first, then the gift stacks on it; the month restarts.
    await db.query("select public.billing_touch($1, false, $2)", [user, phone]);
    const first = await state(user);
    assert.equal(first.remainingCreditsMicroUsd, 500000);
    const expiry = new Date(first.freeCreditExpiresAt).getTime();
    assert.ok(Math.abs(expiry - Date.now() - 30 * 86400000) < 2 * 86400000);
    const gifted = (await redeem(user, false, " welcome3 ")).rows[0].s;
    assert.equal(gifted.remainingCreditsMicroUsd, 3500000);
    assert.equal(gifted.freeCreditMicroUsd, 3500000);
    await assert.rejects(() => redeem(user, false, "WELCOME3"), /code_redeemed/);
    await assert.rejects(() => redeem(other, false, "WELCOME3"), /code_exhausted/);

    // A gift needs no earlier grant: it creates the free credit.
    await db.exec("reset role");
    await db.exec(`update billing_private.gift_codes set max_redemptions = null`);
    await db.exec("set role service_role");
    assert.equal((await redeem(other, false, "WELCOME3")).rows[0].s.remainingCreditsMicroUsd, 3000000);

    // After a month the credit is none and cannot be reserved.
    await db.exec("reset role");
    await db.exec(`update billing_private.grants set expires_at = now() - interval '1 second'
      where transaction_key = 'free:${user}'`);
    await db.exec("set role service_role");
    assert.equal((await state(user)).remainingCreditsMicroUsd, 0);
    await assert.rejects(
      () => db.query("select public.ai_reserve($1,$2,$3)", [user, req1, "haiku"]),
      /insufficient_credits/,
    );
    // A new gift after expiry starts fresh rather than reviving the old balance.
    await db.exec("reset role");
    await db.exec(`insert into billing_private.gift_codes(code) values ('SECOND3')`);
    await db.exec("set role service_role");
    const renewed = (await redeem(user, false, "SECOND3")).rows[0].s;
    assert.equal(renewed.remainingCreditsMicroUsd, 3000000);
    assert.equal(renewed.freeCreditMicroUsd, 3000000);
  } finally {
    await db.close();
  }
});
