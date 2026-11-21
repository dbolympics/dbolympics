WITH scoped_tenants AS (
  SELECT id
  FROM tenants
  WHERE industry ILIKE '%industrial%'
     OR industry ILIKE '%office%'
     OR industry ILIKE '%wholesale%'
     OR industry ILIKE '%b2b%'
),
tenant_match_count AS (
  SELECT COUNT(*) AS cnt FROM scoped_tenants
),
base AS (
  SELECT
    i.id AS id,
    i.amount_due AS amount_due,
    i.currency_code AS currency_code,
    i.due_at AS due_at,
    bp.net_terms_days AS net_terms_days,
    CASE
      WHEN i.due_at IS NULL OR i.due_at >= TIMESTAMP '2025-12-31' THEN 'Not yet due'
      WHEN (DATE '2025-12-31' - CAST(i.due_at AS date)) BETWEEN 1 AND 30 THEN '1-30 days overdue'
      WHEN (DATE '2025-12-31' - CAST(i.due_at AS date)) BETWEEN 31 AND 60 THEN '31-60 days overdue'
      WHEN (DATE '2025-12-31' - CAST(i.due_at AS date)) BETWEEN 61 AND 90 THEN '61-90 days overdue'
      ELSE '90+ days overdue'
    END AS aging_bucket,
    CASE
      WHEN i.due_at IS NULL OR i.due_at >= TIMESTAMP '2025-12-31' THEN 0
      ELSE (DATE '2025-12-31' - CAST(i.due_at AS date))
    END AS days_past_due,
    er.rate AS eur_rate
  FROM invoices i
  JOIN scoped_tenants st ON st.id = i.tenant_id
  LEFT JOIN billing_profiles bp ON bp.id = i.billing_profile_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = i.currency_code
   AND er.as_of = DATE '2025-12-31'
  WHERE i.status IN ('open', 'past_due')
    AND i.amount_due > 0
),
bucketed AS (
  SELECT
    aging_bucket,
    COUNT(*) AS invoice_count,
    SUM(CAST({{divide_decimal(amount_due, eur_rate)}} AS NUMERIC(18,6))) AS amount_due_eur,
    AVG(CAST(days_past_due AS NUMERIC(18,6))) AS avg_days_past_due,
    AVG(CAST(net_terms_days AS NUMERIC(18,6))) AS avg_net_terms_days
  FROM base
  GROUP BY aging_bucket
),
totals AS (
  SELECT SUM(amount_due_eur) AS total_amount_due_eur FROM bucketed
)
SELECT
  b.aging_bucket AS aging_bucket,
  b.invoice_count AS invoice_count,
  b.amount_due_eur AS amount_due_eur,
  {{divide_decimal(b.amount_due_eur, NULLIF(t.total_amount_due_eur, 0))}} * 100 AS pct_of_total_amount_due,
  b.avg_days_past_due AS avg_days_past_due,
  b.avg_net_terms_days AS avg_net_terms_days
FROM bucketed b
CROSS JOIN totals t
WHERE (SELECT cnt FROM tenant_match_count) > 0

UNION ALL

SELECT
  di.industry AS aging_bucket,
  CAST(NULL AS bigint) AS invoice_count,
  CAST(NULL AS numeric(18,6)) AS amount_due_eur,
  CAST(NULL AS numeric(18,6)) AS pct_of_total_amount_due,
  CAST(NULL AS numeric(18,6)) AS avg_days_past_due,
  CAST(NULL AS numeric(18,6)) AS avg_net_terms_days
FROM (SELECT DISTINCT industry FROM tenants) di
WHERE (SELECT cnt FROM tenant_match_count) = 0

ORDER BY amount_due_eur DESC NULLS LAST, aging_bucket NULLS LAST
