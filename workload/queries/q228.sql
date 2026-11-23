WITH payments_2025 AS (
  SELECT
    p.id AS id,
    p.captured_at AS captured_at,
    p.amount AS amount,
    p.currency_code AS currency_code
  FROM payments p
  WHERE p.status IN ('captured', 'refunded', 'partially_refunded')
    AND p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
),
ledger_counts AS (
  SELECT
    le.payment_id AS payment_id,
    COUNT(*) AS entry_count
  FROM ledger_entries le
  WHERE le.payment_id IS NOT NULL
  GROUP BY le.payment_id
),
payments_with_fx AS (
  SELECT
    p.id AS id,
    p.captured_at AS captured_at,
    CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6)) AS amount_eur,
    COALESCE(lc.entry_count, 0) AS entry_count
  FROM payments_2025 p
  LEFT JOIN ledger_counts lc ON lc.payment_id = p.id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.captured_at AS DATE)
),
payments_with_month AS (
  SELECT
    cd.month_label AS month_label,
    cd.month_start AS month_start,
    pf.amount_eur AS amount_eur,
    pf.entry_count AS entry_count
  FROM payments_with_fx pf
  JOIN calendar_days cd ON cd.calendar_date = CAST(pf.captured_at AS DATE)
),
monthly AS (
  SELECT
    month_label,
    month_start,
    COUNT(*) AS total_payments,
    SUM(CASE WHEN entry_count = 0 THEN 1 ELSE 0 END) AS payments_without_ledger_entries,
    SUM(CASE WHEN entry_count = 0 THEN amount_eur ELSE 0 END) AS amount_at_risk_eur
  FROM payments_with_month
  GROUP BY month_label, month_start
)
SELECT
  month_label AS month,
  total_payments,
  payments_without_ledger_entries,
  {{divide_decimal(100.0 * payments_without_ledger_entries, total_payments)}} AS pct_without_ledger_entries,
  amount_at_risk_eur AS amount_at_risk_eur
FROM monthly
ORDER BY month_start NULLS LAST, month_label NULLS LAST
