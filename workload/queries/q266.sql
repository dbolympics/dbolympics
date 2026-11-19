WITH base AS (
  SELECT
    COALESCE(a.touch_point, '(none)') AS touch_point,
    a.order_id AS order_id,
    a.attributed_revenue AS attributed_revenue,
    a.currency_code AS currency_code,
    a.weight AS weight,
    a.occurred_at AS occurred_at
  FROM attributions a
  WHERE a.campaign_id IS NULL
    AND a.order_id IS NOT NULL
    AND a.occurred_at >= DATE '2025-01-01'
    AND a.occurred_at < DATE '2026-01-01'
),
converted AS (
  SELECT
    b.touch_point AS touch_point,
    b.order_id AS order_id,
    b.weight AS weight,
    CASE WHEN b.currency_code = 'EUR' THEN CAST(b.attributed_revenue AS NUMERIC(18,6))
         ELSE CAST({{divide_decimal(b.attributed_revenue, er.rate)}} AS NUMERIC(18,6)) END AS revenue_eur
  FROM base b
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = b.currency_code
    AND er.as_of = CAST(b.occurred_at AS date)
),
totals AS (
  SELECT COUNT(DISTINCT order_id) AS total_orders FROM base
)
SELECT
  c.touch_point AS touch_point,
  COUNT(DISTINCT c.order_id) AS distinct_orders_count,
  {{divide_decimal(COUNT(DISTINCT c.order_id) * 100.0, t.total_orders)}} AS share_of_no_campaign_orders_pct,
  SUM(c.revenue_eur) AS attributed_revenue_eur,
  AVG(c.weight) AS avg_weight
FROM converted c
CROSS JOIN totals t
GROUP BY c.touch_point, t.total_orders
ORDER BY distinct_orders_count DESC NULLS FIRST, touch_point ASC NULLS LAST
