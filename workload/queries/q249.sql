SELECT t.name as merchant_name,
  concat('2025-Q', CAST(extract(quarter from tk.created_at) AS int)) as quarter,
  count(*) as tickets_created,
  count(distinct tk.assignee_agent_id) as distinct_agents,
  {{divide_decimal(CAST(count(*) AS numeric(18,6)), nullif(count(distinct tk.assignee_agent_id),0))}} as tickets_per_agent
FROM tickets tk
JOIN tenants t on t.id = tk.tenant_id
WHERE t.name in ('Cragsley Outfitters','Marrowby & Vane','Studio Vrij','Grind Collective')
  AND tk.created_at >= timestamp '2025-01-01' and tk.created_at < timestamp '2026-01-01'
GROUP BY t.name, extract(quarter from tk.created_at)
ORDER BY t.name NULLS LAST, extract(quarter from tk.created_at) NULLS LAST
