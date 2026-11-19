SELECT
  t.name AS merchant_name,
  t.industry AS industry,
  COUNT(*) FILTER (WHERE ws.started_at >= DATE '2023-10-01' AND ws.started_at < DATE '2024-01-01') AS sessions_q4_2023,
  COUNT(*) FILTER (WHERE ws.started_at >= DATE '2024-10-01' AND ws.started_at < DATE '2025-01-01') AS sessions_q4_2024,
  COUNT(*) FILTER (WHERE ws.started_at >= DATE '2025-10-01' AND ws.started_at < DATE '2026-01-01') AS sessions_q4_2025,
  CASE WHEN COUNT(*) FILTER (WHERE ws.started_at >= DATE '2024-10-01' AND ws.started_at < DATE '2025-01-01') = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * (COUNT(*) FILTER (WHERE ws.started_at >= DATE '2025-10-01' AND ws.started_at < DATE '2026-01-01') - COUNT(*) FILTER (WHERE ws.started_at >= DATE '2024-10-01' AND ws.started_at < DATE '2025-01-01')), COUNT(*) FILTER (WHERE ws.started_at >= DATE '2024-10-01' AND ws.started_at < DATE '2025-01-01'))}}
  END AS yoy_growth_pct_2024_to_2025,
  CASE WHEN COUNT(*) FILTER (WHERE ws.started_at >= DATE '2023-10-01' AND ws.started_at < DATE '2024-01-01') = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * (COUNT(*) FILTER (WHERE ws.started_at >= DATE '2024-10-01' AND ws.started_at < DATE '2025-01-01') - COUNT(*) FILTER (WHERE ws.started_at >= DATE '2023-10-01' AND ws.started_at < DATE '2024-01-01')), COUNT(*) FILTER (WHERE ws.started_at >= DATE '2023-10-01' AND ws.started_at < DATE '2024-01-01'))}}
  END AS yoy_growth_pct_2023_to_2024
FROM tenants t
LEFT JOIN web_sessions ws ON ws.tenant_id = t.id
WHERE t.name IN (
  'Castell Fasteners', 'OfficeHub Nordic', 'Deskline Supplies',
  'Ballycorran Industrial Supply', 'Midland Safety Wear', 'Polder Packaging',
  'Kontor24 Burobedarf'
)
GROUP BY t.id, t.name, t.industry
ORDER BY sessions_q4_2025 DESC NULLS FIRST, t.id ASC NULLS LAST
{{fetch_first(50)}}
