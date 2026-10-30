WITH month_dim AS (
  SELECT DISTINCT cd.month_start AS month_start, cd.month_label AS month_label
  FROM calendar_days cd
  WHERE cd.calendar_date >= DATE '2023-01-01' AND cd.calendar_date <= DATE '2025-12-31'
),
t0 AS (
  SELECT CAST({{date_trunc('month', tk.created_at)}} AS date) AS month_start,
         COUNT(*) AS tickets_created
  FROM tickets tk
  WHERE tk.created_at >= TIMESTAMP '2023-01-01' AND tk.created_at < TIMESTAMP '2026-01-01'
  GROUP BY CAST({{date_trunc('month', tk.created_at)}} AS date)
),
t1 AS (
  SELECT CAST({{date_trunc('month', tk.created_at)}} AS date) AS month_start,
         COUNT(*) AS tickets_with_first_response,
         AVG({{seconds_between(tk.created_at, tk.first_response_at)}} / 3600.0) AS avg_first_response_hours,
         {{percentile_cont(0.5, {{seconds_between(tk.created_at, tk.first_response_at)}} / 3600.0)}} AS median_first_response_hours
  FROM tickets tk
  WHERE tk.created_at >= TIMESTAMP '2023-01-01' AND tk.created_at < TIMESTAMP '2026-01-01'
    AND tk.first_response_at IS NOT NULL
  GROUP BY CAST({{date_trunc('month', tk.created_at)}} AS date)
),
t2 AS (
  SELECT CAST({{date_trunc('month', tk.created_at)}} AS date) AS month_start,
         COUNT(*) AS tickets_resolved,
         AVG({{seconds_between(tk.created_at, tk.resolved_at)}} / 3600.0) AS avg_resolution_hours,
         {{percentile_cont(0.5, {{seconds_between(tk.created_at, tk.resolved_at)}} / 3600.0)}} AS median_resolution_hours
  FROM tickets tk
  WHERE tk.created_at >= TIMESTAMP '2023-01-01' AND tk.created_at < TIMESTAMP '2026-01-01'
    AND tk.resolved_at IS NOT NULL
  GROUP BY CAST({{date_trunc('month', tk.created_at)}} AS date)
),
t3 AS (
  SELECT CAST({{date_trunc('month', tk.created_at)}} AS date) AS month_start,
         COUNT(DISTINCT tk.id) AS tickets_with_breach
  FROM tickets tk
  JOIN sla_breaches sb ON sb.ticket_id = tk.id
  WHERE tk.created_at >= TIMESTAMP '2023-01-01' AND tk.created_at < TIMESTAMP '2026-01-01'
  GROUP BY CAST({{date_trunc('month', tk.created_at)}} AS date)
)
SELECT
  md.month_label AS month,
  COALESCE(t0.tickets_created, 0) AS tickets_created,
  COALESCE(t1.tickets_with_first_response, 0) AS tickets_with_first_response,
  t1.avg_first_response_hours AS avg_first_response_hours,
  t1.median_first_response_hours AS median_first_response_hours,
  COALESCE(t2.tickets_resolved, 0) AS tickets_resolved,
  t2.avg_resolution_hours AS avg_resolution_hours,
  t2.median_resolution_hours AS median_resolution_hours,
  100.0 * COALESCE(t3.tickets_with_breach, 0) / NULLIF(t0.tickets_created, 0) AS sla_breach_rate_pct
FROM month_dim md
LEFT JOIN t0 ON t0.month_start = md.month_start
LEFT JOIN t1 ON t1.month_start = md.month_start
LEFT JOIN t2 ON t2.month_start = md.month_start
LEFT JOIN t3 ON t3.month_start = md.month_start
ORDER BY md.month_start ASC NULLS LAST, md.month_label ASC NULLS LAST
