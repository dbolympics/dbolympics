WITH qualifying_payments AS (
  SELECT
    p.id AS id,
    p.currency_code AS currency_code,
    p.amount AS amount,
    p.amount_refunded AS amount_refunded,
    p.captured_at AS captured_at
  FROM payments p
  WHERE p.status IN ('captured', 'refunded', 'partially_refunded')
    AND p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
),
payment_amounts_eur AS (
  SELECT
    qp.id AS id,
    CAST({{divide_decimal(qp.amount, er.rate)}} AS NUMERIC(18,6)) AS payment_amount_eur,
    CAST({{divide_decimal(qp.amount_refunded, er.rate)}} AS NUMERIC(18,6)) AS amount_refunded_eur
  FROM qualifying_payments qp
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = qp.currency_code
   AND er.as_of = CAST(qp.captured_at AS DATE)
),
ledger_entries_eur AS (
  SELECT
    le.payment_id AS payment_id,
    le.direction AS direction,
    CAST({{divide_decimal(le.amount, er.rate)}} AS NUMERIC(18,6)) AS amount_eur
  FROM ledger_entries le
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = le.currency_code
   AND er.as_of = CAST(le.occurred_at AS DATE)
  WHERE le.payment_id IN (SELECT id FROM qualifying_payments)
),
ledger_agg AS (
  SELECT
    payment_id,
    SUM(CASE WHEN direction = 'credit' THEN amount_eur ELSE 0 END) AS total_credit_eur,
    SUM(CASE WHEN direction = 'debit' THEN amount_eur ELSE 0 END) AS total_debit_eur,
    COUNT(*) AS entry_count
  FROM ledger_entries_eur
  GROUP BY payment_id
),
classified AS (
  SELECT
    pa.id AS id,
    pa.payment_amount_eur AS payment_amount_eur,
    pa.amount_refunded_eur AS amount_refunded_eur,
    COALESCE(la.total_credit_eur, 0) AS total_credit_eur,
    COALESCE(la.total_debit_eur, 0) AS total_debit_eur,
    COALESCE(la.entry_count, 0) AS entry_count,
    (pa.payment_amount_eur - pa.amount_refunded_eur) AS target_net,
    (pa.payment_amount_eur + pa.amount_refunded_eur) AS target_gross
  FROM payment_amounts_eur pa
  LEFT JOIN ledger_agg la ON la.payment_id = pa.id
),
categorized AS (
  SELECT
    id,
    payment_amount_eur,
    total_credit_eur,
    total_debit_eur,
    CASE
      WHEN entry_count = 0 THEN 'no ledger entries'
      WHEN ABS(total_credit_eur - target_net) <= GREATEST(0.01 * ABS(target_net), 1) THEN 'credit = net amount'
      WHEN ABS(total_credit_eur - target_gross) <= GREATEST(0.01 * ABS(target_gross), 1) THEN 'credit = payment + refund'
      ELSE 'other mismatch'
    END AS reconciliation_category
  FROM classified
)
SELECT
  reconciliation_category,
  COUNT(*) AS payment_count,
  {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER ())}} AS pct_of_payments,
  SUM(payment_amount_eur) AS total_payment_amount_eur,
  SUM(total_credit_eur) AS total_ledger_credit_eur,
  SUM(total_debit_eur) AS total_ledger_debit_eur
FROM categorized
GROUP BY reconciliation_category
ORDER BY payment_count DESC NULLS FIRST, reconciliation_category NULLS LAST
