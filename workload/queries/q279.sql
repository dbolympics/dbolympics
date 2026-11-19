WITH failed_feb AS (
  SELECT tenant_id, email, occurred_at
  FROM login_attempts
  WHERE succeeded = false
    AND occurred_at >= DATE '2025-02-01'
    AND occurred_at < DATE '2025-03-01'
),
cohort AS (
  SELECT tenant_id, email, COUNT(*) AS failed_count, MAX(occurred_at) AS last_failed_at
  FROM failed_feb
  GROUP BY tenant_id, email
  HAVING COUNT(*) >= 5
),
success_after AS (
  SELECT
    c.tenant_id AS tenant_id,
    c.email AS email,
    c.failed_count AS failed_count,
    c.last_failed_at AS last_failed_at,
    MIN(la.occurred_at) AS success_at
  FROM cohort c
  LEFT JOIN login_attempts la
    ON la.tenant_id = c.tenant_id
    AND la.email = c.email
    AND la.succeeded = true
    AND la.occurred_at > c.last_failed_at
    AND la.occurred_at < DATE '2025-03-01'
  GROUP BY c.tenant_id, c.email, c.failed_count, c.last_failed_at
),
classified AS (
  SELECT
    tenant_id,
    email,
    failed_count,
    CASE
      WHEN success_at IS NULL THEN 'never_succeeded_in_month'
      WHEN success_at <= last_failed_at + INTERVAL '1 hour' THEN 'succeeded_within_1h'
      WHEN success_at <= last_failed_at + INTERVAL '24 hour' THEN 'succeeded_within_24h'
      ELSE 'succeeded_later_in_month'
    END AS outcome_bucket
  FROM success_after
),
cohort_size AS (
  SELECT COUNT(*) AS n FROM cohort
),
bucket_list AS (
  SELECT * FROM (VALUES
    ('succeeded_within_1h', 1),
    ('succeeded_within_24h', 2),
    ('succeeded_later_in_month', 3),
    ('never_succeeded_in_month', 4)
  ) AS b(outcome_bucket, sort_order)
)
SELECT
  b.outcome_bucket AS outcome_bucket,
  COUNT(c.tenant_id) AS pair_count,
  {{divide_decimal(100.0 * COUNT(c.tenant_id), NULLIF(cs.n, 0))}} AS pct_of_cohort,
  CASE
    WHEN b.outcome_bucket = 'never_succeeded_in_month' THEN NULL
    ELSE AVG(CAST(c.failed_count AS NUMERIC(18,6)))
  END AS avg_failed_attempts_before_success,
  COUNT(DISTINCT c.tenant_id) AS distinct_tenants_affected
FROM bucket_list b
LEFT JOIN classified c ON c.outcome_bucket = b.outcome_bucket
CROSS JOIN cohort_size cs
GROUP BY b.outcome_bucket, b.sort_order, cs.n
ORDER BY b.sort_order NULLS LAST
