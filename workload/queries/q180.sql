WITH fx AS (
  SELECT quote_code, rate
  FROM exchange_rates
  WHERE base_code = 'EUR' AND as_of = DATE '2025-12-31'
),
scoped AS (
  SELECT
    o.id AS id,
    o.amount AS amount,
    o.currency_code AS currency_code,
    o.created_at AS created_at,
    (DATE '2025-12-31' - CAST(o.created_at AS DATE)) AS age_days
  FROM opportunities o
  JOIN pipelines p ON p.id = o.pipeline_id AND p.tenant_id = o.tenant_id
  JOIN tenants t ON t.id = o.tenant_id
  WHERE o.is_closed = false
    AND lower(p.name) = 'new business'
    AND (
      lower(t.industry) LIKE '%wholesale%'
      OR lower(t.industry) LIKE '%industrial%'
      OR lower(t.industry) LIKE '%office equipment%'
    )
),
converted AS (
  SELECT
    s.*,
    CASE WHEN s.currency_code = 'EUR' THEN CAST(s.amount AS NUMERIC(18,6))
         ELSE CAST({{divide_decimal(s.amount, fx.rate)}} AS NUMERIC(18,6)) END AS amount_eur
  FROM scoped s
  LEFT JOIN fx ON fx.quote_code = s.currency_code
),
bucketed AS (
  SELECT
    c.*,
    CASE
      WHEN age_days < 10 THEN '0-9 days'
      WHEN age_days < 20 THEN '10-19 days'
      WHEN age_days < 30 THEN '20-29 days'
      WHEN age_days < 45 THEN '30-44 days'
      WHEN age_days < 90 THEN '45-89 days'
      ELSE '90+ days'
    END AS age_bucket,
    CASE
      WHEN age_days < 10 THEN 0
      WHEN age_days < 20 THEN 10
      WHEN age_days < 30 THEN 20
      WHEN age_days < 45 THEN 30
      WHEN age_days < 90 THEN 45
      ELSE 90
    END AS bucket_order
  FROM converted c
)
SELECT
  age_bucket,
  COUNT(*) AS opportunities_count,
  {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER ())}} AS pct_of_open_pipeline,
  AVG(amount_eur) AS avg_amount_eur,
  SUM(amount_eur) AS total_amount_eur
FROM bucketed
GROUP BY age_bucket, bucket_order
ORDER BY bucket_order NULLS LAST
