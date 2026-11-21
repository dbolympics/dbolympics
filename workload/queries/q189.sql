SELECT
  category AS outcome_category,
  count(*) AS reservation_count,
  {{divide_decimal(100.0 * count(*), sum(count(*)) OVER ())}} AS pct_of_total,
  sum(quantity) AS total_quantity_units,
  avg(quantity * 1.0) AS avg_quantity_per_reservation,
  avg(duration_days) AS avg_hold_duration_days
FROM (
  SELECT
    quantity,
    CASE
      WHEN released_at IS NOT NULL AND (expires_at IS NULL OR released_at <= expires_at) THEN 'released_on_time'
      WHEN released_at IS NOT NULL AND expires_at IS NOT NULL AND released_at > expires_at THEN 'released_late'
      WHEN released_at IS NULL AND expires_at IS NOT NULL AND expires_at < TIMESTAMP '2025-12-31 00:00:00' THEN 'stuck_past_expiry'
      ELSE 'still_open_active'
    END AS category,
    CASE
      WHEN released_at IS NOT NULL THEN {{divide_decimal({{seconds_between(created_at, released_at)}}, 86400.0)}}
      ELSE {{divide_decimal({{seconds_between(created_at, TIMESTAMP '2025-12-31 00:00:00')}}, 86400.0)}}
    END AS duration_days
  FROM stock_reservations
  WHERE created_at >= TIMESTAMP '2025-01-01 00:00:00'
    AND created_at < TIMESTAMP '2026-01-01 00:00:00'
) t
GROUP BY category
ORDER BY
  CASE category
    WHEN 'released_on_time' THEN 1
    WHEN 'released_late' THEN 2
    WHEN 'stuck_past_expiry' THEN 3
    WHEN 'still_open_active' THEN 4
  END NULLS LAST
