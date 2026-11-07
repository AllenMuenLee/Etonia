import { PGlite } from "npm:@electric-sql/pglite@0.3.14";
import { strict as assert } from "node:assert";
import { describePass } from "../functions/_shared/ai_usage.ts";

Deno.test("AI per-pass settlement is atomic, private, reconciled, and idempotent", async () => {
  const db = await migrated();
  try {
    await db.exec("set role service_role");
    await db.query("select public.billing_touch($1,false,$2)", [
      user,
      "dddddddd-dddd-4ddd-8ddd-dddddddddddd",
    ]);
    await db.query("select public.ai_reserve($1,$2,'sol')", [user, req1]);
    const pass = describePass(
      "sol",
      {
        provider: "openai",
        model: "gpt-6.1-sol",
        inputMicroPerKilo: 2000,
        outputMicroPerKilo: 10000,
        maxOutputTokens: 4096,
        cachedInputMicroPerKilo: 100,
        cacheWriteMicroPerKilo: 2500,
      },
      "low",
      "answer",
      { input: 2000, output: 100, cached: 1000, cacheWrites: 500, reasoning: 60 },
    );
    const settle = (details: unknown, cost = pass.costMicro, actor = user) =>
      db.query(
        "select public.ai_settle_usage($1,$2,$3,2000,100,false,'study.answer',$4,'low',$5::jsonb)",
        [actor, req1, cost, req2, JSON.stringify(details)],
      );
    await assert.rejects(() => settle([{ ...pass, prompt: "must never be stored" }]), /rejected/);
    await assert.rejects(() => settle([pass], pass.costMicro + 1), /rejected/);
    await assert.rejects(() => settle([pass], pass.costMicro, other));
    await db.exec("reset role");
    assert.equal(
      (await db.query<{ status: string }>(
        "select status from billing_private.requests where request_id=$1",
        [req1],
      )).rows[0].status,
      "pending",
    );
    await db.exec("set role service_role");
    await settle([pass]);
    await settle([{ ...pass, prompt: "idempotent retries cannot replace metadata" }]);
    await db.exec("reset role");
    const row = (await db.query<Record<string, unknown>>(
      "select task,turn_id,effort,provider_cost,usage_details from billing_private.requests where request_id=$1",
      [req1],
    )).rows[0];
    assert.equal(row.task, "study.answer");
    assert.equal(row.turn_id, req2);
    assert.equal(Number(row.provider_cost), pass.costMicro);
    assert.deepEqual(row.usage_details, { pricingVersion: "token-v2", passes: [pass] });
    await db.exec("set role authenticated");
    await assert.rejects(() => settle([pass]), /permission denied/);
    await assert.rejects(
      () => db.query("select * from billing_private.requests"),
      /permission denied/,
    );
  } finally {
    await db.close();
  }
});

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
    assert.deepEqual(held.r, { reserved: 0, unlimited: false });
    await settle(user, req1, 450000);
    assert.equal((await state(user)).remainingCreditsMicroUsd, 50000);
    await reserve(user, req2, "sonnet");
    await settle(user, req2, 999999);
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

Deno.test("final pricing: plans, credits, and old products on their renamed tiers", async () => {
  const db = await migrated();
  try {
    const plans = (await db.query(
      "select plan, rank, title, monthly_price_cents from billing_private.plans order by rank",
    )).rows;
    assert.deepEqual(plans, [
      { plan: "free", rank: 0, title: "Free", monthly_price_cents: 0 },
      { plan: "starter699", rank: 1, title: "Starter", monthly_price_cents: 699 },
      { plan: "pro1499", rank: 2, title: "Pro", monthly_price_cents: 1499 },
      { plan: "max2499", rank: 3, title: "Max", monthly_price_cents: 2499 },
    ]);
    const product = async (id: string) =>
      (await db.query(
        "select plan, rank, allowance::int from billing_private.products where product_id = $1",
        [
          id,
        ],
      )).rows[0];
    assert.deepEqual(await product("etonia_plan_699_monthly"), {
      plan: "starter699",
      rank: 1,
      allowance: 2450000,
    });
    assert.deepEqual(await product("com.etonia.app.plan.1499.monthly"), {
      plan: "pro1499",
      rank: 2,
      allowance: 5250000,
    });
    assert.deepEqual(await product("etonia_plan_2499_monthly"), {
      plan: "max2499",
      rank: 3,
      allowance: 8750000,
    });
    assert.deepEqual(await product("com.etonia.app.plan.699.yearly"), {
      plan: "starter699",
      rank: 1,
      allowance: 29400000,
    });
    assert.deepEqual(await product("etonia_plan_1499_yearly"), {
      plan: "pro1499",
      rank: 2,
      allowance: 63000000,
    });
    assert.deepEqual(await product("com.etonia.app.plan.2499.yearly"), {
      plan: "max2499",
      rank: 3,
      allowance: 105000000,
    });
    // Retired, but still honoured for a subscription already on it.
    assert.deepEqual(await product("etonia_plan_1299_monthly"), {
      plan: "pro1499",
      rank: 2,
      allowance: 4000000,
    });
    assert.equal(
      (await db.query<{ n: number }>(
        "select count(*)::int n from billing_private.products where plan not in ('starter699','pro1499','max2499')",
      ))
        .rows[0].n,
      0,
    );
  } finally {
    await db.close();
  }
});

Deno.test("Postgres billing: permissions, ownership, renewals, expiry and atomic credits", async () => {
  const db = await migrated();
  try {
    const snapshot = (tx = "first", active = true, future = true) => ({
      platform: "google_play",
      productId: "etonia_plan_1499_monthly",
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
    assert.equal((await state()).plan, "pro1499");
    assert.equal((await state()).remainingCreditsMicroUsd, 5250000);
    // Requests run alongside each other without holding/draining the balance upfront.
    await reserve(req1, "sol", 1000000);
    await reserve(req2, "sol", 1000000);
    assert.equal((await state()).remainingCreditsMicroUsd, 5250000);
    await settle();
    assert.equal((await state()).remainingCreditsMicroUsd, 5150000);
    await settle();
    assert.equal((await state()).remainingCreditsMicroUsd, 5150000);
    await settle(req2, true);
    assert.equal((await state()).remainingCreditsMicroUsd, 5150000);
    await apply(snapshot());
    assert.equal((await state()).remainingCreditsMicroUsd, 5150000);
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
    assert.equal((await state()).remainingCreditsMicroUsd, 5150000);
    await assert.rejects(() => apply(snapshot(), other), /purchase_owner/);
    const last = crypto.randomUUID();
    await reserve(last); // If remaining > 0, always accepted without pre-deducting balance.
    assert.equal((await state()).remainingCreditsMicroUsd, 5150000);
    await apply(snapshot("renewal"));
    assert.equal((await state()).remainingCreditsMicroUsd, 5250000);
    await settle(last, true); // Old request must never add credits to a new grant.
    assert.equal((await state()).remainingCreditsMicroUsd, 5250000);
    await apply(snapshot("renewal", false));
    assert.equal((await state()).activePlan, null);
    await assert.rejects(() => reserve("cccccccc-cccc-4ccc-8ccc-cccccccccccc"), /plan_required/);
    await apply(snapshot("renewal", true, false));
    assert.equal((await state()).activePlan, null);
    const starter = { ...snapshot("starter"), productId: "etonia_plan_699_monthly" };
    await apply(starter);
    await assert.rejects(
      () => reserve("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "astra"),
      /plan_required/,
    );
    await reserve("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "haiku");
    assert.equal((await state()).remainingCreditsMicroUsd, 2450000);
    // A device seen first anonymously, then under a Google account.
    const device = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    await db.query("select public.billing_touch($1, true, $2)", [other, device]);
    // The dashboard reads the view as an administrator, not as service_role.
    const plans = async () => {
      await db.exec("reset role");
      const rows =
        (await db.query<{ user_id: string; is_anonymous: boolean; plan: string; devices: number }>(
          "select user_id, is_anonymous, plan, devices::int from billing_private.account_plans order by user_id",
        )).rows;
      await db.exec("set role service_role");
      return rows;
    };
    assert.deepEqual(await plans(), [
      { user_id: user, is_anonymous: false, plan: "starter699", devices: 0 },
      { user_id: other, is_anonymous: true, plan: "free", devices: 1 },
    ]);
    await db.query("select public.billing_touch($1, false, $2)", [user, device]);
    await db.query("select public.billing_touch($1, false, null)", [other]);
    assert.deepEqual(await plans(), [
      { user_id: user, is_anonymous: false, plan: "starter699", devices: 1 },
      { user_id: other, is_anonymous: false, plan: "free", devices: 0 },
    ]);
    await db.exec("reset role");
    await assert.rejects(
      () =>
        db.query("insert into billing_private.products values ('app_store', 'x', 'free', 0, 1)"),
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
    assert.equal(
      (await redeem(other, false, "WELCOME3")).rows[0].s.remainingCreditsMicroUsd,
      3000000,
    );

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

Deno.test("deleting an account erases its records but not the device's free-credit claim", async () => {
  const db = await migrated();
  try {
    const phone = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    const again = "33333333-3333-4333-8333-333333333333";
    await db.exec("set role service_role");
    const touch = (id: string, device: string) =>
      db.query("select public.billing_touch($1, false, $2)", [id, device]);
    const state = async (id: string) =>
      (await db.query<{ s: any }>("select public.billing_state($1) s", [id])).rows[0].s;

    await touch(user, phone);
    await db.query("select public.billing_rate_limit($1)", [user]);
    await db.query("select public.ai_reserve($1,$2,'haiku')", [user, req1]);
    await db.query("select public.ai_settle($1,$2,1000,10,10,false)", [user, req1]);
    assert.equal((await state(user)).remainingCreditsMicroUsd, 499000);

    // What the app's Delete account does on the server: delete the auth user.
    await db.exec(`reset role; delete from auth.users where id = '${user}'`);
    for (const table of ["accounts", "grants", "requests", "rate_buckets", "subscriptions"]) {
      const left = await db.query<{ n: number }>(
        `select count(*)::int n from billing_private.${table} where user_id = $1`,
        [user],
      );
      assert.equal(left.rows[0].n, 0, `${table} still holds the deleted account`);
    }
    const device = await db.query<{ user_id: string | null; claimed: boolean }>(
      `select user_id, free_credit_claimed_at is not null claimed
         from billing_private.devices where device_id = $1`,
      [phone],
    );
    assert.deepEqual(device.rows[0], { user_id: null, claimed: true });

    // Signing up again on the same device does not bring the free credit back.
    await db.exec(`insert into auth.users values ('${again}'); set role service_role`);
    await touch(again, phone);
    assert.equal((await state(again)).remainingCreditsMicroUsd, 0);
  } finally {
    await db.close();
  }
});

Deno.test("router billing: unlimited only on a paid plan, Haiku or Luna, up to medium effort", async () => {
  const db = await migrated();
  try {
    const phone = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    await db.exec("set role service_role");
    const state = async () =>
      (await db.query<{ s: any }>("select public.billing_state($1) s", [user])).rows[0].s;
    const reserve = async (model: string, effort: string) => {
      const id = crypto.randomUUID();
      const held = (await db.query<{ r: any }>(
        "select public.ai_reserve($1,$2,$3,null,$4) r",
        [user, id, model, effort],
      )).rows[0].r;
      return { id, unlimited: held.unlimited as boolean };
    };
    const settle = (id: string, cost = 100000) =>
      db.query("select public.ai_settle($1,$2,$3,10,10,false)", [user, id, cost]);
    const charged = async (id: string) => {
      await db.exec("reset role");
      const row = (await db.query<{ charged: string; provider_cost: string; unlimited: boolean }>(
        `select charged::text, provider_cost::text, unlimited
           from billing_private.requests where request_id = $1`,
        [id],
      )).rows[0];
      await db.exec("set role service_role");
      return row;
    };

    // Free credit pays for everything, so nothing is unlimited on it.
    await db.query("select public.billing_touch($1, false, $2)", [user, phone]);
    const free = await reserve("haiku", "low");
    assert.equal(free.unlimited, false);
    await settle(free.id, 1000);
    assert.equal((await state()).remainingCreditsMicroUsd, 499000);

    await db.exec("reset role");
    await db.exec(
      `update billing_private.grants set remaining = 0 where transaction_key = 'free:${user}'`,
    );
    await db.exec("set role service_role");
    // A free plan with nothing left is refused, whatever it asks for.
    for (const effort of ["low", "medium", "high"]) {
      await assert.rejects(() => reserve("luna", effort), /insufficient_credits/);
    }

    // A paid plan: Haiku and Luna at low and medium effort cost nothing.
    await db.query("select public.billing_apply($1, $2::jsonb)", [
      user,
      JSON.stringify({
        platform: "google_play",
        productId: "etonia_plan_1499_monthly",
        chainKey: "google:chain",
        transactionKey: "google:first",
        locatorCiphertext: "encrypted",
        active: true,
        expiresAt: new Date(Date.now() + 86400000).toISOString(),
        status: "active",
        autoRenew: true,
        observedAt: new Date().toISOString(),
      }),
    ]);
    assert.equal((await state()).remainingCreditsMicroUsd, 5250000);
    for (const [model, effort] of [["haiku", "low"], ["luna", "medium"], ["haiku", "medium"]]) {
      const request = await reserve(model, effort);
      assert.equal(request.unlimited, true, `${model} at ${effort}`);
      await settle(request.id);
      assert.deepEqual(await charged(request.id), {
        charged: "0",
        provider_cost: "100000",
        unlimited: true,
      });
    }
    assert.equal((await state()).remainingCreditsMicroUsd, 5250000);

    // High effort on them, and every other model, is metered.
    for (
      const [model, effort] of [["haiku", "high"], ["luna", "high"], ["sonnet", "low"], [
        "sol",
        "medium",
      ]]
    ) {
      const request = await reserve(model, effort);
      assert.equal(request.unlimited, false, `${model} at ${effort}`);
      await settle(request.id);
      assert.equal((await charged(request.id)).charged, "100000");
    }
    assert.equal((await state()).remainingCreditsMicroUsd, 5250000 - 4 * 100000);

    // Out of credits, a paid plan still reaches the unlimited pairs and nothing else.
    await db.exec("reset role");
    await db.exec(
      `update billing_private.grants set remaining = 0 where transaction_key = 'google:first'`,
    );
    await db.exec("set role service_role");
    for (const [model, effort] of [["haiku", "high"], ["sol", "low"], ["sonnet", "medium"]]) {
      await assert.rejects(() => reserve(model, effort), /insufficient_credits/);
    }
    const carried = await reserve("luna", "medium");
    assert.equal(carried.unlimited, true);
    await settle(carried.id, 250000);
    assert.equal((await state()).remainingCreditsMicroUsd, 0);

    await assert.rejects(() => reserve("haiku", "extreme"), /rejected/);
  } finally {
    await db.close();
  }
});

Deno.test("embeddings: charged once from credits, never unlimited, and apart from answer limits", async () => {
  const db = await migrated();
  try {
    const phone = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
    await db.exec("set role service_role");
    const balance = async () =>
      (await db.query<{ s: any }>("select public.billing_state($1) s", [user])).rows[0].s
        .remainingCreditsMicroUsd;
    // No credit was ever granted: refused.
    await assert.rejects(() => db.query("select public.embed_admit($1)", [user]), /plan_required/);
    await db.query("select public.billing_touch($1, false, $2)", [user, phone]);
    await db.query("select public.embed_admit($1)", [user]);
    const request = crypto.randomUUID();
    await db.query("select public.embed_settle($1,$2,$3,$4)", [user, request, 1200, 400]);
    assert.equal(await balance(), 500000 - 1200);
    // The same request id again costs nothing more.
    await db.query("select public.embed_settle($1,$2,$3,$4)", [user, request, 1200, 400]);
    assert.equal(await balance(), 500000 - 1200);

    // Embedding rows do not use up the answer limits (4 pending, 300 a day).
    await db.exec("reset role");
    await db.exec(
      `insert into billing_private.requests(request_id,user_id,transaction_key,model,reserved,charged,provider_cost,status)
      select gen_random_uuid(), '${user}', 'free:${user}', 'embed', 0, 0, 0, 'settled' from generate_series(1, 320)`,
    );
    await db.exec("set role service_role");
    const answer = await db.query<{ r: any }>(
      "select public.ai_reserve($1,$2,'haiku',null,'low') r",
      [user, crypto.randomUUID()],
    );
    assert.equal(answer.rows[0].r.unlimited, false);
    // ...and have their own: forty a minute.
    await assert.rejects(() => db.query("select public.embed_admit($1)", [user]), /rate_limited/);

    // Nothing left: refused.
    await db.exec("reset role");
    await db.exec("delete from billing_private.requests where model = 'embed'");
    await db.exec(
      `update billing_private.grants set remaining = 0 where transaction_key = 'free:${user}'`,
    );
    await db.exec("set role service_role");
    await assert.rejects(
      () => db.query("select public.embed_admit($1)", [user]),
      /insufficient_credits/,
    );
  } finally {
    await db.close();
  }
});
