SELECT order_group, orders_count, avg_order_value_eur, avg_items_per_order, return_rate_pct, cancelled_rate_pct
FROM (
  SELECT
    case when o.discount_total > 0 then 'discounted' else 'full price' end as order_group,
    count(*) as orders_count,
    avg({{divide_decimal(o.grand_total, case when o.currency_code = 'EUR' then 1 else er.rate end)}}) as avg_order_value_eur,
    avg(cast(coalesce(oi.item_qty,0) as numeric(18,6))) as avg_items_per_order,
    {{divide_decimal(100.0 * sum(case when ret.order_id is not null then 1 else 0 end), count(*))}} as return_rate_pct,
    {{divide_decimal(100.0 * sum(case when o.status = 'cancelled' then 1 else 0 end), count(*))}} as cancelled_rate_pct
  FROM orders o
  LEFT JOIN exchange_rates er on er.base_code = 'EUR' and er.quote_code = o.currency_code and er.as_of = CAST(o.placed_at AS date)
  LEFT JOIN (select order_id, sum(quantity) as item_qty from order_items group by order_id) oi on oi.order_id = o.id
  LEFT JOIN (select distinct order_id from order_returns) ret on ret.order_id = o.id
  WHERE o.placed_at >= date '2025-01-01' and o.placed_at < date '2026-01-01'
  GROUP BY case when o.discount_total > 0 then 'discounted' else 'full price' end
) t
ORDER BY (case when order_group = 'discounted' then 0 else 1 end) NULLS LAST
