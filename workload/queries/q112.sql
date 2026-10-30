WITH t0 AS (
  SELECT DISTINCT
    tcal.month_start AS month_start,
    tcal.month_label AS month_label
  FROM calendar_days tcal
  WHERE tcal.month_start >= DATE '2023-01-01'
    AND tcal.month_start <= DATE '2025-12-01'
),
t1 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    COUNT(*) AS requests_received
  FROM data_subject_requests tdsr
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
),
t2 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    COUNT(*) AS access_requests_received
  FROM data_subject_requests tdsr
  WHERE tdsr.request_type = 'access'
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
),
t3 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    COUNT(*) AS erasure_requests_received
  FROM data_subject_requests tdsr
  WHERE tdsr.request_type = 'erasure'
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
),
t4 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    COUNT(*) AS portability_requests_received
  FROM data_subject_requests tdsr
  WHERE tdsr.request_type = 'portability'
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
),
t5 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    COUNT(*) AS rectification_restriction_requests_received
  FROM data_subject_requests tdsr
  WHERE tdsr.request_type IN ('rectification', 'restriction')
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
),
t6 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    COUNT(*) AS completed_count
  FROM data_subject_requests tdsr
  WHERE tdsr.completed_at IS NOT NULL
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
),
t7 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    {{percentile_cont(0.5, {{seconds_between(tdsr.received_at, tdsr.completed_at)}} / 86400.0)}} AS median_days_to_close
  FROM data_subject_requests tdsr
  WHERE tdsr.completed_at IS NOT NULL
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
),
t8 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    COUNT(*) AS still_open_count
  FROM data_subject_requests tdsr
  WHERE tdsr.completed_at IS NULL
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
),
t9 AS (
  SELECT
    CAST({{date_trunc('month', tdsr.received_at)}} AS date) AS month_start,
    COUNT(*) AS overdue_count
  FROM data_subject_requests tdsr
  WHERE tdsr.completed_at IS NULL
    AND tdsr.due_at IS NOT NULL
    AND tdsr.due_at < TIMESTAMP '2026-01-05 00:00:00'
  GROUP BY CAST({{date_trunc('month', tdsr.received_at)}} AS date)
)
SELECT
  t0.month_label AS month,
  COALESCE(t1.requests_received, 0) AS requests_received,
  COALESCE(t2.access_requests_received, 0) AS access_requests_received,
  COALESCE(t3.erasure_requests_received, 0) AS erasure_requests_received,
  COALESCE(t4.portability_requests_received, 0) AS portability_requests_received,
  COALESCE(t5.rectification_restriction_requests_received, 0) AS rectification_restriction_requests_received,
  COALESCE(t6.completed_count, 0) AS completed_count,
  t7.median_days_to_close AS median_days_to_close,
  COALESCE(t8.still_open_count, 0) AS still_open_count,
  COALESCE(t9.overdue_count, 0) AS overdue_count
FROM t0
LEFT JOIN t1 ON t1.month_start = t0.month_start
LEFT JOIN t2 ON t2.month_start = t0.month_start
LEFT JOIN t3 ON t3.month_start = t0.month_start
LEFT JOIN t4 ON t4.month_start = t0.month_start
LEFT JOIN t5 ON t5.month_start = t0.month_start
LEFT JOIN t6 ON t6.month_start = t0.month_start
LEFT JOIN t7 ON t7.month_start = t0.month_start
LEFT JOIN t8 ON t8.month_start = t0.month_start
LEFT JOIN t9 ON t9.month_start = t0.month_start
ORDER BY t0.month_start ASC NULLS LAST, t0.month_label ASC NULLS LAST
