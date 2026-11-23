SELECT
  t.name AS merchant_name,
  COUNT(*) AS tickets_2025,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE tk.channel = 'email'), COUNT(*))}} AS pct_email,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE tk.channel = 'chat'), COUNT(*))}} AS pct_chat,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE tk.channel = 'phone'), COUNT(*))}} AS pct_phone,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE tk.channel = 'web'), COUNT(*))}} AS pct_web,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE tk.channel = 'social'), COUNT(*))}} AS pct_social,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE tk.channel = 'api'), COUNT(*))}} AS pct_api
FROM tickets tk
JOIN tenants t ON t.id = tk.tenant_id
WHERE tk.created_at >= DATE '2025-01-01' AND tk.created_at < DATE '2026-01-01'
GROUP BY t.id, t.name
HAVING COUNT(*) >= 20
ORDER BY tickets_2025 DESC NULLS FIRST, merchant_name ASC NULLS LAST, t.id ASC NULLS LAST
{{fetch_first(50)}}
