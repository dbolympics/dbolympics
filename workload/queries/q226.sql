WITH t0_payments_eur AS (
  SELECT
    p.id AS payment_id,
    p.payment_method_id AS payment_method_id,
    CAST({{divide_decimal(p.amount, er0.rate)}} AS NUMERIC(18,6)) AS payment_amount_eur,
    CAST({{divide_decimal(p.amount_refunded, er0.rate)}} AS NUMERIC(18,6)) AS amount_refunded_eur
  FROM payments p
  JOIN exchange_rates er0
    ON er0.base_code = 'EUR'
   AND er0.quote_code = p.currency_code
   AND er0.as_of = CAST(p.captured_at AS DATE)
  WHERE p.status IN ('captured','refunded','partially_refunded')
    AND p.captured_at >= DATE '2025-01-01'
    AND p.captured_at <  DATE '2026-01-01'
),

t1_ledger_credit AS (
  SELECT
    le.payment_id AS payment_id,
    SUM(CAST({{divide_decimal(le.amount, er1.rate)}} AS NUMERIC(18,6))) AS ledger_credit_total_eur
  FROM ledger_entries le
  JOIN exchange_rates er1
    ON er1.base_code = 'EUR'
   AND er1.quote_code = le.currency_code
   AND er1.as_of = CAST(le.occurred_at AS DATE)
  WHERE le.direction = 'credit'
    AND le.payment_id IS NOT NULL
  GROUP BY le.payment_id
),

t2_ledger_rowcount AS (
  SELECT
    le.payment_id AS payment_id,
    COUNT(*) AS ledger_row_count
  FROM ledger_entries le
  WHERE le.payment_id IS NOT NULL
  GROUP BY le.payment_id
),

t3_payment_classified AS (
  SELECT
    t0.payment_id AS payment_id,
    t0.payment_method_id AS payment_method_id,
    t0.payment_amount_eur AS payment_amount_eur,
    COALESCE(t1.ledger_credit_total_eur, 0) AS ledger_credit_total_eur,
    COALESCE(t2.ledger_row_count, 0) AS ledger_row_count,
    (t0.payment_amount_eur - t0.amount_refunded_eur) AS expected_net_eur,
    (t0.payment_amount_eur + t0.amount_refunded_eur) AS expected_gross_eur,
    ABS(COALESCE(t1.ledger_credit_total_eur,0) - (t0.payment_amount_eur - t0.amount_refunded_eur)) AS diff_net_eur,
    ABS(COALESCE(t1.ledger_credit_total_eur,0) - (t0.payment_amount_eur + t0.amount_refunded_eur)) AS diff_gross_eur
  FROM t0_payments_eur t0
  LEFT JOIN t1_ledger_credit t1 ON t1.payment_id = t0.payment_id
  LEFT JOIN t2_ledger_rowcount t2 ON t2.payment_id = t0.payment_id
),

t4_other_mismatch AS (
  SELECT
    t3.payment_id AS payment_id,
    t3.payment_method_id AS payment_method_id,
    t3.payment_amount_eur AS payment_amount_eur,
    CASE WHEN t3.diff_net_eur <= t3.diff_gross_eur THEN t3.diff_net_eur ELSE t3.diff_gross_eur END AS abs_diff_eur
  FROM t3_payment_classified t3
  WHERE t3.ledger_row_count >= 1
    AND t3.diff_net_eur   > GREATEST(0.01 * ABS(t3.expected_net_eur), 1)
    AND t3.diff_gross_eur > GREATEST(0.01 * ABS(t3.expected_gross_eur), 1)
),

t5_mismatch_with_kind AS (
  SELECT
    t4.payment_id AS payment_id,
    t4.payment_amount_eur AS payment_amount_eur,
    t4.abs_diff_eur AS abs_diff_eur,
    COALESCE(pm.kind, 'unknown') AS payment_method_kind
  FROM t4_other_mismatch t4
  LEFT JOIN payment_methods pm ON pm.id = t4.payment_method_id
),

t6_grand_totals AS (
  SELECT
    COUNT(*) AS grand_total_count,
    SUM(t5.payment_amount_eur) AS grand_total_amount_eur
  FROM t5_mismatch_with_kind t5
),

t7_count AS (
  SELECT t5.payment_method_kind AS payment_method_kind, COUNT(*) AS payment_count
  FROM t5_mismatch_with_kind t5
  GROUP BY t5.payment_method_kind
),

t8_amount AS (
  SELECT t5.payment_method_kind AS payment_method_kind, SUM(t5.payment_amount_eur) AS total_payment_amount_eur
  FROM t5_mismatch_with_kind t5
  GROUP BY t5.payment_method_kind
),

t9_avgdiff AS (
  SELECT t5.payment_method_kind AS payment_method_kind, AVG(t5.abs_diff_eur) AS avg_abs_diff_eur
  FROM t5_mismatch_with_kind t5
  GROUP BY t5.payment_method_kind
)

SELECT
  t7.payment_method_kind AS payment_method_kind,
  t7.payment_count AS payment_count,
  {{divide_decimal(100.0 * t7.payment_count, NULLIF(t6.grand_total_count, 0))}} AS pct_of_mismatch_count,
  COALESCE(t8.total_payment_amount_eur, 0) AS total_payment_amount_eur,
  {{divide_decimal(100.0 * COALESCE(t8.total_payment_amount_eur, 0), NULLIF(t6.grand_total_amount_eur, 0))}} AS pct_of_mismatch_amount,
  COALESCE(t9.avg_abs_diff_eur, 0) AS avg_abs_diff_eur
FROM t7_count t7
LEFT JOIN t8_amount t8 ON t8.payment_method_kind = t7.payment_method_kind
LEFT JOIN t9_avgdiff t9 ON t9.payment_method_kind = t7.payment_method_kind
CROSS JOIN t6_grand_totals t6
ORDER BY t7.payment_count DESC NULLS FIRST, t7.payment_method_kind ASC NULLS LAST
