WITH job_runs_filtered AS (
  SELECT
    jr.id AS id,
    jr.tenant_id AS tenant_id,
    jr.job_id AS job_id,
    jr.status AS status,
    jr.started_at AS started_at,
    jr.finished_at AS finished_at,
    j.handler AS handler
  FROM job_runs jr
  JOIN jobs j ON j.id = jr.job_id
  WHERE jr.queued_at >= DATE '2025-10-01'
    AND jr.queued_at < DATE '2026-01-01'
)
SELECT
  t0.handler AS handler,
  COALESCE(t1.total_runs, 0) AS total_runs,
  COALESCE(t2.failed_runs, 0) AS failed_runs,
  {{divide_decimal(100.0 * COALESCE(t2.failed_runs, 0), NULLIF(COALESCE(t1.total_runs, 0), 0))}} AS failure_rate_pct,
  COALESCE(t3.distinct_tenants_run, 0) AS distinct_tenants_run,
  COALESCE(t4.distinct_tenants_failed, 0) AS distinct_tenants_failed,
  t5.avg_duration_seconds_failed AS avg_duration_seconds_failed
FROM (SELECT DISTINCT handler FROM job_runs_filtered) t0
LEFT JOIN (
  SELECT handler, COUNT(*) AS total_runs
  FROM job_runs_filtered
  GROUP BY handler
) t1 ON t1.handler = t0.handler
LEFT JOIN (
  SELECT handler, COUNT(*) AS failed_runs
  FROM job_runs_filtered
  WHERE status = 'failed'
  GROUP BY handler
) t2 ON t2.handler = t0.handler
LEFT JOIN (
  SELECT handler, COUNT(DISTINCT tenant_id) AS distinct_tenants_run
  FROM job_runs_filtered
  GROUP BY handler
) t3 ON t3.handler = t0.handler
LEFT JOIN (
  SELECT handler, COUNT(DISTINCT tenant_id) AS distinct_tenants_failed
  FROM job_runs_filtered
  WHERE status = 'failed'
  GROUP BY handler
) t4 ON t4.handler = t0.handler
LEFT JOIN (
  SELECT handler, AVG({{seconds_between(started_at, finished_at)}}) AS avg_duration_seconds_failed
  FROM job_runs_filtered
  WHERE status = 'failed'
    AND started_at IS NOT NULL
    AND finished_at IS NOT NULL
  GROUP BY handler
) t5 ON t5.handler = t0.handler
ORDER BY failed_runs DESC NULLS FIRST, t0.handler ASC NULLS LAST
