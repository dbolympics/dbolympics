SELECT
  COALESCE(rl.limit_scope, 'no scope recorded') AS scope_category,
  COUNT(DISTINCT ak.id) AS distinct_key_count,
  {{divide_decimal(COUNT(DISTINCT ak.id) * 100.0, 76)}} AS share_pct,
  COUNT(DISTINCT ak.tenant_id) AS distinct_tenants
FROM (
  SELECT id, tenant_id
  FROM api_keys
  WHERE status = 'active'
    AND created_at < DATE '2022-01-05'
) ak
LEFT JOIN rate_limits rl ON rl.api_key_id = ak.id
GROUP BY COALESCE(rl.limit_scope, 'no scope recorded')
ORDER BY distinct_key_count DESC NULLS FIRST, scope_category ASC NULLS LAST
