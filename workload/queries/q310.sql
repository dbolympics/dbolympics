WITH target_tenants AS (
  SELECT id, name
  FROM tenants
  WHERE name IN (
    'Ballycorran Industrial Supply',
    'Kontor24 Burobedarf',
    'OfficeHub Nordic',
    'Midland Safety Wear',
    'Castell Fasteners',
    'Hanse Industriebedarf',
    'Polder Packaging',
    'Deskline Supplies',
    'Papeterie Grossiste'
  )
),
rates AS (
  SELECT quote_code, rate
  FROM exchange_rates
  WHERE base_code = 'EUR' AND as_of = DATE '2025-12-31'
),
inv AS (
  SELECT
    i.id AS id,
    i.amount_due AS amount_due,
    i.currency_code AS currency_code,
    i.due_at AS due_at,
    CASE
      WHEN i.currency_code = 'EUR' THEN i.amount_due
      ELSE CAST({{divide_decimal(i.amount_due, r.rate)}} AS NUMERIC(18,6))
    END AS amount_due_eur,
    CASE
      WHEN i.due_at IS NULL OR i.due_at >= DATE '2025-12-31' THEN 'Not yet due'
      WHEN DATE '2025-12-31' - CAST(i.due_at AS date) BETWEEN 1 AND 30 THEN '1-30 days overdue'
      WHEN DATE '2025-12-31' - CAST(i.due_at AS date) BETWEEN 31 AND 60 THEN '31-60 days overdue'
      WHEN DATE '2025-12-31' - CAST(i.due_at AS date) BETWEEN 61 AND 90 THEN '61-90 days overdue'
      ELSE '90+ days overdue'
    END AS aging_bucket,
    CASE
      WHEN i.due_at IS NULL OR i.due_at >= DATE '2025-12-31' THEN 0
      ELSE DATE '2025-12-31' - CAST(i.due_at AS date)
    END AS days_past_due
  FROM invoices i
  JOIN target_tenants t ON t.id = i.tenant_id
  LEFT JOIN rates r ON r.quote_code = i.currency_code
  WHERE i.status IN ('open', 'past_due')
    AND i.amount_due > 0
),
agg AS (
  SELECT
    aging_bucket,
    COUNT(*) AS invoice_count,
    SUM(amount_due_eur) AS amount_due_eur,
    AVG(CAST(days_past_due AS NUMERIC(18,6))) AS avg_days_past_due
  FROM inv
  GROUP BY aging_bucket
)
SELECT
  aging_bucket,
  invoice_count,
  amount_due_eur AS amount_due_eur,
  {{divide_decimal(amount_due_eur, SUM(amount_due_eur) OVER ())}} * 100 AS pct_of_total_amount_due,
  avg_days_past_due AS avg_days_past_due
FROM agg
ORDER BY amount_due_eur DESC NULLS FIRST, aging_bucket ASC NULLS LAST
