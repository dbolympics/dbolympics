WITH evaluable_tickets AS (
  SELECT
    t0.id AS ticket_id,
    t0.tenant_id AS tenant_id,
    t0.created_at AS created_at,
    t0.resolved_at AS resolved_at,
    t1.resolution_target_minutes AS resolution_target_minutes,
    CASE WHEN t0.resolved_at IS NULL THEN NULL
         ELSE {{divide_decimal({{seconds_between(t0.created_at, t0.resolved_at)}}, 3600.0)}}
    END AS actual_hours,
    CASE
      WHEN t0.resolved_at IS NULL THEN 1
      WHEN {{divide_decimal({{seconds_between(t0.created_at, t0.resolved_at)}}, 60.0)}} > t1.resolution_target_minutes THEN 1
      ELSE 0
    END AS is_miss
  FROM tickets t0
  JOIN sla_policies t1 ON t1.id = t0.sla_policy_id
  WHERE t0.priority = 'urgent'
    AND t0.sla_policy_id IS NOT NULL
    AND t0.created_at >= DATE '2025-01-01'
    AND t0.created_at < DATE '2026-01-01'
),
tenant_counts AS (
  SELECT tenant_id, COUNT(*) AS evaluated_count
  FROM evaluable_tickets
  GROUP BY tenant_id
  HAVING COUNT(*) >= 5
),
tenant_target AS (
  SELECT e.tenant_id AS tenant_id,
    {{divide_decimal(CAST(SUM(e.resolution_target_minutes) AS NUMERIC(18,6)), COUNT(*))}} / 60.0 AS weighted_target_hours,
    COUNT(DISTINCT e.resolution_target_minutes) AS distinct_target_count
  FROM evaluable_tickets e
  JOIN tenant_counts c ON c.tenant_id = e.tenant_id
  GROUP BY e.tenant_id
),
tenant_actual AS (
  SELECT e.tenant_id AS tenant_id,
    AVG(e.actual_hours) AS avg_actual_hours,
    {{percentile_cont(0.5, e.actual_hours)}} AS median_actual_hours
  FROM evaluable_tickets e
  JOIN tenant_counts c ON c.tenant_id = e.tenant_id
  WHERE e.resolved_at IS NOT NULL
  GROUP BY e.tenant_id
),
tenant_miss AS (
  SELECT e.tenant_id AS tenant_id,
    SUM(e.is_miss) AS miss_count
  FROM evaluable_tickets e
  JOIN tenant_counts c ON c.tenant_id = e.tenant_id
  GROUP BY e.tenant_id
)
SELECT
  t9.name AS merchant_name,
  t1.weighted_target_hours AS urgent_resolution_target_hours,
  t0.evaluated_count AS urgent_tickets_evaluated_2025,
  t2.median_actual_hours AS median_actual_resolution_hours,
  t2.avg_actual_hours AS avg_actual_resolution_hours,
  {{divide_decimal(100.0 * t3.miss_count, t0.evaluated_count)}} AS urgent_miss_rate_pct,
  CASE WHEN t1.distinct_target_count > 1 THEN 'Y' ELSE 'N' END AS multiple_urgent_sla_policies
FROM tenant_counts t0
JOIN tenant_target t1 ON t1.tenant_id = t0.tenant_id
LEFT JOIN tenant_actual t2 ON t2.tenant_id = t0.tenant_id
JOIN tenant_miss t3 ON t3.tenant_id = t0.tenant_id
JOIN tenants t9 ON t9.id = t0.tenant_id
ORDER BY urgent_miss_rate_pct DESC NULLS FIRST, merchant_name ASC NULLS LAST, t9.id ASC NULLS LAST
{{fetch_first(50)}}
