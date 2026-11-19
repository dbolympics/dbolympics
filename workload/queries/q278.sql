SELECT
  request_type,
  received_at,
  due_at,
  updated_at,
  {{divide_decimal({{seconds_between(received_at, updated_at)}}, 86400.0)}} AS days_received_to_updated_at,
  (updated_at <= due_at) AS within_due_at
FROM data_subject_requests
WHERE status = 'rejected'
  AND completed_at IS NULL
ORDER BY received_at ASC NULLS LAST, id ASC NULLS LAST
