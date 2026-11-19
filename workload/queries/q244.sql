with t2025 as (
  select
    tenant_id,
    count(*) as tickets_created,
    count(distinct assignee_agent_id) as distinct_agents_handled,
    count(*) filter (where assignee_agent_id is null) as unassigned_count
  from tickets
  where created_at >= timestamp '2025-01-01' and created_at < timestamp '2026-01-01'
  group by tenant_id
),
agents as (
  select tenant_id, count(*) as registered_agents
  from support_agents
  group by tenant_id
)
select
  ten.name as merchant_name,
  t.tickets_created AS tickets_created,
  coalesce(a.registered_agents, 0) as registered_support_agents,
  t.distinct_agents_handled AS distinct_agents_handled,
  case when t.distinct_agents_handled > 0
       then {{divide_decimal(CAST(t.tickets_created AS decimal(18,6)), t.distinct_agents_handled)}}
       else null
  end as tickets_per_active_agent,
  {{divide_decimal(100.0 * t.unassigned_count, t.tickets_created)}} as pct_unassigned
from t2025 t
join tenants ten on ten.id = t.tenant_id
left join agents a on a.tenant_id = t.tenant_id
where t.tickets_created >= 20
order by tickets_per_active_agent desc nulls last, merchant_name asc NULLS LAST, t.tenant_id asc NULLS LAST
{{fetch_first(50)}}
