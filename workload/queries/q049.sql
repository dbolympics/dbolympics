select
  channel,
  sum(case when started_at >= date '2025-01-01' and started_at < date '2026-01-01' then 1 else 0 end) as sessions_2025,
  {{divide_decimal(100.0 * sum(case when started_at >= date '2025-01-01' and started_at < date '2026-01-01' then 1 else 0 end), nullif(sum(sum(case when started_at >= date '2025-01-01' and started_at < date '2026-01-01' then 1 else 0 end)) over (), 0))}} as share_of_2025_sessions_pct,
  sum(case when started_at >= date '2024-01-01' and started_at < date '2025-01-01' then 1 else 0 end) as sessions_2024,
  {{divide_decimal(100.0 * (
sum(case when started_at >= date '2025-01-01' and started_at < date '2026-01-01' then 1 else 0 end)
- sum(case when started_at >= date '2024-01-01' and started_at < date '2025-01-01' then 1 else 0 end)
), nullif(sum(case when started_at >= date '2024-01-01' and started_at < date '2025-01-01' then 1 else 0 end), 0))}} as yoy_change_pct,
  {{divide_decimal(100.0 * sum(case when started_at >= date '2025-01-01' and started_at < date '2026-01-01' and is_bounce then 1 else 0 end), nullif(sum(case when started_at >= date '2025-01-01' and started_at < date '2026-01-01' then 1 else 0 end), 0))}} as bounce_rate_2025_pct,
  avg(cast(case when started_at >= date '2025-01-01' and started_at < date '2026-01-01' then page_view_count end as numeric(18,6))) as avg_page_views_2025
from (
  select
    coalesce(nullif(trim(utm_source), ''), 'direct/none') as channel,
    started_at,
    is_bounce,
    page_view_count
  from web_sessions
) s
group by channel
order by sessions_2025 desc NULLS FIRST, channel asc NULLS LAST
{{fetch_first(12)}}
