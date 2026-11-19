WITH discount_orders AS (
  select
    o.id as order_id,
    o.tenant_id AS tenant_id,
    o.user_id AS user_id,
    o.placed_at AS placed_at,
    od.amount as discount_amount,
    od.currency_code AS currency_code
  from order_discounts od
  join discounts d on d.id = od.discount_id and d.name = 'Subscription delivery (prepaid)'
  join orders o on o.id = od.order_id
  where o.placed_at >= timestamp '2025-01-01'
    and o.placed_at < timestamp '2026-01-01'
    and o.status <> 'cancelled'
),
orphan_flagged AS (
  select
    do_.*,
    case when exists (
      select 1 from subscriptions s
      where s.tenant_id = do_.tenant_id
        and s.user_id = do_.user_id
        and s.started_at <= do_.placed_at
        and (s.ended_at is null or s.ended_at >= do_.placed_at)
        and s.status in ('trialing','active','past_due')
    ) then false else true end as is_orphan
  from discount_orders do_
),
orphan_only AS (
  select * from orphan_flagged where is_orphan
),
customer_orphan AS (
  select tenant_id, user_id, max(placed_at) as last_order_at, count(*) as orphan_order_count
  from orphan_only
  group by tenant_id, user_id
),
subs_ranked AS (
  select
    s.tenant_id AS tenant_id, s.user_id AS user_id, s.status AS status, s.ended_at AS ended_at, s.started_at AS started_at,
    row_number() over (partition by s.tenant_id, s.user_id order by s.started_at desc NULLS FIRST, s.id desc NULLS FIRST) as rn
  from subscriptions s
),
most_recent_sub AS (
  select tenant_id, user_id, status, ended_at
  from subs_ranked
  where rn = 1
),
customer_classified AS (
  select
    co.tenant_id AS tenant_id,
    co.user_id AS user_id,
    co.orphan_order_count AS orphan_order_count,
    case
      when mrs.user_id is null then 'no_sub'
      when mrs.status = 'canceled' and mrs.ended_at is not null
        and mrs.ended_at >= co.last_order_at - interval '30 days'
        and mrs.ended_at <= co.last_order_at
      then 'lapsed'
      else 'other'
    end as classification
  from customer_orphan co
  left join most_recent_sub mrs
    on mrs.tenant_id = co.tenant_id and mrs.user_id = co.user_id
),
orphan_eur AS (
  select
    oo.tenant_id AS tenant_id,
    oo.order_id AS order_id,
    CAST({{divide_decimal(oo.discount_amount, er.rate)}} AS NUMERIC(18,6)) as discount_amount_eur
  from orphan_only oo
  join exchange_rates er
    on er.base_code = 'EUR'
    and er.quote_code = oo.currency_code
    and er.as_of = cast(oo.placed_at as date)
),
tenant_totals AS (
  select tenant_id, count(*) as total_discount_orders
  from discount_orders
  group by tenant_id
),
tenant_orphan AS (
  select
    tenant_id,
    count(*) as orphan_order_count,
    count(distinct user_id) as orphan_customers
  from orphan_only
  group by tenant_id
),
tenant_max_customer AS (
  select tenant_id, max(orphan_order_count) as max_orphan_per_customer
  from customer_orphan
  group by tenant_id
),
tenant_class AS (
  select
    tenant_id,
    count(*) as total_customers,
    sum(case when classification = 'lapsed' then 1 else 0 end) as lapsed_customers,
    sum(case when classification = 'no_sub' then 1 else 0 end) as no_sub_customers
  from customer_classified
  group by tenant_id
),
tenant_eur AS (
  select tenant_id, sum(discount_amount_eur) as total_discount_eur
  from orphan_eur
  group by tenant_id
)
select
  t.name as tenant_name,
  tor.orphan_order_count AS orphan_order_count,
  {{divide_decimal(100.0 * tor.orphan_order_count, tt.total_discount_orders)}} as orphan_pct_of_discount_orders,
  tor.orphan_customers as distinct_orphan_customers,
  tmc.max_orphan_per_customer AS max_orphan_per_customer,
  {{divide_decimal(100.0 * tc.lapsed_customers, nullif(tc.total_customers,0))}} as pct_lapsed_subscriber,
  {{divide_decimal(100.0 * tc.no_sub_customers, nullif(tc.total_customers,0))}} as pct_no_subscription_record,
  te.total_discount_eur as total_discount_amount_eur
from tenant_orphan tor
join tenants t on t.id = tor.tenant_id
join tenant_totals tt on tt.tenant_id = tor.tenant_id
join tenant_max_customer tmc on tmc.tenant_id = tor.tenant_id
join tenant_class tc on tc.tenant_id = tor.tenant_id
join tenant_eur te on te.tenant_id = tor.tenant_id
order by tor.orphan_order_count desc NULLS FIRST, t.name asc NULLS LAST, t.id NULLS LAST
