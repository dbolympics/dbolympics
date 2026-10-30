SELECT
  COALESCE(om.month, rm.month) AS month,
  om.orders_placed AS orders_placed,
  rm.returns_requested AS returns_requested,
  CASE WHEN om.orders_placed > 0 THEN rm.returns_requested * 100.0 / om.orders_placed ELSE NULL END AS return_rate_pct,
  rm.returns_refunded AS returns_refunded,
  rm.avg_days_requested_to_refunded AS avg_days_requested_to_refunded,
  rm.median_days_requested_to_refunded AS median_days_requested_to_refunded,
  CASE WHEN rm.returns_requested > 0 THEN rm.returns_rejected * 100.0 / rm.returns_requested ELSE NULL END AS returns_rejected_pct
FROM
  (SELECT {{year_month({{date_trunc('month', placed_at)}})}} AS month, count(*) AS orders_placed
   FROM orders
   WHERE placed_at >= DATE '2023-01-01' AND placed_at < DATE '2026-01-01'
   GROUP BY 1) om
FULL OUTER JOIN
  (SELECT {{year_month({{date_trunc('month', requested_at)}})}} AS month,
          count(*) AS returns_requested,
          count(*) FILTER (WHERE status = 'refunded') AS returns_refunded,
          count(*) FILTER (WHERE status = 'rejected') AS returns_rejected,
          AVG({{seconds_between(requested_at, refunded_at)}}/86400) FILTER (WHERE status = 'refunded' AND refunded_at IS NOT NULL) AS avg_days_requested_to_refunded,
          {{percentile_cont_filter(0.5, {{seconds_between(requested_at, refunded_at)}}/86400, status = 'refunded' AND refunded_at IS NOT NULL)}} AS median_days_requested_to_refunded
   FROM order_returns
   WHERE requested_at >= DATE '2023-01-01' AND requested_at < DATE '2026-01-01'
   GROUP BY 1) rm
ON om.month = rm.month
ORDER BY COALESCE(om.month, rm.month) NULLS LAST
