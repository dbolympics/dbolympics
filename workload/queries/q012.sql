SELECT
  q.year_num || '-Q' || q.quarter_num AS quarter,
  pa.failure_rate AS payment_failure_rate_pct,
  CASE WHEN pm.captured_eur > 0 THEN {{divide_decimal(rf.refund_eur, pm.captured_eur)}} * 100 ELSE NULL END AS refund_rate_pct,
  CASE WHEN ord.order_count > 0 THEN {{divide_decimal(tk.ticket_count * 100.0, ord.order_count)}} ELSE NULL END AS tickets_per_100_orders,
  cs.avg_csat AS avg_csat_score
FROM (
  SELECT DISTINCT year_num, quarter_num
  FROM calendar_days
  WHERE calendar_date BETWEEN DATE '2024-01-01' AND DATE '2025-12-31'
) q
LEFT JOIN (
  SELECT cd.year_num AS year_num, cd.quarter_num AS quarter_num,
    {{divide_decimal(SUM(CASE WHEN pa.status = 'failed' THEN 1 ELSE 0 END) * 100.0, COUNT(*))}} AS failure_rate
  FROM payment_attempts pa
  JOIN calendar_days cd ON cd.calendar_date = CAST(pa.attempted_at AS DATE)
  WHERE cd.calendar_date BETWEEN DATE '2024-01-01' AND DATE '2025-12-31'
  GROUP BY cd.year_num, cd.quarter_num
) pa ON pa.year_num = q.year_num AND pa.quarter_num = q.quarter_num
LEFT JOIN (
  SELECT cd.year_num AS year_num, cd.quarter_num AS quarter_num,
    SUM(CAST({{divide_decimal(pr.amount, er.rate)}} AS NUMERIC(18,6))) AS refund_eur
  FROM payment_refunds pr
  JOIN calendar_days cd ON cd.calendar_date = CAST(pr.processed_at AS DATE)
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = pr.currency_code AND er.as_of = cd.calendar_date
  WHERE pr.status = 'succeeded'
    AND cd.calendar_date BETWEEN DATE '2024-01-01' AND DATE '2025-12-31'
  GROUP BY cd.year_num, cd.quarter_num
) rf ON rf.year_num = q.year_num AND rf.quarter_num = q.quarter_num
LEFT JOIN (
  SELECT cd.year_num AS year_num, cd.quarter_num AS quarter_num,
    SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) AS captured_eur
  FROM payments p
  JOIN calendar_days cd ON cd.calendar_date = CAST(p.captured_at AS DATE)
  JOIN exchange_rates er ON er.base_code = 'EUR' AND er.quote_code = p.currency_code AND er.as_of = cd.calendar_date
  WHERE p.status IN ('captured', 'partially_refunded', 'refunded')
    AND cd.calendar_date BETWEEN DATE '2024-01-01' AND DATE '2025-12-31'
  GROUP BY cd.year_num, cd.quarter_num
) pm ON pm.year_num = q.year_num AND pm.quarter_num = q.quarter_num
LEFT JOIN (
  SELECT cd.year_num AS year_num, cd.quarter_num AS quarter_num, COUNT(*) AS ticket_count
  FROM tickets t
  JOIN calendar_days cd ON cd.calendar_date = CAST(t.created_at AS DATE)
  WHERE cd.calendar_date BETWEEN DATE '2024-01-01' AND DATE '2025-12-31'
  GROUP BY cd.year_num, cd.quarter_num
) tk ON tk.year_num = q.year_num AND tk.quarter_num = q.quarter_num
LEFT JOIN (
  SELECT cd.year_num AS year_num, cd.quarter_num AS quarter_num, COUNT(*) AS order_count
  FROM orders o
  JOIN calendar_days cd ON cd.calendar_date = CAST(o.placed_at AS DATE)
  WHERE o.status IN ('paid', 'partially_fulfilled', 'fulfilled', 'refunded')
    AND cd.calendar_date BETWEEN DATE '2024-01-01' AND DATE '2025-12-31'
  GROUP BY cd.year_num, cd.quarter_num
) ord ON ord.year_num = q.year_num AND ord.quarter_num = q.quarter_num
LEFT JOIN (
  SELECT cd.year_num AS year_num, cd.quarter_num AS quarter_num, AVG(CAST(c.score AS NUMERIC(18,6))) AS avg_csat
  FROM csat_responses c
  JOIN calendar_days cd ON cd.calendar_date = CAST(c.submitted_at AS DATE)
  WHERE cd.calendar_date BETWEEN DATE '2024-01-01' AND DATE '2025-12-31'
  GROUP BY cd.year_num, cd.quarter_num
) cs ON cs.year_num = q.year_num AND cs.quarter_num = q.quarter_num
ORDER BY q.year_num ASC NULLS LAST, q.quarter_num ASC NULLS LAST
