SELECT
  t0.kind AS kind,
  COALESCE(t1.payment_count, 0) AS payment_count,
  t2.avg_days_order_to_capture AS avg_days_order_to_capture,
  t3.pct_captured_within_7_days AS pct_captured_within_7_days,
  t4.pct_captured_within_14_days AS pct_captured_within_14_days
FROM (SELECT DISTINCT pm0.kind AS kind FROM payment_methods pm0) t0
LEFT JOIN (
  SELECT pm1.kind AS kind, COUNT(*) AS payment_count
  FROM payments p1
  JOIN payment_methods pm1 ON p1.payment_method_id = pm1.id
  JOIN orders o1 ON p1.order_id = o1.id
  WHERE p1.status IN ('captured','refunded','partially_refunded')
    AND p1.order_id IS NOT NULL
  GROUP BY pm1.kind
) t1 ON t1.kind = t0.kind
LEFT JOIN (
  SELECT pm2.kind AS kind,
         AVG({{seconds_between(o2.placed_at, p2.captured_at)}} / 86400.0) AS avg_days_order_to_capture
  FROM payments p2
  JOIN payment_methods pm2 ON p2.payment_method_id = pm2.id
  JOIN orders o2 ON p2.order_id = o2.id
  WHERE p2.status IN ('captured','refunded','partially_refunded')
    AND p2.order_id IS NOT NULL
    AND p2.captured_at IS NOT NULL
    AND o2.placed_at IS NOT NULL
  GROUP BY pm2.kind
) t2 ON t2.kind = t0.kind
LEFT JOIN (
  SELECT pm3.kind AS kind,
         100.0 * SUM(CASE WHEN p3.captured_at <= o3.placed_at + INTERVAL '7' DAY THEN 1 ELSE 0 END) / COUNT(*) AS pct_captured_within_7_days
  FROM payments p3
  JOIN payment_methods pm3 ON p3.payment_method_id = pm3.id
  JOIN orders o3 ON p3.order_id = o3.id
  WHERE p3.status IN ('captured','refunded','partially_refunded')
    AND p3.order_id IS NOT NULL
    AND p3.captured_at IS NOT NULL
    AND o3.placed_at IS NOT NULL
  GROUP BY pm3.kind
) t3 ON t3.kind = t0.kind
LEFT JOIN (
  SELECT pm4.kind AS kind,
         100.0 * SUM(CASE WHEN p4.captured_at <= o4.placed_at + INTERVAL '14' DAY THEN 1 ELSE 0 END) / COUNT(*) AS pct_captured_within_14_days
  FROM payments p4
  JOIN payment_methods pm4 ON p4.payment_method_id = pm4.id
  JOIN orders o4 ON p4.order_id = o4.id
  WHERE p4.status IN ('captured','refunded','partially_refunded')
    AND p4.order_id IS NOT NULL
    AND p4.captured_at IS NOT NULL
    AND o4.placed_at IS NOT NULL
  GROUP BY pm4.kind
) t4 ON t4.kind = t0.kind
WHERE COALESCE(t1.payment_count, 0) > 0
ORDER BY t2.avg_days_order_to_capture DESC NULLS LAST, t0.kind ASC NULLS LAST
