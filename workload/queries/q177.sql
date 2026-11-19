WITH tenant_scope AS (
  SELECT id AS tenant_id
  FROM tenants
  WHERE industry ILIKE '%industrial%'
     OR industry ILIKE '%office equipment%'
     OR industry ILIKE '%wholesal%'
),
new_business_pipelines AS (
  SELECT tenant_id, id AS pipeline_id
  FROM pipelines
  WHERE name = 'New business'
),
scoped_opportunities AS (
  SELECT
    o.id AS id,
    o.is_won AS is_won,
    o.created_at AS created_at,
    o.closed_at AS closed_at
  FROM opportunities o
  JOIN tenant_scope ts ON ts.tenant_id = o.tenant_id
  JOIN new_business_pipelines nbp
    ON nbp.tenant_id = o.tenant_id
   AND nbp.pipeline_id = o.pipeline_id
  WHERE o.is_closed = true
    AND o.closed_at IS NOT NULL
    AND o.closed_at >= DATE '2023-01-01'
    AND o.closed_at < DATE '2026-01-01'
),
opportunities_with_month AS (
  SELECT
    so.id AS id,
    so.is_won AS is_won,
    cd.month_label AS month_label,
    {{divide_decimal({{seconds_between(so.created_at, so.closed_at)}}, 86400.0)}} AS cycle_days
  FROM scoped_opportunities so
  JOIN calendar_days cd ON cd.calendar_date = CAST(so.closed_at AS DATE)
),
monthly_stats AS (
  SELECT
    month_label,
    COUNT(*) AS opportunities_closed,
    COUNT(*) FILTER (WHERE is_won) AS closed_won,
    COUNT(*) FILTER (WHERE NOT is_won) AS closed_lost,
    AVG(cycle_days) AS avg_cycle_days_raw,
    {{percentile_cont(0.5, cycle_days)}} AS median_cycle_days_raw
  FROM opportunities_with_month
  GROUP BY month_label
)
SELECT
  month_label AS month,
  opportunities_closed,
  closed_won,
  closed_lost,
  {{divide_decimal(100.0 * closed_won, NULLIF(opportunities_closed, 0))}} AS win_rate_pct,
  avg_cycle_days_raw AS avg_cycle_days,
  median_cycle_days_raw AS median_cycle_days
FROM monthly_stats
ORDER BY month ASC NULLS LAST
