WITH order_agg AS (
  SELECT
    {{year_month(o.placed_at)}} AS month,
    COUNT(*) AS orders_count,
    SUM(CASE WHEN o.currency_code = 'EUR' THEN o.discount_total ELSE CAST({{divide_decimal(o.discount_total, er.rate)}} AS NUMERIC(18,6)) END) AS discount_eur,
    SUM(CASE WHEN o.currency_code = 'EUR' THEN o.subtotal ELSE CAST({{divide_decimal(o.subtotal, er.rate)}} AS NUMERIC(18,6)) END) AS gmv_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = o.currency_code
    AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
  GROUP BY 1
),
refund_agg AS (
  SELECT
    {{year_month(o.placed_at)}} AS month,
    SUM(CASE WHEN ret.currency_code = 'EUR' THEN ret.refund_total ELSE CAST({{divide_decimal(ret.refund_total, er.rate)}} AS NUMERIC(18,6)) END) AS refund_eur
  FROM order_returns ret
  JOIN orders o ON o.id = ret.order_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = ret.currency_code
    AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
  GROUP BY 1
),
months AS (
  SELECT DISTINCT month_label FROM calendar_days WHERE year_num = 2025
)
SELECT
  m.month_label AS month,
  COALESCE(oa.orders_count, 0) AS orders_count,
  COALESCE(oa.discount_eur, 0) AS discount_given_eur,
  COALESCE(ra.refund_eur, 0) AS refund_amount_eur,
  COALESCE(oa.gmv_eur, 0) AS gmv_eur,
  CASE WHEN COALESCE(oa.gmv_eur, 0) = 0 THEN NULL
  ELSE {{divide_decimal((COALESCE(oa.discount_eur, 0) + COALESCE(ra.refund_eur, 0)), oa.gmv_eur)}} * 100
  END AS net_leakage_pct
FROM months m
LEFT JOIN order_agg oa ON oa.month = m.month_label
LEFT JOIN refund_agg ra ON ra.month = m.month_label
ORDER BY m.month_label NULLS LAST
