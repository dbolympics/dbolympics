SELECT t.name AS tenant_name,
  COUNT(*) AS customers,
  {{divide_decimal(100.0 * SUM(CASE WHEN cust.before_cnt > 0 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_with_session_before,
  {{divide_decimal(100.0 * SUM(CASE WHEN cust.after_cnt > 0 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_with_session_after,
  AVG(CAST(cust.after_cnt AS NUMERIC(18,6))) AS avg_sessions_after_first_order_per_customer
FROM (
  SELECT fo.tenant_id AS tenant_id, fo.user_id AS user_id, fo.first_order_at AS first_order_at,
    (SELECT COUNT(*) FROM web_sessions ws WHERE ws.tenant_id = fo.tenant_id AND ws.user_id = fo.user_id AND ws.started_at <= fo.first_order_at) AS before_cnt,
    (SELECT COUNT(*) FROM web_sessions ws WHERE ws.tenant_id = fo.tenant_id AND ws.user_id = fo.user_id AND ws.started_at > fo.first_order_at) AS after_cnt
  FROM (
    SELECT tenant_id, user_id, MIN(placed_at) AS first_order_at
    FROM orders
    WHERE tenant_id IN (SELECT id FROM tenants WHERE name IN ('Brennquell Kaffee','Spice Route Box','Grind Collective','Honeycomb Larder'))
    GROUP BY tenant_id, user_id
  ) fo
) cust
JOIN tenants t ON t.id = cust.tenant_id
GROUP BY t.name
ORDER BY t.name NULLS LAST
