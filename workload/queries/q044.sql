SELECT t.name as merchant_name,
  ord.orders_placed AS orders_placed,
  ret.returns_requested AS returns_requested,
  {{divide_decimal(100.0 * ret.returns_requested, ord.orders_placed)}} as return_rate_pct,
  rf.avg_days AS avg_days,
  rf.median_days AS median_days,
  {{divide_decimal(100.0 * coalesce(rej.rejected_count,0), ret.returns_requested)}} as returns_rejected_pct
FROM tenants t
JOIN (SELECT tenant_id, count(*) as orders_placed FROM orders WHERE placed_at >= DATE '2025-01-01' AND placed_at < DATE '2026-01-01' GROUP BY tenant_id) ord ON ord.tenant_id = t.id
JOIN (SELECT tenant_id, count(*) as returns_requested FROM order_returns WHERE requested_at >= DATE '2025-01-01' AND requested_at < DATE '2026-01-01' GROUP BY tenant_id) ret ON ret.tenant_id = t.id
LEFT JOIN (SELECT tenant_id, avg(days) as avg_days, {{percentile_cont(0.5, days)}} as median_days
           FROM (SELECT tenant_id, {{divide_decimal({{seconds_between(requested_at, refunded_at)}}, 86400)}} as days FROM order_returns WHERE status='refunded' AND refunded_at IS NOT NULL AND requested_at >= DATE '2025-01-01' AND requested_at < DATE '2026-01-01') x
           GROUP BY tenant_id) rf ON rf.tenant_id = t.id
LEFT JOIN (SELECT tenant_id, count(*) as rejected_count FROM order_returns WHERE status='rejected' AND requested_at >= DATE '2025-01-01' AND requested_at < DATE '2026-01-01' GROUP BY tenant_id) rej ON rej.tenant_id = t.id
WHERE ret.returns_requested >= 20
ORDER BY ret.returns_requested DESC NULLS FIRST, t.name ASC NULLS LAST, t.id NULLS LAST
{{fetch_first(50)}}
