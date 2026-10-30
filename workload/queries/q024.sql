with quarters as (
  select distinct quarter_start, year_num, quarter_num
  from calendar_days
  where year_num = 2025
),
payments_in_2025 as (
  select
    CAST({{date_trunc('quarter', p.captured_at)}} AS date) as quarter_start,
    CAST(p.amount_refunded / er.rate AS NUMERIC(18,6)) as amount_refunded_eur
  from payments p
  join exchange_rates er
    on er.base_code = 'EUR'
   and er.quote_code = p.currency_code
   and er.as_of = CAST(p.captured_at AS DATE)
  where p.captured_at >= date '2025-01-01'
    and p.captured_at < date '2026-01-01'
),
payments_by_quarter as (
  select quarter_start, sum(amount_refunded_eur) as amount_refunded_eur_from_payments
  from payments_in_2025
  group by quarter_start
),
returns_in_2025 as (
  select
    CAST({{date_trunc('quarter', r.refunded_at)}} AS date) as quarter_start,
    CAST(r.refund_total / er.rate AS NUMERIC(18,6)) as refund_total_eur
  from order_returns r
  join exchange_rates er
    on er.base_code = 'EUR'
   and er.quote_code = r.currency_code
   and er.as_of = CAST(r.refunded_at AS DATE)
  where r.status = 'refunded'
    and r.refunded_at >= date '2025-01-01'
    and r.refunded_at < date '2026-01-01'
),
returns_by_quarter as (
  select quarter_start, sum(refund_total_eur) as refund_total_eur_from_order_returns
  from returns_in_2025
  group by quarter_start
),
combined as (
  select
    q.quarter_start AS quarter_start,
    q.year_num AS year_num,
    q.quarter_num AS quarter_num,
    coalesce(p.amount_refunded_eur_from_payments, 0) as amount_refunded_eur_from_payments,
    coalesce(r.refund_total_eur_from_order_returns, 0) as refund_total_eur_from_order_returns
  from quarters q
  left join payments_by_quarter p on p.quarter_start = q.quarter_start
  left join returns_by_quarter r on r.quarter_start = q.quarter_start
)
select
  year_num || '-Q' || quarter_num as quarter,
  amount_refunded_eur_from_payments as amount_refunded_eur_from_payments,
  refund_total_eur_from_order_returns as refund_total_eur_from_order_returns,
  amount_refunded_eur_from_payments - refund_total_eur_from_order_returns as difference_eur,
  case when amount_refunded_eur_from_payments = 0 then null
  else (amount_refunded_eur_from_payments - refund_total_eur_from_order_returns) / amount_refunded_eur_from_payments * 100
  end as difference_pct_of_payments_figure
from combined
order by year_num NULLS LAST, quarter_num NULLS LAST, quarter_start NULLS LAST
