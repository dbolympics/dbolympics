WITH filtered_tickets AS (
  SELECT tk.id AS id, t.name AS merchant_name,
    extract(year from tk.created_at) AS yr,
    extract(quarter from tk.created_at) AS qtr,
    tk.created_at AS created_at, tk.resolved_at AS resolved_at,
    EXISTS (SELECT 1 FROM sla_breaches sb WHERE sb.ticket_id = tk.id) AS has_breach
  FROM tickets tk
  JOIN tenants t ON tk.tenant_id = t.id
  WHERE t.name IN ('Cragsley Outfitters','Marrowby & Vane','Studio Vrij','Grind Collective')
    AND tk.created_at >= DATE '2025-01-01' AND tk.created_at < DATE '2026-01-01'
)
SELECT merchant_name,
  CAST(yr AS text) || '-Q' || CAST(qtr AS text) AS quarter,
  count(*) AS tickets_created,
  avg({{divide_decimal({{seconds_between(created_at, resolved_at)}}, 3600)}}) FILTER (WHERE resolved_at IS NOT NULL) AS avg_resolution_hours,
  {{percentile_cont_filter(0.5, {{divide_decimal({{seconds_between(created_at, resolved_at)}}, 3600)}}, resolved_at IS NOT NULL)}} AS median_resolution_hours,
  {{divide_decimal(100.0 * count(*) FILTER (WHERE has_breach), count(*))}} AS sla_breach_rate_pct
FROM filtered_tickets
GROUP BY merchant_name, yr, qtr
ORDER BY merchant_name NULLS LAST, yr NULLS LAST, qtr NULLS LAST
