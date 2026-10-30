with checks_2025 as (
  select
    {{date_trunc('month', checked_at)}} as month_start,
    is_healthy,
    latency_ms,
    component
  from system_health_checks
  where checked_at >= date '2025-01-01'
    and checked_at < date '2026-01-01'
),
monthly_agg as (
  select
    month_start,
    count(*) as total_checks,
    count(*) filter (where is_healthy = false) as unhealthy_checks,
    avg(cast(latency_ms as numeric(18,6))) as avg_latency_ms,
    count(distinct component) as distinct_components_checked
  from checks_2025
  group by month_start
)
select
  {{year_month(month_start)}} as month,
  total_checks,
  unhealthy_checks,
  100.0 * unhealthy_checks / nullif(total_checks, 0) as unhealthy_rate_pct,
  avg_latency_ms,
  distinct_components_checked
from monthly_agg
order by month_start asc NULLS LAST
