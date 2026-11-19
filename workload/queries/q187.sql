SELECT
  kind,
  count(*) AS event_count,
  min(abs(quantity)) AS min_abs_qty,
  max(abs(quantity)) AS max_abs_qty,
  avg(cast(abs(quantity) as numeric(18,6))) AS avg_abs_qty,
  {{percentile_cont(0.5, abs(quantity))}} AS median_abs_qty,
  {{divide_decimal(100.0 * count(*) FILTER (WHERE abs(quantity) = 1), count(*))}} AS pct_abs_qty_eq_1,
  sum(abs(quantity)) AS total_abs_qty
FROM stock_movements
WHERE occurred_at >= timestamp '2025-01-01' AND occurred_at < timestamp '2026-01-01'
GROUP BY kind
ORDER BY kind NULLS LAST
