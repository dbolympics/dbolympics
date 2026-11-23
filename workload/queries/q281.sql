SELECT table_name, earliest_record_date, days_since_earliest_record, total_row_count,
       row_count_older_than_730_days,
       {{divide_decimal(100.0 * row_count_older_than_730_days, NULLIF(total_row_count, 0))}} AS pct_older_than_730_days
FROM (
  SELECT 'access_log' AS table_name,
         CAST(MIN(occurred_at) AS date) AS earliest_record_date,
         (DATE '2025-12-31' - CAST(MIN(occurred_at) AS date)) AS days_since_earliest_record,
         COUNT(*) AS total_row_count,
         SUM(CASE WHEN occurred_at < (DATE '2025-12-31' - INTERVAL '730 days') THEN 1 ELSE 0 END) AS row_count_older_than_730_days
  FROM access_log

  UNION ALL

  SELECT 'change_history' AS table_name,
         CAST(MIN(occurred_at) AS date),
         (DATE '2025-12-31' - CAST(MIN(occurred_at) AS date)),
         COUNT(*),
         SUM(CASE WHEN occurred_at < (DATE '2025-12-31' - INTERVAL '730 days') THEN 1 ELSE 0 END)
  FROM change_history

  UNION ALL

  SELECT 'compliance_events' AS table_name,
         CAST(MIN(occurred_at) AS date),
         (DATE '2025-12-31' - CAST(MIN(occurred_at) AS date)),
         COUNT(*),
         SUM(CASE WHEN occurred_at < (DATE '2025-12-31' - INTERVAL '730 days') THEN 1 ELSE 0 END)
  FROM compliance_events

  UNION ALL

  SELECT 'login_attempts' AS table_name,
         CAST(MIN(occurred_at) AS date),
         (DATE '2025-12-31' - CAST(MIN(occurred_at) AS date)),
         COUNT(*),
         SUM(CASE WHEN occurred_at < (DATE '2025-12-31' - INTERVAL '730 days') THEN 1 ELSE 0 END)
  FROM login_attempts

  UNION ALL

  SELECT 'data_subject_requests' AS table_name,
         CAST(MIN(received_at) AS date),
         (DATE '2025-12-31' - CAST(MIN(received_at) AS date)),
         COUNT(*),
         SUM(CASE WHEN received_at < (DATE '2025-12-31' - INTERVAL '730 days') THEN 1 ELSE 0 END)
  FROM data_subject_requests
) t
ORDER BY table_name NULLS LAST
