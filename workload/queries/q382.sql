WITH scoped_tenants AS (
  SELECT id, name FROM tenants
  WHERE name IN ('Ballycorran Industrial Supply','Castell Fasteners','Hanse Industriebedarf','Midland Safety Wear','Polder Packaging')
),
new_business_pipelines AS (
  SELECT p.id AS pipeline_id, p.tenant_id AS tenant_id
  FROM pipelines p
  JOIN scoped_tenants st ON st.id = p.tenant_id
  WHERE p.name = 'New business'
),
lost_opps AS (
  SELECT o.id AS opportunity_id, o.tenant_id AS tenant_id, o.created_at AS created_at, o.closed_at AS closed_at
  FROM opportunities o
  JOIN new_business_pipelines nbp ON nbp.pipeline_id = o.pipeline_id AND nbp.tenant_id = o.tenant_id
  WHERE o.is_closed = true AND o.is_won = false
),
total_lost AS (
  SELECT COUNT(*) AS total_lost_opps FROM lost_opps
),
activity_positions AS (
  SELECT
    a.id AS activity_id,
    lo.opportunity_id AS opportunity_id,
    CASE
      WHEN lo.closed_at IS NULL OR lo.created_at IS NULL THEN NULL
      WHEN lo.closed_at = lo.created_at THEN NULL
      ELSE {{seconds_between(lo.created_at, lo.closed_at)}}
    END AS lifetime_seconds,
    {{seconds_between(lo.created_at, a.occurred_at)}} AS elapsed_seconds
  FROM activities a
  JOIN lost_opps lo ON lo.opportunity_id = a.opportunity_id AND a.tenant_id = lo.tenant_id
),
bucketed AS (
  SELECT
    activity_id,
    opportunity_id,
    CASE
      WHEN lifetime_seconds IS NULL OR elapsed_seconds IS NULL OR elapsed_seconds < 0 OR elapsed_seconds > lifetime_seconds THEN 'outside window'
      WHEN 4 * elapsed_seconds < lifetime_seconds THEN 'Q1 (0-25%)'
      WHEN 2 * elapsed_seconds < lifetime_seconds THEN 'Q2 (25-50%)'
      WHEN 4 * elapsed_seconds < 3 * lifetime_seconds THEN 'Q3 (50-75%)'
      ELSE 'Q4 (75-100%)'
    END AS lifecycle_quartile
  FROM activity_positions
),
totals AS (
  SELECT COUNT(*) AS total_activities_all FROM bucketed
)
SELECT
  b.lifecycle_quartile AS lifecycle_quartile,
  COUNT(*) AS total_activities_in_bucket,
  {{divide_decimal(100.0 * COUNT(*), t.total_activities_all)}} AS pct_of_total_activities,
  COUNT(DISTINCT b.opportunity_id) AS opportunities_with_at_least_one_activity_in_bucket,
  {{divide_decimal(100.0 * COUNT(DISTINCT b.opportunity_id), tl.total_lost_opps)}} AS pct_of_lost_opportunities_with_activity_in_bucket
FROM bucketed b
CROSS JOIN totals t
CROSS JOIN total_lost tl
GROUP BY b.lifecycle_quartile, t.total_activities_all, tl.total_lost_opps
ORDER BY CASE b.lifecycle_quartile
  WHEN 'Q1 (0-25%)' THEN 1
  WHEN 'Q2 (25-50%)' THEN 2
  WHEN 'Q3 (50-75%)' THEN 3
  WHEN 'Q4 (75-100%)' THEN 4
  ELSE 5
END NULLS LAST
