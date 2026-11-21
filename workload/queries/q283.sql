with failed_logins as (
  select
    t.id as tenant_id,
    t.name as tenant_name,
    la.user_agent AS user_agent,
    cast(la.occurred_at as date) as failure_day
  from login_attempts la
  join tenants t on t.id = la.tenant_id
  where t.name in ('Cragsley Outfitters', 'Marrowby & Vane', 'Studio Vrij')
    and la.succeeded = false
    and la.occurred_at >= timestamp '2025-02-01'
    and la.occurred_at < timestamp '2025-03-01'
),
tenant_totals as (
  select tenant_id, tenant_name, count(*) as total_failed
  from failed_logins
  group by tenant_id, tenant_name
),
user_agent_counts as (
  select tenant_id, user_agent, count(*) as ua_count
  from failed_logins
  group by tenant_id, user_agent
),
distinct_ua as (
  select tenant_id, count(distinct user_agent) as distinct_user_agents
  from failed_logins
  group by tenant_id
),
top_ua as (
  select tenant_id, max(ua_count) as top_ua_count
  from user_agent_counts
  group by tenant_id
),
day_counts as (
  select tenant_id, failure_day, count(*) as day_count
  from failed_logins
  group by tenant_id, failure_day
),
distinct_days as (
  select tenant_id, count(distinct failure_day) as distinct_calendar_days_with_failures
  from failed_logins
  group by tenant_id
),
max_day as (
  select tenant_id, max(day_count) as max_failed_attempts_single_day
  from day_counts
  group by tenant_id
),
ranked_days as (
  select tenant_id, day_count,
    row_number() over (partition by tenant_id order by day_count desc NULLS FIRST) as rn
  from day_counts
),
top3_days as (
  select tenant_id, sum(day_count) as top3_sum
  from ranked_days
  where rn <= 3
  group by tenant_id
)
select
  tt.tenant_name AS tenant_name,
  du.distinct_user_agents AS distinct_user_agents,
  {{divide_decimal(100.0 * tu.top_ua_count, tt.total_failed)}} as top_user_agent_share_pct,
  dd.distinct_calendar_days_with_failures AS distinct_calendar_days_with_failures,
  md.max_failed_attempts_single_day AS max_failed_attempts_single_day,
  {{divide_decimal(100.0 * t3.top3_sum, tt.total_failed)}} as pct_failed_attempts_in_top_3_days
from tenant_totals tt
join distinct_ua du on du.tenant_id = tt.tenant_id
join top_ua tu on tu.tenant_id = tt.tenant_id
join distinct_days dd on dd.tenant_id = tt.tenant_id
join max_day md on md.tenant_id = tt.tenant_id
join top3_days t3 on t3.tenant_id = tt.tenant_id
order by tt.tenant_name NULLS LAST, tt.tenant_id NULLS LAST
