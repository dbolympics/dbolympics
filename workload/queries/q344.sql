SELECT
  d.ref_date AS date,
  d.label AS label,
  COALESCE(w.orders_cnt, 0) AS orders_14_to_16_utc,
  COALESCE(w.revenue_eur, 0) AS revenue_eur_14_to_16_utc,
  COALESCE(f.total_orders, 0) AS total_orders_full_day,
  {{divide_decimal(COALESCE(w.orders_cnt, 0) * 100.0, NULLIF(f.total_orders, 0))}} AS pct_of_day_in_window
FROM (VALUES
  (DATE '2025-11-21', 'Prior Friday'),
  (DATE '2025-11-28', 'Black Friday 2025'),
  (DATE '2025-12-05', 'Following Friday'),
  (DATE '2024-11-29', 'Black Friday 2024')
) AS d(ref_date, label)
LEFT JOIN (
  SELECT
    CAST(o.placed_at AS date) AS d,
    COUNT(*) AS orders_cnt,
    SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS revenue_eur
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE CAST(o.placed_at AS date) IN (DATE '2025-11-21', DATE '2025-11-28', DATE '2025-12-05', DATE '2024-11-29')
    AND CAST(o.placed_at AS time) >= TIME '14:00:00'
    AND CAST(o.placed_at AS time) < TIME '16:00:00'
  GROUP BY CAST(o.placed_at AS date)
) AS w
  ON w.d = d.ref_date
LEFT JOIN (
  SELECT
    CAST(o.placed_at AS date) AS d,
    COUNT(*) AS total_orders
  FROM orders o
  WHERE CAST(o.placed_at AS date) IN (DATE '2025-11-21', DATE '2025-11-28', DATE '2025-12-05', DATE '2024-11-29')
  GROUP BY CAST(o.placed_at AS date)
) AS f
  ON f.d = d.ref_date
ORDER BY d.ref_date ASC NULLS LAST
