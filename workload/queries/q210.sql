with latest_rates as (
  select quote_code, rate
  from (
    select quote_code, rate, row_number() over (partition by quote_code order by as_of desc NULLS FIRST, id desc NULLS FIRST) as rn
    from exchange_rates
    where base_code = 'EUR' and as_of <= DATE '2025-12-31'
  ) ranked
  where rn = 1
),
unpaid as (
  select i.tenant_id AS tenant_id,
    sum({{divide_decimal(i.amount_due, case when i.currency_code = 'EUR' then 1 else lr.rate end)}}) as unpaid_eur
  from invoices i
  left join latest_rates lr on lr.quote_code = i.currency_code
  where i.status in ('open','past_due')
  group by i.tenant_id
),
traffic as (
  select tenant_id,
    count(*) filter (where started_at >= TIMESTAMP '2025-07-01' and started_at < TIMESTAMP '2025-10-01') as q3_sessions,
    count(*) filter (where started_at >= TIMESTAMP '2025-10-01' and started_at < TIMESTAMP '2026-01-01') as q4_sessions
  from web_sessions
  group by tenant_id
),
payout_rates as (
  select p.id as payout_id, p.tenant_id AS tenant_id, p.paid_at AS paid_at,
    {{divide_decimal(p.fee_amount, case when p.currency_code = 'EUR' then 1 else er.rate end)}} as fee_eur
  from payouts p
  left join exchange_rates er
    on er.base_code = 'EUR' and er.quote_code = p.currency_code and er.as_of = CAST(p.paid_at AS DATE)
  where p.status = 'paid'
),
revenue as (
  select tenant_id,
    sum(fee_eur) filter (where paid_at >= TIMESTAMP '2025-07-01' and paid_at < TIMESTAMP '2025-10-01') as q3_fee,
    sum(fee_eur) filter (where paid_at >= TIMESTAMP '2025-10-01' and paid_at < TIMESTAMP '2026-01-01') as q4_fee
  from payout_rates
  group by tenant_id
),
last_order as (
  select tenant_id, max(placed_at) as last_placed_at
  from orders
  group by tenant_id
)
select
  t.name as merchant_name,
  t.industry as vertical,
  coalesce(u.unpaid_eur, 0) as unpaid_invoice_balance_eur,
  case when tr.q3_sessions is null or tr.q3_sessions = 0 then null
       else {{divide_decimal(100.0 * (tr.q4_sessions - tr.q3_sessions), tr.q3_sessions)}} end as traffic_change_pct_q4_vs_q3,
  case when r.q3_fee is null or r.q3_fee = 0 then null
       else 100.0 * (r.q4_fee - r.q3_fee) / r.q3_fee end as fee_revenue_change_pct_q4_vs_q3,
  (DATE '2026-01-05' - CAST(lo.last_placed_at AS DATE)) as days_since_last_order,
  t.status as tenant_status
from tenants t
left join unpaid u on u.tenant_id = t.id
left join traffic tr on tr.tenant_id = t.id
left join revenue r on r.tenant_id = t.id
left join last_order lo on lo.tenant_id = t.id
where t.deleted_at is null
order by unpaid_invoice_balance_eur desc nulls last, traffic_change_pct_q4_vs_q3 asc nulls last, merchant_name NULLS LAST, t.id NULLS LAST
{{fetch_first(50)}}
