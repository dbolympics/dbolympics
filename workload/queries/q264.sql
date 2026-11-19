WITH order_amounts AS (
  SELECT o.id AS id, o.placed_at AS placed_at, o.currency_code AS currency_code, o.grand_total AS grand_total,
    CASE WHEN o.currency_code = 'EUR' THEN o.grand_total
         ELSE CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) END AS grand_total_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
),
attributed AS (
  SELECT DISTINCT order_id FROM attributions WHERE order_id IS NOT NULL
)
SELECT
  {{year_month(oa.placed_at)}} AS month,
  COUNT(*) AS orders_count,
  COUNT(*) FILTER (WHERE a.order_id IS NOT NULL) AS attributed_orders_count,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE a.order_id IS NOT NULL), COUNT(*))}} AS attribution_coverage_pct,
  SUM(oa.grand_total_eur) AS total_revenue_eur,
  SUM(oa.grand_total_eur) FILTER (WHERE a.order_id IS NOT NULL) AS attributed_revenue_eur
FROM order_amounts oa
LEFT JOIN attributed a ON a.order_id = oa.id
GROUP BY 1
ORDER BY 1 NULLS LAST
