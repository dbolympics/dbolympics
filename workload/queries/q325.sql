WITH policy AS (
  SELECT entity_table, MIN(retention_days) AS retention_days, MIN(action_on_expiry) AS action_on_expiry
  FROM retention_policies
  WHERE entity_table IN ('events','job_runs','page_views','system_health_checks')
  GROUP BY entity_table
),
events_stats AS (
  SELECT 'events' AS entity_table,
         COUNT(*) AS total_rows,
         (DATE '2026-01-05' - CAST(MIN(t0.occurred_at) AS DATE)) AS oldest_age_days,
         COUNT(*) FILTER (WHERE t0.occurred_at < (DATE '2026-01-05' - (SELECT retention_days FROM policy WHERE policy.entity_table = 'events'))) AS exceeding_rows
  FROM events t0
),
job_runs_stats AS (
  SELECT 'job_runs' AS entity_table,
         COUNT(*) AS total_rows,
         (DATE '2026-01-05' - CAST(MIN(t0.queued_at) AS DATE)) AS oldest_age_days,
         COUNT(*) FILTER (WHERE t0.queued_at < (DATE '2026-01-05' - (SELECT retention_days FROM policy WHERE policy.entity_table = 'job_runs'))) AS exceeding_rows
  FROM job_runs t0
),
page_views_stats AS (
  SELECT 'page_views' AS entity_table,
         COUNT(*) AS total_rows,
         (DATE '2026-01-05' - CAST(MIN(t0.viewed_at) AS DATE)) AS oldest_age_days,
         COUNT(*) FILTER (WHERE t0.viewed_at < (DATE '2026-01-05' - (SELECT retention_days FROM policy WHERE policy.entity_table = 'page_views'))) AS exceeding_rows
  FROM page_views t0
),
system_health_checks_stats AS (
  SELECT 'system_health_checks' AS entity_table,
         COUNT(*) AS total_rows,
         (DATE '2026-01-05' - CAST(MIN(t0.checked_at) AS DATE)) AS oldest_age_days,
         COUNT(*) FILTER (WHERE t0.checked_at < (DATE '2026-01-05' - (SELECT retention_days FROM policy WHERE policy.entity_table = 'system_health_checks'))) AS exceeding_rows
  FROM system_health_checks t0
),
all_stats AS (
  SELECT * FROM events_stats
  UNION ALL SELECT * FROM job_runs_stats
  UNION ALL SELECT * FROM page_views_stats
  UNION ALL SELECT * FROM system_health_checks_stats
)
SELECT
  a.entity_table AS entity_table,
  COALESCE(p.retention_days, 0) AS stated_retention_days,
  COALESCE(p.action_on_expiry, 'unknown') AS action_on_expiry,
  a.total_rows AS total_rows,
  a.oldest_age_days AS oldest_row_age_days,
  a.exceeding_rows AS rows_exceeding_retention,
  {{divide_decimal(100.0 * a.exceeding_rows, NULLIF(a.total_rows, 0))}} AS pct_exceeding_retention
FROM all_stats a
LEFT JOIN policy p ON p.entity_table = a.entity_table
ORDER BY pct_exceeding_retention DESC NULLS FIRST, a.entity_table ASC NULLS LAST
