WITH payment_base AS (
  SELECT 
    p.id AS payment_id,
    p.tenant_id AS tenant_id,
    p.order_id AS order_id,
    p.currency_code AS currency_code,
    p.amount AS amount,
    p.amount_refunded AS amount_refunded,
    p.captured_at AS captured_at
  FROM payments p
  JOIN payment_methods pm ON pm.id = p.payment_method_id
  WHERE p.status IN ('captured', 'refunded', 'partially_refunded')
    AND p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
    AND pm.kind = 'bank_transfer'
),
payment_eur AS (
  SELECT
    pb.payment_id AS payment_id,
    pb.tenant_id AS tenant_id,
    pb.order_id AS order_id,
    pb.currency_code AS currency_code,
    pb.amount AS amount,
    pb.amount_refunded AS amount_refunded,
    pb.captured_at AS captured_at,
    CASE WHEN pb.currency_code = 'EUR' THEN pb.amount
         ELSE CAST({{divide_decimal(pb.amount, er.rate)}} AS NUMERIC(18,6)) END AS payment_amount_eur,
    CASE WHEN pb.currency_code = 'EUR' THEN pb.amount_refunded
         ELSE CAST({{divide_decimal(pb.amount_refunded, er.rate)}} AS NUMERIC(18,6)) END AS amount_refunded_eur
  FROM payment_base pb
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = pb.currency_code
    AND er.as_of = CAST(pb.captured_at AS date)
),
ledger_credit AS (
  SELECT
    le.payment_id AS payment_id,
    SUM(CASE WHEN le.currency_code = 'EUR' THEN le.amount
             ELSE CAST({{divide_decimal(le.amount, er.rate)}} AS NUMERIC(18,6)) END) AS ledger_credit_total_eur
  FROM ledger_entries le
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = le.currency_code
    AND er.as_of = CAST(le.occurred_at AS date)
  WHERE le.direction = 'credit'
    AND le.payment_id IN (SELECT payment_id FROM payment_base)
  GROUP BY le.payment_id
),
calc AS (
  SELECT
    pe.payment_id AS payment_id,
    pe.tenant_id AS tenant_id,
    pe.order_id AS order_id,
    pe.currency_code AS currency_code,
    pe.amount AS payment_amount,
    pe.amount_refunded AS amount_refunded,
    pe.captured_at AS captured_at,
    lc.ledger_credit_total_eur AS ledger_credit_total_eur,
    (pe.payment_amount_eur - pe.amount_refunded_eur) AS net_amount_eur,
    (pe.payment_amount_eur + pe.amount_refunded_eur) AS payment_plus_refund_eur,
    CASE WHEN ABS(lc.ledger_credit_total_eur - (pe.payment_amount_eur - pe.amount_refunded_eur))
              <= ABS(lc.ledger_credit_total_eur - (pe.payment_amount_eur + pe.amount_refunded_eur))
         THEN (pe.payment_amount_eur - pe.amount_refunded_eur)
         ELSE (pe.payment_amount_eur + pe.amount_refunded_eur)
    END AS nearest_expected_eur
  FROM payment_eur pe
  LEFT JOIN ledger_credit lc ON lc.payment_id = pe.payment_id
),
classified AS (
  SELECT
    c.*,
    (c.ledger_credit_total_eur - c.nearest_expected_eur) AS diff_eur,
    GREATEST(0.01 * ABS(c.nearest_expected_eur), 1) AS tolerance_eur
  FROM calc c
)
SELECT
  o.order_number AS order_number,
  t.name AS merchant_name,
  cl.captured_at AS payment_captured_at,
  cl.currency_code AS currency_code,
  cl.payment_amount AS payment_amount,
  cl.amount_refunded AS amount_refunded,
  cl.ledger_credit_total_eur AS ledger_credit_total_eur,
  cl.nearest_expected_eur AS nearest_expected_eur,
  cl.diff_eur AS diff_eur
FROM classified cl
JOIN tenants t ON t.id = cl.tenant_id
LEFT JOIN orders o ON o.id = cl.order_id
WHERE cl.ledger_credit_total_eur IS NOT NULL
  AND ABS(cl.diff_eur) > cl.tolerance_eur
ORDER BY diff_eur DESC NULLS FIRST, cl.payment_id NULLS LAST
