SELECT
  request_type,
  status,
  count(*) AS request_count,
  CAST(min(received_at) AS date) AS earliest_received_at,
  CAST(max(received_at) AS date) AS latest_received_at,
  {{percentile_cont_filter(0.5, {{divide_decimal({{seconds_between(received_at, completed_at)}}, 86400.0)}}, completed_at IS NOT NULL)}} AS median_days_to_close
FROM data_subject_requests
GROUP BY request_type, status
ORDER BY request_type NULLS LAST, status NULLS LAST
