import { PGlite } from "npm:@electric-sql/pglite@0.3.14";
import { strict as assert } from "node:assert";

const user = "11111111-1111-4111-8111-111111111111";
const device = "dddddddd-dddd-4ddd-8ddd-dddddddddddd";
const session = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
const event = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";

async function migrated(): Promise<PGlite> {
  const db = new PGlite();
  await db.exec(`create role anon; create role authenticated; create role service_role;
    create schema auth; create table auth.users(id uuid primary key);
    insert into auth.users values ('${user}');`);
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

Deno.test("launch analytics are private, idempotent and feed dashboard views", async () => {
  const db = await migrated();
  try {
    await db.exec("set role authenticated");
    await assert.rejects(
      () => db.query("select * from analytics_private.events"),
      /permission denied/,
    );
    await assert.rejects(
      () =>
        db.query(
          "select public.analytics_ingest($1,false,$2,$3,$4,'app_open','android',null,null)",
          [user, device, event, session],
        ),
      /permission denied/,
    );

    await db.exec("reset role; set role service_role");
    await db.query("select public.billing_touch($1, false, $2)", [user, device]);
    const ingest = (id: string, name: string, detail: string | null = null) =>
      db.query<{ accepted: boolean }>(
        "select public.analytics_ingest($1,false,$2,$3,$4,$5,'android','0.1.0+1',$6) accepted",
        [user, device, id, session, name, detail],
      );
    assert.equal((await ingest(event, "app_open")).rows[0].accepted, true);
    assert.equal((await ingest(event, "app_open")).rows[0].accepted, false);
    await assert.rejects(
      () => ingest("ffffffff-ffff-4fff-8fff-ffffffffffff", "note_created", "private-text"),
      /event_detail_allowed/,
    );
    await ingest("cccccccc-cccc-4ccc-8ccc-cccccccccccc", "note_created");
    await ingest("eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee", "note_exported", "pdf");

    await db.exec("reset role");
    const daily = (await db.query<{
      active_users: number;
      sessions: number;
      notes_created: number;
      notes_exported: number;
    }>(`select active_users::int, sessions::int, notes_created::int,
      notes_exported::int from analytics_private.daily_kpis
      where metric_date = current_date`)).rows[0];
    assert.deepEqual(daily, {
      active_users: 1,
      sessions: 1,
      notes_created: 1,
      notes_exported: 1,
    });
    const overview = (await db.query<{
      dau: number;
      mau: number;
      activated_accounts: number;
    }>(`select dau::int, mau::int, activated_accounts::int
      from analytics_private.launch_overview`)).rows[0];
    assert.deepEqual(overview, { dau: 1, mau: 1, activated_accounts: 1 });

    await db.exec(`update analytics_private.events
      set occurred_at = now() - interval '401 days' where event_id = '${event}'`);
    await db.exec("set role service_role");
    assert.equal(
      (await db.query<{ removed: number }>(
        "select public.analytics_prune()::int removed",
      )).rows[0].removed,
      1,
    );
  } finally {
    await db.close();
  }
});
