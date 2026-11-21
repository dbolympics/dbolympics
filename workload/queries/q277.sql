WITH failed_feb AS (
  SELECT email, occurred_at
  FROM login_attempts
  WHERE succeeded = false
    AND email IS NOT NULL
    AND occurred_at >= DATE '2025-02-01' AND occurred_at < DATE '2025-03-01'
),
cohort AS (
  SELECT email, COUNT(*) AS failed_cnt, MAX(occurred_at) AS last_failed_at
  FROM failed_feb
  GROUP BY email
  HAVING COUNT(*) >= 5
),
success_feb AS (
  SELECT email, occurred_at
  FROM login_attempts
  WHERE succeeded = true
    AND email IS NOT NULL
    AND occurred_at >= DATE '2025-02-01' AND occurred_at < DATE '2025-03-01'
),
cohort_outcome AS (
  SELECT c.email AS email, c.failed_cnt AS failed_cnt, c.last_failed_at AS last_failed_at,
         MIN(s.occurred_at) AS first_success_at
  FROM cohort c
  LEFT JOIN success_feb s
    ON s.email = c.email AND s.occurred_at > c.last_failed_at
  GROUP BY c.email, c.failed_cnt, c.last_failed_at
),
bucketed AS (
  SELECT
    email, failed_cnt,
    CASE
      WHEN first_success_at IS NULL THEN 'never_succeeded_in_month'
      WHEN first_success_at <= last_failed_at + INTERVAL '1 hour' THEN 'succeeded_within_1h'
      WHEN first_success_at <= last_failed_at + INTERVAL '24 hour' THEN 'succeeded_within_24h'
      ELSE 'succeeded_later_in_month'
    END AS outcome_bucket
  FROM cohort_outcome
)
SELECT
  b.outcome_bucket AS outcome_bucket,
  COUNT(*) AS email_count,
  {{divide_decimal(100.0 * COUNT(*), (SELECT COUNT(*) FROM cohort))}} AS pct_of_cohort,
  AVG(CAST(b.failed_cnt AS NUMERIC(18,6))) FILTER (WHERE b.outcome_bucket <> 'never_succeeded_in_month') AS avg_failed_attempts_before_success,
  COUNT(DISTINCT la.tenant_id) AS distinct_tenants_affected
FROM bucketed b
JOIN login_attempts la
  ON la.email = b.email
  AND la.occurred_at >= DATE '2025-02-01' AND la.occurred_at < DATE '2025-03-01'
GROUP BY b.outcome_bucket
ORDER BY CASE b.outcome_bucket
  WHEN 'succeeded_within_1h' THEN 1
  WHEN 'succeeded_within_24h' THEN 2
  WHEN 'succeeded_later_in_month' THEN 3
  WHEN 'never_succeeded_in_month' THEN 4
END NULLS LAST
