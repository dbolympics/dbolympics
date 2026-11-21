SELECT
  carrier,
  COUNT(*) AS shipments_shipped,
  COUNT(delivered_at) AS shipments_delivered,
  AVG(CAST(CASE WHEN delivered_at IS NOT NULL THEN ({{date_diff_days(shipped_at, delivered_at)}}) END AS NUMERIC(18,6))) AS avg_transit_days,
  ({{percentile_cont_filter(0.5, {{date_diff_days(shipped_at, delivered_at)}}, delivered_at IS NOT NULL)}}) AS median_transit_days,
  {{divide_decimal(100.0 * SUM(CASE WHEN delivered_at IS NOT NULL AND ({{date_diff_days(shipped_at, delivered_at)}}) <= 3 THEN 1 ELSE 0 END), NULLIF(COUNT(delivered_at), 0))}} AS pct_within_3_days,
  {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER ())}} AS share_of_total_shipments_pct
FROM shipments
WHERE shipped_at >= DATE '2025-01-01' AND shipped_at < DATE '2026-01-01'
GROUP BY carrier
ORDER BY shipments_shipped DESC NULLS FIRST, carrier ASC NULLS LAST
