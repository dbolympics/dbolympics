SELECT
  t0.name AS tenant_name,
  COALESCE(t1.total_sessions_2025, 0) AS total_sessions_2025,
  COALESCE(t2.direct_sessions_2025, 0) AS direct_sessions_2025,
  {{divide_decimal(COALESCE(t2.direct_sessions_2025, 0) * 100.0, NULLIF(COALESCE(t1.total_sessions_2025, 0), 0))}} AS direct_share_of_tenant_pct,
  {{divide_decimal(COALESCE(t2.direct_sessions_2025, 0) * 100.0, NULLIF(t3.platform_direct_sessions_2025, 0))}} AS pct_of_platform_direct_sessions
FROM tenants t0
LEFT JOIN (
  SELECT tenant_id, COUNT(*) AS total_sessions_2025
  FROM web_sessions
  WHERE started_at >= DATE '2025-01-01' AND started_at < DATE '2026-01-01'
  GROUP BY tenant_id
) t1 ON t1.tenant_id = t0.id
LEFT JOIN (
  SELECT tenant_id, COUNT(*) AS direct_sessions_2025
  FROM web_sessions
  WHERE started_at >= DATE '2025-01-01' AND started_at < DATE '2026-01-01'
    AND (utm_source IS NULL OR TRIM(utm_source) = '')
  GROUP BY tenant_id
) t2 ON t2.tenant_id = t0.id
CROSS JOIN (
  SELECT COUNT(*) AS platform_direct_sessions_2025
  FROM web_sessions
  WHERE started_at >= DATE '2025-01-01' AND started_at < DATE '2026-01-01'
    AND (utm_source IS NULL OR TRIM(utm_source) = '')
) t3
ORDER BY direct_sessions_2025 DESC NULLS FIRST, tenant_name ASC NULLS LAST, t0.id ASC NULLS LAST
{{fetch_first(15)}}
