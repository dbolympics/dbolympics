WITH job_week AS (
  SELECT
    cd.week_start AS week_start,
    COUNT(*) AS total_job_runs,
    SUM(CASE WHEN jr.status = 'failed' THEN 1 ELSE 0 END) AS failed_job_runs
  FROM job_runs jr
  JOIN calendar_days cd ON cd.calendar_date = CAST(jr.queued_at AS date)
  WHERE jr.queued_at >= DATE '2025-11-01' AND jr.queued_at < DATE '2026-01-01'
  GROUP BY cd.week_start
),
health_week AS (
  SELECT
    cd.week_start AS week_start,
    COUNT(*) AS total_health_checks,
    SUM(CASE WHEN shc.is_healthy = false THEN 1 ELSE 0 END) AS unhealthy_health_checks
  FROM system_health_checks shc
  JOIN calendar_days cd ON cd.calendar_date = CAST(shc.checked_at AS date)
  WHERE shc.checked_at >= DATE '2025-11-01' AND shc.checked_at < DATE '2026-01-01'
  GROUP BY cd.week_start
)
SELECT
  jw.week_start AS week_start,
  jw.total_job_runs AS total_job_runs,
  jw.failed_job_runs AS failed_job_runs,
  {{divide_decimal(100.0 * jw.failed_job_runs, NULLIF(jw.total_job_runs, 0))}} AS job_failure_rate_pct,
  hw.total_health_checks AS total_health_checks,
  hw.unhealthy_health_checks AS unhealthy_health_checks,
  {{divide_decimal(100.0 * hw.unhealthy_health_checks, NULLIF(hw.total_health_checks, 0))}} AS health_check_unhealthy_rate_pct
FROM job_week jw
JOIN health_week hw ON hw.week_start = jw.week_start
ORDER BY jw.week_start ASC NULLS LAST
