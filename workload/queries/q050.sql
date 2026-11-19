WITH attr AS (
  SELECT
    c.channel AS channel,
    a.order_id AS order_id,
    a.attributed_revenue AS attributed_revenue,
    CASE WHEN a.currency_code = 'EUR' THEN 1 ELSE er.rate END AS fx_rate
  FROM attributions a
  JOIN campaigns c ON c.id = a.campaign_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = a.currency_code
    AND er.as_of = CAST(a.occurred_at AS date)
  WHERE a.occurred_at >= TIMESTAMP '2025-01-01'
    AND a.occurred_at < TIMESTAMP '2026-01-01'
    AND a.order_id IS NOT NULL
),
per_channel AS (
  SELECT
    channel,
    COUNT(DISTINCT order_id) AS attributed_orders,
    SUM(CAST({{divide_decimal(attributed_revenue, fx_rate)}} AS NUMERIC(18,6))) AS attributed_revenue_eur
  FROM attr
  GROUP BY channel
),
totals AS (
  SELECT SUM(attributed_revenue_eur) AS total_revenue_eur FROM per_channel
)
SELECT
  pc.channel AS channel,
  pc.attributed_orders AS attributed_orders,
  pc.attributed_revenue_eur AS attributed_revenue_eur,
  {{divide_decimal(pc.attributed_revenue_eur, t.total_revenue_eur)}} * 100 AS share_of_revenue_pct,
  {{divide_decimal(pc.attributed_revenue_eur, pc.attributed_orders)}} AS avg_order_value_eur
FROM per_channel pc
CROSS JOIN totals t
ORDER BY attributed_revenue_eur DESC NULLS FIRST, channel ASC NULLS LAST
