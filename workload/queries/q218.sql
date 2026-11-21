WITH payout_eur AS (
  SELECT p.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(p.gross_amount, er.rate)}} AS NUMERIC(18,6))) AS gross_eur,
         SUM(CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6))) AS fee_eur
  FROM payouts p
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = p.currency_code AND er.as_of = CAST(p.paid_at AS date)
  WHERE p.paid_at >= DATE '2025-01-01' AND p.paid_at < DATE '2026-01-01'
  GROUP BY p.tenant_id
),
returns_eur AS (
  SELECT r.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(r.refund_total, er.rate)}} AS NUMERIC(18,6))) AS refund_eur
  FROM order_returns r
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = r.currency_code AND er.as_of = CAST(r.requested_at AS date)
  WHERE r.requested_at >= DATE '2025-01-01' AND r.requested_at < DATE '2026-01-01'
  GROUP BY r.tenant_id
),
shipping_eur AS (
  SELECT s.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(s.shipping_cost, er.rate)}} AS NUMERIC(18,6))) AS shipping_eur
  FROM shipments s
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = s.currency_code AND er.as_of = CAST(s.shipped_at AS date)
  WHERE s.shipped_at >= DATE '2025-01-01' AND s.shipped_at < DATE '2026-01-01' AND s.shipping_cost IS NOT NULL
  GROUP BY s.tenant_id
),
orders_cnt AS (
  SELECT tenant_id, COUNT(*) AS orders_2025
  FROM orders
  WHERE placed_at >= DATE '2025-01-01' AND placed_at < DATE '2026-01-01'
  GROUP BY tenant_id
),
tickets_cnt AS (
  SELECT tenant_id, COUNT(*) AS tickets_2025
  FROM tickets
  WHERE created_at >= DATE '2025-01-01' AND created_at < DATE '2026-01-01'
  GROUP BY tenant_id
)
SELECT t.name AS merchant_name,
       t.industry AS vertical,
       pe.gross_eur AS gross_payment_volume_eur,
       pe.fee_eur AS fee_revenue_eur,
       {{divide_decimal(100 * pe.fee_eur, NULLIF(pe.gross_eur, 0))}} AS take_rate_pct,
       {{divide_decimal(100 * COALESCE(re.refund_eur, 0), NULLIF(pe.gross_eur, 0))}} AS refund_rate_pct,
       {{divide_decimal(100 * COALESCE(se.shipping_eur, 0), NULLIF(pe.gross_eur, 0))}} AS shipping_cost_rate_pct,
       {{divide_decimal(100 * COALESCE(tc.tickets_2025, 0), CAST(NULLIF(oc.orders_2025, 0) AS numeric(18,6)))}} AS tickets_per_100_orders
FROM payout_eur pe
JOIN tenants t ON t.id = pe.tenant_id
LEFT JOIN returns_eur re ON re.tenant_id = pe.tenant_id
LEFT JOIN shipping_eur se ON se.tenant_id = pe.tenant_id
LEFT JOIN orders_cnt oc ON oc.tenant_id = pe.tenant_id
LEFT JOIN tickets_cnt tc ON tc.tenant_id = pe.tenant_id
ORDER BY pe.gross_eur DESC NULLS FIRST, t.name NULLS LAST, pe.tenant_id NULLS LAST
{{fetch_first(20)}}
