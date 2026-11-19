SELECT
  o.month_label AS month,
  COUNT(*) AS orders_qualifying,
  AVG(CAST({{date_diff_days(o.placed_at, f.shipped_at)}} AS NUMERIC(18,6))) AS avg_processing_days,
  AVG(CAST({{date_diff_days(f.shipped_at, f.delivered_at)}} AS NUMERIC(18,6))) AS avg_transit_days,
  AVG(CAST({{date_diff_days(o.placed_at, f.delivered_at)}} AS NUMERIC(18,6))) AS avg_total_days,
  {{divide_decimal(100.0 * SUM(CASE WHEN ({{date_diff_days(o.placed_at, f.delivered_at)}}) <= 5 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_within_5_days_total
FROM (
  SELECT orders.id AS id, orders.placed_at AS placed_at, cd.month_label AS month_label
  FROM orders
  JOIN calendar_days cd ON cd.calendar_date = CAST(orders.placed_at AS date)
  WHERE orders.status = 'fulfilled'
    AND orders.placed_at >= TIMESTAMP '2025-01-01'
    AND orders.placed_at < TIMESTAMP '2026-01-01'
) o
JOIN fulfillments f ON f.order_id = o.id
WHERE f.shipped_at IS NOT NULL
  AND f.delivered_at IS NOT NULL
  AND (SELECT COUNT(*) FROM fulfillments f2 WHERE f2.order_id = o.id) = 1
GROUP BY o.month_label
ORDER BY o.month_label NULLS LAST
