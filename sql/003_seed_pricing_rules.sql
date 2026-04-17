alter table if exists pricing_rules
    add column if not exists display_name varchar(128),
    add column if not exists description text;

insert into pricing_rules (
    name,
    display_name,
    description,
    billing_mode,
    price_per_gb,
    free_quota_bytes,
    subscription_price,
    included_traffic_bytes,
    subscription_period,
    traffic_reset_period,
    is_unlimited,
    status
)
select
    seed.name,
    seed.display_name,
    seed.description,
    seed.billing_mode,
    seed.price_per_gb::numeric,
    seed.included_traffic_bytes,
    seed.subscription_price::numeric,
    seed.included_traffic_bytes,
    seed.subscription_period,
    seed.traffic_reset_period,
    seed.is_unlimited,
    'active'
from (
    values
        ('default-traffic', '按量流量', '无到期时间，优先使用包年包月套餐。', 'traffic', '0.5000', 0::bigint, '0.0000', 'none', 'none', false),
        ('monthly-unlimited', '不限量包月', '不限量包月套餐，固定 5 元。未到期续费，将会延长到期时间。', 'subscription', '0.0000', 0::bigint, '5.0000', 'month', 'month', true),
        ('yearly-unlimited', '不限量包年', '不限量包年套餐，固定 40 元。未到期续费，将会延长到期时间。', 'subscription', '0.0000', 0::bigint, '40.0000', 'year', 'month', true)
) as seed(name, display_name, description, billing_mode, price_per_gb, included_traffic_bytes, subscription_price, subscription_period, traffic_reset_period, is_unlimited)
where not exists (
    select 1
    from pricing_rules pr
    where pr.name = seed.name
);
