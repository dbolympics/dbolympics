WITH pay_2025 AS (
  SELECT
    p.id AS payment_id,
    p.tenant_id AS tenant_id,
    p.currency_code AS currency_code,
    p.amount AS amount,
    p.captured_at AS captured_at
  FROM payments p
  WHERE p.status IN ('captured', 'refunded', 'partially_refunded')
    AND p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
),
ledger_counts AS (
  SELECT payment_id, COUNT(*) AS entry_count
  FROM ledger_entries
  WHERE payment_id IS NOT NULL
  GROUP BY payment_id
),
pay_flagged AS (
  SELECT
    p.tenant_id AS tenant_id,
    p.payment_id AS payment_id,
    p.currency_code AS currency_code,
    p.amount AS amount,
    p.captured_at AS captured_at,
    CASE WHEN lc.entry_count IS NULL OR lc.entry_count = 0 THEN 1 ELSE 0 END AS no_ledger
  FROM pay_2025 p
  LEFT JOIN ledger_counts lc ON lc.payment_id = p.payment_id
),
pay_eur AS (
  SELECT
    pf.*,
    CASE
      WHEN pf.currency_code = 'EUR' THEN pf.amount
      ELSE CAST({{divide_decimal(pf.amount, er.rate)}} AS NUMERIC(18,6))
    END AS amount_eur
  FROM pay_flagged pf
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = pf.currency_code
    AND er.as_of = CAST(pf.captured_at AS DATE)
),
by_tenant AS (
  SELECT
    t.name AS merchant_name,
    COUNT(*) AS total_payments_2025,
    SUM(pe.no_ledger) AS payments_without_ledger_entries,
    {{divide_decimal(100.0 * SUM(pe.no_ledger), COUNT(*))}} AS pct_without_ledger_entries,
    SUM(CASE WHEN pe.no_ledger = 1 THEN pe.amount_eur ELSE 0 END) AS amount_at_risk_eur
  FROM pay_eur pe
  JOIN tenants t ON t.id = pe.tenant_id
  GROUP BY t.name
  HAVING SUM(pe.no_ledger) >= 1
)
SELECT
  merchant_name,
  total_payments_2025,
  payments_without_ledger_entries,
  pct_without_ledger_entries,
  amount_at_risk_eur,
  COUNT(*) OVER () AS tenants_with_gap_total
FROM by_tenant
ORDER BY amount_at_risk_eur DESC NULLS FIRST, merchant_name ASC NULLS LAST
{{fetch_first(30)}}
