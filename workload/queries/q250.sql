WITH q AS (
  SELECT 1 AS q_num, date '2025-01-01' AS q_start, date '2025-04-01' AS q_end
  UNION ALL SELECT 2, date '2025-04-01', date '2025-07-01'
  UNION ALL SELECT 3, date '2025-07-01', date '2025-10-01'
  UNION ALL SELECT 4, date '2025-10-01', date '2026-01-01'
),
m AS (
  SELECT id, name FROM tenants WHERE name IN ('Cragsley Outfitters','Marrowby & Vane','Studio Vrij','Grind Collective')
)
SELECT
  m.name AS merchant_name,
  '2025-Q' || q.q_num AS quarter,
  count(tk.id) AS urgent_tickets_evaluated,
  {{divide_decimal(100.0 * CAST(sum(
    case when tk.id is not null
           and (tk.resolved_at is null or tk.resolved_at > {{add_minutes(tk.created_at, sp.resolution_target_minutes)}})
         then 1 else 0 end
  ) AS numeric(18,6)), nullif(count(tk.id), 0))}} AS urgent_miss_rate_pct,
  avg(case when tk.resolved_at is not null then {{divide_decimal({{seconds_between(tk.created_at, tk.resolved_at)}}, 3600.0)}} end) AS avg_actual_resolution_hours,
  {{percentile_cont(0.5, case when tk.resolved_at is not null then {{divide_decimal({{seconds_between(tk.created_at, tk.resolved_at)}}, 3600.0)}} end)}} AS median_actual_resolution_hours
FROM m
CROSS JOIN q
LEFT JOIN tickets tk
  ON tk.tenant_id = m.id
  AND tk.priority = 'urgent'
  AND tk.sla_policy_id IS NOT NULL
  AND tk.created_at >= q.q_start AND tk.created_at < q.q_end
LEFT JOIN sla_policies sp ON sp.id = tk.sla_policy_id
GROUP BY m.name, q.q_num
ORDER BY m.name ASC NULLS LAST, q.q_num ASC NULLS LAST
