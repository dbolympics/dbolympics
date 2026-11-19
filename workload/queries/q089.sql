WITH months AS (
  SELECT DISTINCT month_label, month_start
  FROM calendar_days
  WHERE calendar_date >= DATE '2023-01-01' AND calendar_date <= DATE '2025-12-31'
),
orders_filtered AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, o.currency_code AS currency_code, o.grand_total AS grand_total, o.placed_at AS placed_at,
         {{year_month(o.placed_at)}} AS month_label
  FROM orders o
  WHERE o.status <> 'cancelled' AND o.placed_at IS NOT NULL
    AND o.placed_at >= TIMESTAMP '2023-01-01' AND o.placed_at < TIMESTAMP '2026-01-01'
),
orders_eur AS (
  SELECT ofl.order_id AS order_id, ofl.month_label AS month_label,
         CAST({{divide_decimal(ofl.grand_total, er.rate)}} AS NUMERIC(18,6)) AS grand_total_eur
  FROM orders_filtered ofl
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = ofl.currency_code
    AND er.as_of = CAST(ofl.placed_at AS date)
),
payments_captured AS (
  SELECT p.id AS payment_id, p.order_id AS order_id, p.amount AS amount, p.currency_code AS currency_code, p.captured_at AS captured_at
  FROM payments p
  WHERE p.status = 'captured' AND p.order_id IS NOT NULL
),
payments_linked AS (
  SELECT pc.payment_id AS payment_id, pc.order_id AS order_id, ofl.month_label AS month_label,
         CAST({{divide_decimal(pc.amount, er.rate)}} AS NUMERIC(18,6)) AS amount_eur
  FROM payments_captured pc
  JOIN orders_filtered ofl ON ofl.order_id = pc.order_id
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = pc.currency_code
    AND er.as_of = CAST(COALESCE(pc.captured_at, ofl.placed_at) AS date)
),
order_agg AS (
  SELECT month_label,
         COUNT(*) AS orders_count,
         SUM(grand_total_eur) AS orders_grand_total_eur
  FROM orders_eur
  GROUP BY month_label
),
order_with_payment AS (
  SELECT month_label, COUNT(DISTINCT order_id) AS orders_with_captured_payment_count
  FROM payments_linked
  GROUP BY month_label
),
payment_agg AS (
  SELECT month_label, SUM(amount_eur) AS captured_payment_total_eur
  FROM payments_linked
  GROUP BY month_label
)
SELECT
  m.month_label AS month,
  COALESCE(oa.orders_count, 0) AS orders_count,
  COALESCE(oa.orders_grand_total_eur, 0) AS orders_grand_total_eur,
  COALESCE(owp.orders_with_captured_payment_count, 0) AS orders_with_captured_payment_count,
  COALESCE(pa.captured_payment_total_eur, 0) AS captured_payment_total_eur,
  COALESCE(oa.orders_count, 0) - COALESCE(owp.orders_with_captured_payment_count, 0) AS orders_without_captured_payment_count,
  COALESCE(oa.orders_grand_total_eur, 0) - COALESCE(pa.captured_payment_total_eur, 0) AS gap_eur,
  CASE WHEN COALESCE(oa.orders_grand_total_eur, 0) = 0 THEN NULL
       ELSE {{divide_decimal((COALESCE(oa.orders_grand_total_eur, 0) - COALESCE(pa.captured_payment_total_eur, 0)), oa.orders_grand_total_eur)}} * 100
  END AS gap_pct
FROM months m
LEFT JOIN order_agg oa ON oa.month_label = m.month_label
LEFT JOIN order_with_payment owp ON owp.month_label = m.month_label
LEFT JOIN payment_agg pa ON pa.month_label = m.month_label
ORDER BY m.month_label NULLS LAST
