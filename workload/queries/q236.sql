SELECT
  '2025-Q' || CAST(EXTRACT(QUARTER FROM ordered_at) AS INTEGER) AS quarter,
  COUNT(*) AS pos_ordered_total,
  COUNT(*) FILTER (WHERE ordered_at <= DATE '2025-11-01') AS pos_matured,
  COUNT(*) FILTER (WHERE ordered_at <= DATE '2025-11-01' AND received_at IS NOT NULL) AS pos_matured_received,
  {{divide_decimal(100.0 * COUNT(*) FILTER (
WHERE ordered_at <= DATE '2025-11-01'
  AND received_at IS NULL
  AND status IN ('submitted','partially_received')
), NULLIF(COUNT(*) FILTER (WHERE ordered_at <= DATE '2025-11-01'), 0))}} AS pct_matured_still_open,
  AVG(CAST(CASE
WHEN ordered_at <= DATE '2025-11-01' AND received_at IS NOT NULL
THEN {{date_diff_days(ordered_at, received_at)}}
END AS NUMERIC(18,6))) AS avg_actual_lead_days,
  {{divide_decimal(100.0 * COUNT(*) FILTER (
WHERE ordered_at <= DATE '2025-11-01'
  AND expected_at IS NOT NULL
  AND received_at IS NOT NULL
  AND received_at > expected_at
), NULLIF(COUNT(*) FILTER (
WHERE ordered_at <= DATE '2025-11-01'
  AND expected_at IS NOT NULL
  AND received_at IS NOT NULL
), 0))}} AS pct_received_late,
  AVG(CAST(CASE
WHEN ordered_at <= DATE '2025-11-01'
  AND expected_at IS NOT NULL
  AND received_at IS NOT NULL
  AND received_at > expected_at
THEN {{date_diff_days(expected_at, received_at)}}
END AS NUMERIC(18,6))) AS avg_days_late
FROM purchase_orders
WHERE ordered_at >= DATE '2025-01-01' AND ordered_at < DATE '2026-01-01'
GROUP BY EXTRACT(QUARTER FROM ordered_at)
ORDER BY quarter ASC NULLS LAST
