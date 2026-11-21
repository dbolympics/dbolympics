WITH order_items_agg AS (
  SELECT order_id, SUM(quantity) AS item_qty
  FROM order_items
  GROUP BY order_id
),
order_returns_flag AS (
  SELECT DISTINCT order_id FROM order_returns
),
base AS (
  SELECT
    o.id AS order_id,
    t.industry AS industry,
    CASE WHEN o.discount_total > 0 THEN 'discounted' ELSE 'full price' END AS order_group,
    o.status AS status,
    o.grand_total AS grand_total,
    o.currency_code AS currency_code,
    o.placed_at AS placed_at,
    COALESCE(oi.item_qty, 0) AS item_qty,
    COALESCE(er.rate, CASE WHEN o.currency_code = 'EUR' THEN 1 END) AS eur_rate
  FROM orders o
  JOIN tenants t ON t.id = o.tenant_id
  LEFT JOIN order_items_agg oi ON oi.order_id = o.id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
)
SELECT
  b.industry AS industry,
  b.order_group AS order_group,
  COUNT(*) AS orders_count,
  AVG(CAST({{divide_decimal(b.grand_total, b.eur_rate)}} AS NUMERIC(18,6))) AS avg_order_value_eur,
  AVG(CAST(b.item_qty AS NUMERIC(18,6))) AS avg_items_per_order,
  {{divide_decimal(100.0 * SUM(CASE WHEN rf.order_id IS NOT NULL THEN 1 ELSE 0 END), COUNT(*))}} AS return_rate_pct,
  {{divide_decimal(100.0 * SUM(CASE WHEN b.status = 'cancelled' THEN 1 ELSE 0 END), COUNT(*))}} AS cancelled_rate_pct
FROM base b
LEFT JOIN order_returns_flag rf ON rf.order_id = b.order_id
GROUP BY b.industry, b.order_group
ORDER BY b.industry ASC NULLS LAST, b.order_group ASC NULLS LAST
