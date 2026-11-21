SELECT
  a.action AS action_type,
  COUNT(*) AS total_events,
  COUNT(*) FILTER (WHERE a.occurred_at >= TIMESTAMP '2025-10-05' AND a.occurred_at < TIMESTAMP '2026-01-01') AS events_last_90_days,
  COUNT(DISTINCT a.tenant_id) AS distinct_tenants,
  {{divide_decimal(100.0 * COUNT(DISTINCT a.tenant_id), t.tenant_count)}} AS pct_of_tenants,
  COUNT(DISTINCT a.actor_user_id) AS distinct_actor_users,
  MIN(a.occurred_at) AS earliest_occurred_at,
  MAX(a.occurred_at) AS most_recent_occurred_at
FROM audit_log a
CROSS JOIN (SELECT COUNT(*) AS tenant_count FROM tenants) t
WHERE a.occurred_at >= TIMESTAMP '2023-01-01' AND a.occurred_at < TIMESTAMP '2026-01-01'
GROUP BY a.action, t.tenant_count
ORDER BY total_events DESC NULLS FIRST, action_type ASC NULLS LAST
