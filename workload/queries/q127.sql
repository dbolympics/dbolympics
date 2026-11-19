WITH t0 AS (
  SELECT
    t0a.id AS job_run_id,
    t0a.status AS status,
    t0a.queued_at AS queued_at,
    t0a.started_at AS started_at,
    t0a.finished_at AS finished_at,
    t0b.week_start AS week_start
  FROM job_runs t0a
  JOIN calendar_days t0b
    ON t0b.calendar_date = CAST(t0a.queued_at AS date)
  WHERE t0a.queued_at >= DATE '2025-10-01'
    AND t0a.queued_at < DATE '2026-01-01'
),
t1 AS (
  SELECT t1a.week_start AS week_start, COUNT(*) AS total_job_runs
  FROM t0 t1a
  GROUP BY t1a.week_start
),
t2 AS (
  SELECT t2a.week_start AS week_start, COUNT(*) AS failed_runs
  FROM t0 t2a
  WHERE t2a.status = 'failed'
  GROUP BY t2a.week_start
),
t3 AS (
  SELECT
    t3a.week_start AS week_start,
    AVG({{seconds_between(t3a.queued_at, t3a.started_at)}}) AS avg_queue_delay_seconds
  FROM t0 t3a
  WHERE t3a.started_at IS NOT NULL AND t3a.queued_at IS NOT NULL
  GROUP BY t3a.week_start
),
t4 AS (
  SELECT
    t4a.week_start AS week_start,
    {{percentile_cont(0.95, {{seconds_between(t4a.queued_at, t4a.started_at)}})}} AS p95_queue_delay_seconds
  FROM t0 t4a
  WHERE t4a.started_at IS NOT NULL AND t4a.queued_at IS NOT NULL
  GROUP BY t4a.week_start
),
t5 AS (
  SELECT
    t5a.week_start AS week_start,
    COUNT(*) AS delay_denom,
    COUNT(*) FILTER (WHERE {{seconds_between(t5a.queued_at, t5a.started_at)}} > 300) AS over_5min_count
  FROM t0 t5a
  WHERE t5a.started_at IS NOT NULL AND t5a.queued_at IS NOT NULL
  GROUP BY t5a.week_start
),
t6 AS (
  SELECT
    t6a.week_start AS week_start,
    AVG({{seconds_between(t6a.started_at, t6a.finished_at)}}) AS avg_duration_seconds
  FROM t0 t6a
  WHERE t6a.finished_at IS NOT NULL AND t6a.started_at IS NOT NULL
  GROUP BY t6a.week_start
),
t_weeks AS (
  SELECT DISTINCT t0.week_start AS week_start FROM t0
)
SELECT
  t_weeks.week_start AS week_start,
  COALESCE(t1.total_job_runs, 0) AS total_job_runs,
  COALESCE(t2.failed_runs, 0) AS failed_runs,
  {{divide_decimal(CAST(COALESCE(t2.failed_runs, 0) AS numeric(18,6)) * 100.0, NULLIF(t1.total_job_runs, 0))}} AS failure_rate_pct,
  COALESCE(t3.avg_queue_delay_seconds, 0) AS avg_queue_delay_seconds,
  COALESCE(t4.p95_queue_delay_seconds, 0) AS p95_queue_delay_seconds,
  {{divide_decimal(CAST(COALESCE(t5.over_5min_count, 0) AS numeric(18,6)) * 100.0, NULLIF(t5.delay_denom, 0))}} AS pct_jobs_queue_delay_over_5min,
  COALESCE(t6.avg_duration_seconds, 0) AS avg_duration_seconds
FROM t_weeks
LEFT JOIN t1 ON t1.week_start = t_weeks.week_start
LEFT JOIN t2 ON t2.week_start = t_weeks.week_start
LEFT JOIN t3 ON t3.week_start = t_weeks.week_start
LEFT JOIN t4 ON t4.week_start = t_weeks.week_start
LEFT JOIN t5 ON t5.week_start = t_weeks.week_start
LEFT JOIN t6 ON t6.week_start = t_weeks.week_start
ORDER BY t_weeks.week_start ASC NULLS LAST
