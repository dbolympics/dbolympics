WITH months AS (
  SELECT DISTINCT t0.month_start AS month_start, t0.month_label AS month_label
  FROM calendar_days t0
  WHERE t0.month_start BETWEEN DATE '2023-01-01' AND DATE '2025-12-01'
)
SELECT
  m.month_label AS month,
  COALESCE(r.requests_received,0) AS requests_received,
  COALESCE(ot.completed_on_time,0) AS completed_on_time,
  COALESCE(lt.completed_late,0) AS completed_late,
  COALESCE(nd.still_open_not_due,0) AS still_open_not_due,
  COALESCE(od.still_open_overdue,0) AS still_open_overdue,
  avgc.avg_days_to_complete AS avg_days_to_complete,
  medc.median_days_to_complete AS median_days_to_complete,
  CASE WHEN (COALESCE(ot.completed_on_time,0)+COALESCE(lt.completed_late,0))=0 THEN NULL
ELSE 100.0*COALESCE(ot.completed_on_time,0)/(COALESCE(ot.completed_on_time,0)+COALESCE(lt.completed_late,0))
END AS pct_on_time
FROM months m
LEFT JOIN (
  SELECT CAST({{date_trunc('month', t1.received_at)}} AS date) AS month_start, COUNT(*) AS requests_received
  FROM data_subject_requests t1
  GROUP BY 1
) r ON r.month_start = m.month_start
LEFT JOIN (
  SELECT CAST({{date_trunc('month', t2.received_at)}} AS date) AS month_start, COUNT(*) AS completed_on_time
  FROM data_subject_requests t2
  WHERE t2.completed_at IS NOT NULL AND t2.completed_at <= t2.due_at
  GROUP BY 1
) ot ON ot.month_start = m.month_start
LEFT JOIN (
  SELECT CAST({{date_trunc('month', t3.received_at)}} AS date) AS month_start, COUNT(*) AS completed_late
  FROM data_subject_requests t3
  WHERE t3.completed_at IS NOT NULL AND (t3.completed_at > t3.due_at OR t3.due_at IS NULL)
  GROUP BY 1
) lt ON lt.month_start = m.month_start
LEFT JOIN (
  SELECT CAST({{date_trunc('month', t4.received_at)}} AS date) AS month_start, COUNT(*) AS still_open_not_due
  FROM data_subject_requests t4
  WHERE t4.completed_at IS NULL AND (t4.due_at IS NULL OR t4.due_at >= DATE '2025-12-31')
  GROUP BY 1
) nd ON nd.month_start = m.month_start
LEFT JOIN (
  SELECT CAST({{date_trunc('month', t5.received_at)}} AS date) AS month_start, COUNT(*) AS still_open_overdue
  FROM data_subject_requests t5
  WHERE t5.completed_at IS NULL AND t5.due_at < DATE '2025-12-31'
  GROUP BY 1
) od ON od.month_start = m.month_start
LEFT JOIN (
  SELECT CAST({{date_trunc('month', t6.received_at)}} AS date) AS month_start,
    AVG({{seconds_between(t6.received_at, t6.completed_at)}}/86400.0) AS avg_days_to_complete
  FROM data_subject_requests t6
  WHERE t6.completed_at IS NOT NULL
  GROUP BY 1
) avgc ON avgc.month_start = m.month_start
LEFT JOIN (
  SELECT month_start, {{percentile_cont(0.5, days)}} AS median_days_to_complete
  FROM (
    SELECT CAST({{date_trunc('month', t7.received_at)}} AS date) AS month_start,
      {{seconds_between(t7.received_at, t7.completed_at)}}/86400.0 AS days
    FROM data_subject_requests t7
    WHERE t7.completed_at IS NOT NULL
  ) sub
  GROUP BY month_start
) medc ON medc.month_start = m.month_start
ORDER BY m.month_start NULLS LAST, m.month_label NULLS LAST
