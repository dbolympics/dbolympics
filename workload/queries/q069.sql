SELECT
  status,
  request_type,
  COUNT(*) AS count_requests,
  COUNT(completed_at) AS count_with_completed_at,
  COUNT(*) - COUNT(completed_at) AS count_without_completed_at,
  SUM(CASE WHEN completed_at IS NULL AND due_at < TIMESTAMP '2025-12-31 00:00:00' THEN 1 ELSE 0 END) AS count_overdue_open,
  {{divide_decimal(100.0 * SUM(CASE WHEN due_at IS NULL THEN 1 ELSE 0 END), COUNT(*))}} AS pct_due_at_null,
  AVG(CASE WHEN due_at IS NOT NULL THEN {{divide_decimal({{seconds_between(received_at, due_at)}}, 86400.0)}} END) AS avg_sla_window_days,
  MIN(CASE WHEN completed_at IS NULL THEN received_at END) AS oldest_open_received_at
FROM data_subject_requests
WHERE received_at >= DATE '2023-01-01' AND received_at < DATE '2026-01-01'
GROUP BY status, request_type
ORDER BY status NULLS LAST, request_type NULLS LAST
