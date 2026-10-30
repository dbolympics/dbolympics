SELECT
  {{year_month({{date_trunc('month', occurred_at)}})}} AS month,
  COUNT(*) AS rows_in_live_table,
  (DATE '2026-01-05' - CAST({{date_trunc('month', occurred_at)}} AS date)) AS days_old_as_of_report_date,
  CASE WHEN (DATE '2026-01-05' - CAST({{date_trunc('month', occurred_at)}} AS date)) > 730 THEN 'Y' ELSE 'N' END AS exceeds_730_day_retention
FROM audit_log
WHERE occurred_at >= DATE '2023-01-01' AND occurred_at < DATE '2026-01-01'
GROUP BY {{date_trunc('month', occurred_at)}}
ORDER BY {{date_trunc('month', occurred_at)}} ASC NULLS LAST
