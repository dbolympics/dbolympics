with active_keys as (
  select
    id,
    tenant_id,
    created_at,
    last_used_at,
    date '2026-01-05' - CAST(created_at AS date) as age_days
  from api_keys
  where status = 'active'
),
bucketed as (
  select
    *,
    case
      when age_days < 90 then '1 - under 90 days'
      when age_days < 365 then '2 - 90 days-1 year'
      when age_days < 730 then '3 - 1-2 years'
      when age_days < 1460 then '4 - 2-4 years'
      else '5 - 4+ years'
    end as bucket_sort
  from active_keys
),
totals as (
  select count(*) as total_active from bucketed
)
select
  case b.bucket_sort
    when '1 - under 90 days' then 'under 90 days'
    when '2 - 90 days-1 year' then '90 days-1 year'
    when '3 - 1-2 years' then '1-2 years'
    when '4 - 2-4 years' then '2-4 years'
    when '5 - 4+ years' then '4+ years'
  end as age_bucket,
  count(*) as active_key_count,
  {{divide_decimal(100.0 * count(*), t.total_active)}} as share_pct,
  count(distinct b.tenant_id) as distinct_tenants,
  max(b.age_days) as oldest_key_age_days,
  count(*) filter (where b.last_used_at is null) as never_used_count,
  count(*) filter (where b.last_used_at is not null and b.last_used_at < timestamp '2025-10-05') as unused_90d_plus_count
from bucketed b
cross join totals t
group by b.bucket_sort, t.total_active
order by b.bucket_sort NULLS LAST
