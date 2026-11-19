SELECT 
  tn.name AS merchant_name,
  u.urgent_created AS urgent_created,
  u.urgent_missing AS urgent_missing,
  {{divide_decimal(100.0 * u.urgent_missing, NULLIF(u.urgent_evaluable,0))}} AS urgent_miss_rate_pct,
  {{divide_decimal(100.0 * a.all_missing, NULLIF(a.all_evaluable,0))}} AS all_priority_miss_rate_pct
FROM (
  SELECT t.tenant_id AS tenant_id,
    COUNT(*) AS urgent_created,
    SUM(CASE WHEN t.sla_policy_id IS NOT NULL THEN 1 ELSE 0 END) AS urgent_evaluable,
    SUM(CASE WHEN t.sla_policy_id IS NOT NULL AND (t.resolved_at IS NULL OR {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 60)}} > sp.resolution_target_minutes) THEN 1 ELSE 0 END) AS urgent_missing
  FROM tickets t
  LEFT JOIN sla_policies sp ON sp.id = t.sla_policy_id
  WHERE t.priority = 'urgent'
    AND t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2026-01-01'
  GROUP BY t.tenant_id
) u
JOIN (
  SELECT t.tenant_id AS tenant_id,
    SUM(CASE WHEN t.sla_policy_id IS NOT NULL THEN 1 ELSE 0 END) AS all_evaluable,
    SUM(CASE WHEN t.sla_policy_id IS NOT NULL AND (t.resolved_at IS NULL OR {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 60)}} > sp.resolution_target_minutes) THEN 1 ELSE 0 END) AS all_missing
  FROM tickets t
  LEFT JOIN sla_policies sp ON sp.id = t.sla_policy_id
  WHERE t.created_at >= DATE '2025-01-01' AND t.created_at < DATE '2026-01-01'
  GROUP BY t.tenant_id
) a ON a.tenant_id = u.tenant_id
JOIN tenants tn ON tn.id = u.tenant_id
WHERE u.urgent_evaluable >= 5
ORDER BY urgent_miss_rate_pct DESC NULLS FIRST, merchant_name ASC NULLS LAST, u.tenant_id NULLS LAST
{{fetch_first(50)}}
