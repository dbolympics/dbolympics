WITH target_pipelines AS (
  SELECT p.id AS pipeline_id, p.tenant_id AS tenant_id
  FROM pipelines p
  JOIN tenants t ON t.id = p.tenant_id
  WHERE t.name IN ('Ballycorran Industrial Supply','Castell Fasteners','Hanse Industriebedarf','Midland Safety Wear','Polder Packaging')
    AND p.name = 'New business'
),
months AS (
  SELECT DISTINCT month_start, month_label FROM calendar_days WHERE calendar_date BETWEEN DATE '2023-01-01' AND DATE '2025-12-31'
),
created AS (
  SELECT CAST({{date_trunc('month', o.created_at)}} AS date) AS month_start, count(*) AS cnt
  FROM opportunities o
  JOIN target_pipelines tp ON tp.pipeline_id = o.pipeline_id AND tp.tenant_id = o.tenant_id
  WHERE o.created_at >= DATE '2023-01-01' AND o.created_at < DATE '2026-01-01'
  GROUP BY 1
),
closed AS (
  SELECT CAST({{date_trunc('month', o.closed_at)}} AS date) AS month_start, count(*) AS cnt
  FROM opportunities o
  JOIN target_pipelines tp ON tp.pipeline_id = o.pipeline_id AND tp.tenant_id = o.tenant_id
  WHERE o.is_closed = true AND o.closed_at >= DATE '2023-01-01' AND o.closed_at < DATE '2026-01-01'
  GROUP BY 1
)
SELECT m.month_label AS month,
       coalesce(c.cnt,0) AS opportunities_created,
       coalesce(cl.cnt,0) AS opportunities_closed
FROM months m
LEFT JOIN created c ON c.month_start = m.month_start
LEFT JOIN closed cl ON cl.month_start = m.month_start
ORDER BY m.month_start NULLS LAST, m.month_label NULLS LAST
