SELECT
  {{year_month(t0.month_start)}} AS month,
  t0.email_count AS emails_logged,
  (DATE '2026-01-05' - t0.month_start) AS days_old_as_of_2026_01_05,
  CASE WHEN (DATE '2026-01-05' - t0.month_start) > 730 THEN 'Y' ELSE 'N' END AS exceeds_730_day_retention
FROM (
  SELECT CAST({{date_trunc('month', t1.created_at)}} AS date) AS month_start, COUNT(*) AS email_count
  FROM email_log t1
  WHERE t1.created_at >= DATE '2023-01-01' AND t1.created_at < DATE '2026-01-01'
  GROUP BY {{date_trunc('month', t1.created_at)}}
) t0
ORDER BY t0.month_start ASC NULLS LAST
