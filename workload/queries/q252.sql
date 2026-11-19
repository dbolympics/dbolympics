SELECT
  t.name AS merchant_name,
  COUNT(*) AS urgent_tickets_evaluated,
  {{divide_decimal(100.0 * SUM(CASE WHEN b.bucket = 1 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_within_8h,
  {{divide_decimal(100.0 * SUM(CASE WHEN b.bucket = 2 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_8h_24h,
  {{divide_decimal(100.0 * SUM(CASE WHEN b.bucket = 3 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_1d_3d,
  {{divide_decimal(100.0 * SUM(CASE WHEN b.bucket = 4 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_3d_7d,
  {{divide_decimal(100.0 * SUM(CASE WHEN b.bucket = 5 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_over_7d_or_unresolved
FROM (
  SELECT
    tk.id AS id,
    tk.tenant_id AS tenant_id,
    CASE
      WHEN tk.resolved_at IS NULL THEN 5
      WHEN {{divide_decimal({{seconds_between(tk.created_at, tk.resolved_at)}}, 3600.0)}} <= 8 THEN 1
      WHEN {{divide_decimal({{seconds_between(tk.created_at, tk.resolved_at)}}, 3600.0)}} <= 24 THEN 2
      WHEN {{divide_decimal({{seconds_between(tk.created_at, tk.resolved_at)}}, 3600.0)}} <= 72 THEN 3
      WHEN {{divide_decimal({{seconds_between(tk.created_at, tk.resolved_at)}}, 3600.0)}} <= 168 THEN 4
      ELSE 5
    END AS bucket
  FROM tickets tk
  JOIN sla_policies sp ON sp.id = tk.sla_policy_id
  WHERE tk.priority = 'urgent'
    AND tk.sla_policy_id IS NOT NULL
    AND tk.created_at >= timestamp '2025-01-01'
    AND tk.created_at < timestamp '2026-01-01'
    AND tk.tenant_id IN (
      SELECT id FROM tenants
      WHERE name IN ('Cragsley Outfitters', 'Marrowby & Vane', 'Studio Vrij', 'Grind Collective', 'Wiesgrund Wohnen')
    )
) b
JOIN tenants t ON t.id = b.tenant_id
GROUP BY t.name
ORDER BY t.name ASC NULLS LAST
