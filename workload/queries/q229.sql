WITH quarters AS (
  SELECT * FROM (VALUES (1),(2),(3),(4)) AS v(q)
),
ledger_filtered AS (
  SELECT
    je.id AS id,
    je.direction AS direction,
    je.amount AS amount,
    je.currency_code AS currency_code,
    je.occurred_at AS occurred_at,
    la.account_type AS account_type,
    la.name AS account_name
  FROM ledger_entries je
  JOIN ledger_accounts la ON la.id = je.ledger_account_id
  WHERE je.occurred_at >= DATE '2025-01-01'
    AND je.occurred_at < DATE '2026-01-01'
    AND (
      la.account_type IN ('revenue','contra_revenue')
      OR la.name = 'VAT / sales tax payable'
    )
),
ledger_eur AS (
  SELECT
    lf.id AS id,
    lf.direction AS direction,
    lf.amount AS amount,
    lf.currency_code AS currency_code,
    lf.account_type AS account_type,
    lf.account_name AS account_name,
    CAST(EXTRACT(QUARTER FROM lf.occurred_at) AS int) AS q,
    CASE WHEN lf.currency_code = 'EUR' THEN CAST(lf.amount AS NUMERIC(18,6))
         ELSE CAST({{divide_decimal(lf.amount, er.rate)}} AS NUMERIC(18,6)) END AS amount_eur
  FROM ledger_filtered lf
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = lf.currency_code
   AND er.as_of = CAST(lf.occurred_at AS date)
),
ledger_quarterly AS (
  SELECT
    q,
    SUM(CASE
          WHEN direction = 'credit' AND (account_type = 'revenue' OR account_name = 'VAT / sales tax payable') THEN amount_eur
          WHEN direction = 'debit' AND (account_type = 'contra_revenue' OR account_name = 'VAT / sales tax payable') THEN -amount_eur
          ELSE 0
        END) AS ledger_gross_billed_eur
  FROM ledger_eur
  GROUP BY q
),
payments_filtered AS (
  SELECT
    p.id AS id,
    p.amount AS amount,
    p.amount_refunded AS amount_refunded,
    p.currency_code AS currency_code,
    p.captured_at AS captured_at,
    CAST(EXTRACT(QUARTER FROM p.captured_at) AS int) AS q
  FROM payments p
  WHERE p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
    AND p.status IN ('captured','refunded','partially_refunded')
),
payments_eur AS (
  SELECT
    pf.q AS q,
    CASE WHEN pf.currency_code = 'EUR' THEN (pf.amount - pf.amount_refunded)
         ELSE CAST({{divide_decimal((pf.amount - pf.amount_refunded), er.rate)}} AS NUMERIC(18,6)) END AS net_amount_eur
  FROM payments_filtered pf
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = pf.currency_code
   AND er.as_of = CAST(pf.captured_at AS date)
),
payments_quarterly AS (
  SELECT q, SUM(net_amount_eur) AS payments_net_amount_eur
  FROM payments_eur
  GROUP BY q
)
SELECT
  '2025-Q' || quarters.q AS quarter,
  COALESCE(lq.ledger_gross_billed_eur,0) AS ledger_gross_billed_eur,
  COALESCE(pq.payments_net_amount_eur,0) AS payments_net_amount_eur,
  COALESCE(lq.ledger_gross_billed_eur,0) - COALESCE(pq.payments_net_amount_eur,0) AS diff_eur,
  CASE WHEN COALESCE(pq.payments_net_amount_eur,0) = 0 THEN NULL
       ELSE {{divide_decimal((COALESCE(lq.ledger_gross_billed_eur,0) - COALESCE(pq.payments_net_amount_eur,0)), pq.payments_net_amount_eur)}} * 100
  END AS diff_pct
FROM quarters
LEFT JOIN ledger_quarterly lq ON lq.q = quarters.q
LEFT JOIN payments_quarterly pq ON pq.q = quarters.q
ORDER BY quarters.q NULLS LAST
