SELECT reason,
  COUNT(*) AS event_count,
  {{divide_decimal(100.0 * COUNT(*), SUM(COUNT(*)) OVER ())}} AS pct_of_total_events,
  SUM(quantity_delta) AS net_quantity_delta,
  SUM(ABS(quantity_delta)) AS total_abs_quantity_delta,
  AVG(CAST(ABS(quantity_delta) AS NUMERIC(18,6))) AS avg_abs_quantity_delta
FROM stock_adjustments
WHERE created_at >= DATE '2025-01-01'
  AND created_at < DATE '2026-01-01'
  AND ABS(quantity_delta) = 1
GROUP BY reason
ORDER BY event_count DESC NULLS FIRST, reason ASC NULLS LAST
{{fetch_first(50)}}
