WITH fx AS (
  SELECT quote_code, as_of, rate
  FROM exchange_rates
  WHERE base_code = 'EUR'
),
payments_2025 AS (
  SELECT p.id AS id, p.payment_method_id AS payment_method_id, p.amount AS amount, p.amount_refunded AS amount_refunded, p.currency_code AS currency_code, p.captured_at AS captured_at
  FROM payments p
  WHERE p.status IN ('captured', 'refunded', 'partially_refunded')
    AND p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
),
ledger_agg AS (
  SELECT
    le.payment_id AS payment_id,
    SUM(
      CASE WHEN le.direction = 'credit'
        THEN le.amount * COALESCE(fx.rate, CASE WHEN le.currency_code = 'EUR' THEN 1 END)
        ELSE 0
      END
    ) AS credit_eur,
    COUNT(*) AS entry_count
  FROM ledger_entries le
  LEFT JOIN fx ON fx.quote_code = le.currency_code AND fx.as_of = CAST(le.occurred_at AS DATE)
  WHERE le.payment_id IS NOT NULL
  GROUP BY le.payment_id
),
calc AS (
  SELECT
    p.id AS id,
    COALESCE(pm.kind, 'unknown') AS payment_method_kind,
    p.amount * COALESCE(fx_p.rate, CASE WHEN p.currency_code = 'EUR' THEN 1 END) AS payment_amount_eur,
    p.amount_refunded * COALESCE(fx_p.rate, CASE WHEN p.currency_code = 'EUR' THEN 1 END) AS refunded_amount_eur,
    la.credit_eur AS credit_eur,
    la.entry_count AS entry_count
  FROM payments_2025 p
  LEFT JOIN payment_methods pm ON pm.id = p.payment_method_id
  LEFT JOIN fx fx_p ON fx_p.quote_code = p.currency_code AND fx_p.as_of = CAST(p.captured_at AS DATE)
  LEFT JOIN ledger_agg la ON la.payment_id = p.id
),
classified AS (
  SELECT
    id,
    payment_method_kind,
    CASE
      WHEN entry_count IS NULL OR entry_count = 0 THEN 'no_ledger_entries'
      WHEN ABS(credit_eur - (payment_amount_eur - refunded_amount_eur))
           <= GREATEST(1.0, 0.01 * ABS(payment_amount_eur - refunded_amount_eur))
        THEN 'credit_equals_net'
      WHEN ABS(credit_eur - (payment_amount_eur + refunded_amount_eur))
           <= GREATEST(1.0, 0.01 * ABS(payment_amount_eur + refunded_amount_eur))
        THEN 'credit_equals_payment_plus_refund'
      ELSE 'other_mismatch'
    END AS classification
  FROM calc
)
SELECT
  payment_method_kind,
  COUNT(*) AS total_payment_count_2025,
  SUM(CASE WHEN classification = 'credit_equals_net' THEN 1 ELSE 0 END) AS count_credit_equals_net,
  SUM(CASE WHEN classification = 'credit_equals_payment_plus_refund' THEN 1 ELSE 0 END) AS count_credit_equals_payment_plus_refund,
  SUM(CASE WHEN classification = 'other_mismatch' THEN 1 ELSE 0 END) AS count_other_mismatch,
  SUM(CASE WHEN classification = 'no_ledger_entries' THEN 1 ELSE 0 END) AS count_no_ledger_entries,
  {{divide_decimal(100.0 * SUM(CASE WHEN classification IN ('credit_equals_net', 'credit_equals_payment_plus_refund') THEN 1 ELSE 0 END), COUNT(*))}} AS pct_clean
FROM classified
GROUP BY payment_method_kind
ORDER BY total_payment_count_2025 DESC NULLS FIRST, payment_method_kind ASC NULLS LAST
