WITH q3_refunds AS (
  SELECT pr.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(pr.amount, er.rate)}} AS NUMERIC(18,6))) AS refund_amount_eur
  FROM payment_refunds pr
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = pr.currency_code
   AND er.as_of = CAST(pr.processed_at AS date)
  WHERE pr.status = 'succeeded'
    AND pr.processed_at >= DATE '2025-07-01'
    AND pr.processed_at < DATE '2025-10-01'
  GROUP BY pr.tenant_id
),
q3_payments AS (
  SELECT p.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) AS captured_amount_eur
  FROM payments p
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.captured_at AS date)
  WHERE p.status IN ('captured','partially_refunded','refunded')
    AND p.captured_at >= DATE '2025-07-01'
    AND p.captured_at < DATE '2025-10-01'
  GROUP BY p.tenant_id
),
h1_refunds AS (
  SELECT pr.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(pr.amount, er.rate)}} AS NUMERIC(18,6))) AS refund_amount_eur
  FROM payment_refunds pr
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = pr.currency_code
   AND er.as_of = CAST(pr.processed_at AS date)
  WHERE pr.status = 'succeeded'
    AND pr.processed_at >= DATE '2025-01-01'
    AND pr.processed_at < DATE '2025-07-01'
  GROUP BY pr.tenant_id
),
h1_payments AS (
  SELECT p.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) AS captured_amount_eur
  FROM payments p
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.captured_at AS date)
  WHERE p.status IN ('captured','partially_refunded','refunded')
    AND p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2025-07-01'
  GROUP BY p.tenant_id
),
q3_orders AS (
  SELECT tenant_id, COUNT(*) AS order_count
  FROM orders
  WHERE placed_at >= DATE '2025-07-01'
    AND placed_at < DATE '2025-10-01'
  GROUP BY tenant_id
)
SELECT
  t.name AS merchant_name,
  t.industry AS vertical,
  {{divide_decimal(100.0 * COALESCE(qr.refund_amount_eur,0), NULLIF(qp.captured_amount_eur,0))}} AS refund_rate_q3_pct,
  {{divide_decimal(100.0 * COALESCE(hr.refund_amount_eur,0), NULLIF(hp.captured_amount_eur,0))}} AS refund_rate_h1_baseline_pct,
  ({{divide_decimal(100.0 * COALESCE(qr.refund_amount_eur,0), NULLIF(qp.captured_amount_eur,0))}})
  - ({{divide_decimal(100.0 * COALESCE(hr.refund_amount_eur,0), NULLIF(hp.captured_amount_eur,0))}}) AS change_vs_baseline_pp,
  COALESCE(qr.refund_amount_eur,0) AS refund_amount_q3_eur,
  qo.order_count AS order_count_q3
FROM q3_orders qo
JOIN tenants t ON t.id = qo.tenant_id
LEFT JOIN q3_refunds qr ON qr.tenant_id = qo.tenant_id
LEFT JOIN q3_payments qp ON qp.tenant_id = qo.tenant_id
LEFT JOIN h1_refunds hr ON hr.tenant_id = qo.tenant_id
LEFT JOIN h1_payments hp ON hp.tenant_id = qo.tenant_id
WHERE qo.order_count >= 10
ORDER BY change_vs_baseline_pp DESC NULLS LAST, refund_amount_q3_eur DESC NULLS FIRST, merchant_name ASC NULLS LAST, t.id ASC NULLS LAST
