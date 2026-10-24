-- Map yearly products to their respective tiers (starter499, pro1299, max2999)
-- and grant annual token allowances (12x monthly allocation: $14.40, $48.00, $120.00).
insert into billing_private.products (platform, product_id, plan, rank, allowance) values
 ('app_store', 'com.etonia.app.plan.499.yearly', 'starter499', 1, 14400000),
 ('app_store', 'com.etonia.app.plan.1299.yearly', 'pro1299', 2, 48000000),
 ('app_store', 'com.etonia.app.plan.2999.yearly', 'max2999', 3, 120000000),
 ('google_play', 'etonia_plan_499_yearly', 'starter499', 1, 14400000),
 ('google_play', 'etonia_plan_1299_yearly', 'pro1299', 2, 48000000),
 ('google_play', 'etonia_plan_2999_yearly', 'max2999', 3, 120000000)
on conflict (platform, product_id) do update set
  plan = excluded.plan,
  rank = excluded.rank,
  allowance = excluded.allowance;
