WITH ledger_q AS (
  SELECT
    CAST(EXTRACT(YEAR FROM le.occurred_at) AS int) AS yr,
    CAST(EXTRACT(QUARTER FROM le.occurred_at) AS int) AS qtr,
    SUM(CASE
          WHEN la.account_type = 'revenue' AND le.direction = 'credit'
          THEN (CASE WHEN le.currency_code = 'EUR' THEN CAST(le.amount AS NUMERIC(18,6)) ELSE CAST({{divide_decimal(le.amount, er.rate)}} AS NUMERIC(18,6)) END)
          ELSE 0
        END) AS ledger_revenue_credit_eur,
    SUM(CASE
          WHEN la.account_type = 'contra_revenue' AND le.direction = 'debit'
          THEN (CASE WHEN le.currency_code = 'EUR' THEN CAST(le.amount AS NUMERIC(18,6)) ELSE CAST({{divide_decimal(le.amount, er.rate)}} AS NUMERIC(18,6)) END)
          ELSE 0
        END) AS ledger_contra_revenue_debit_eur
  FROM ledger_entries le
  JOIN ledger_accounts la ON la.id = le.ledger_account_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = le.currency_code
   AND er.as_of = CAST(le.occurred_at AS DATE)
  WHERE le.occurred_at >= DATE '2025-01-01'
    AND le.occurred_at < DATE '2026-01-01'
    AND la.account_type IN ('revenue', 'contra_revenue')
  GROUP BY 1, 2
),
payments_q AS (
  SELECT
    CAST(EXTRACT(YEAR FROM p.captured_at) AS int) AS yr,
    CAST(EXTRACT(QUARTER FROM p.captured_at) AS int) AS qtr,
    SUM(CASE
          WHEN p.currency_code = 'EUR' THEN (p.amount - p.amount_refunded)
          ELSE CAST({{divide_decimal((p.amount - p.amount_refunded), er2.rate)}} AS NUMERIC(18,6))
        END) AS payments_net_amount_eur
  FROM payments p
  LEFT JOIN exchange_rates er2
    ON er2.base_code = 'EUR'
   AND er2.quote_code = p.currency_code
   AND er2.as_of = CAST(p.captured_at AS DATE)
  WHERE p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
    AND p.status IN ('captured', 'refunded', 'partially_refunded')
  GROUP BY 1, 2
)
SELECT
  l.yr || '-Q' || l.qtr AS quarter,
  l.ledger_revenue_credit_eur AS ledger_revenue_credit_eur,
  l.ledger_contra_revenue_debit_eur AS ledger_contra_revenue_debit_eur,
  l.ledger_revenue_credit_eur - l.ledger_contra_revenue_debit_eur AS ledger_net_revenue_eur,
  p.payments_net_amount_eur AS payments_net_amount_eur,
  (l.ledger_revenue_credit_eur - l.ledger_contra_revenue_debit_eur) - p.payments_net_amount_eur AS diff_eur,
  {{divide_decimal(((l.ledger_revenue_credit_eur - l.ledger_contra_revenue_debit_eur) - p.payments_net_amount_eur), NULLIF(p.payments_net_amount_eur, 0))}} * 100 AS diff_pct
FROM ledger_q l
JOIN payments_q p ON p.yr = l.yr AND p.qtr = l.qtr
ORDER BY l.yr NULLS LAST, l.qtr NULLS LAST
