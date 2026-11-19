SELECT
  v.calendar_date AS date,
  v.label AS label,
  count(o.id) AS total_orders,
  sum(CAST({{divide_decimal(o.grand_total, COALESCE(er.rate, 1))}} AS NUMERIC(18,6))) AS total_revenue_eur
FROM (VALUES
    (date '2025-11-21', 'Prior Friday'),
    (date '2025-11-28', 'Black Friday 2025'),
    (date '2025-12-05', 'Following Friday'),
    (date '2024-11-29', 'Black Friday 2024')
  ) AS v(calendar_date, label)
LEFT JOIN orders o
  ON CAST(o.placed_at AS DATE) = v.calendar_date
LEFT JOIN exchange_rates er
  ON er.base_code = 'EUR'
  AND er.quote_code = o.currency_code
  AND er.as_of = v.calendar_date
  AND o.currency_code <> 'EUR'
GROUP BY v.calendar_date, v.label
ORDER BY v.calendar_date ASC NULLS LAST
