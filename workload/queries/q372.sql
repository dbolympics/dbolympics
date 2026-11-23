select
  direction,
  count(*) as transaction_count,
  count(order_id) as transactions_with_order_id,
  {{divide_decimal(100.0 * count(order_id), nullif(count(*), 0))}} as pct_with_order_id,
  count(distinct order_id) as distinct_order_ids_referenced
from loyalty_transactions
where occurred_at >= date '2023-01-01'
  and occurred_at < date '2026-01-01'
group by direction
order by transaction_count desc NULLS FIRST, direction NULLS LAST
