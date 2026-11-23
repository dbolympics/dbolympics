with base as (
  select t.id as ticket_id, t.priority AS priority,
         sp.first_response_target_minutes AS first_response_target_minutes,
         sp.resolution_target_minutes AS resolution_target_minutes
  from tickets t
  join sla_policies sp on sp.id = t.sla_policy_id
  where t.created_at >= date '2025-01-01'
    and t.created_at < date '2026-01-01'
    and t.sla_policy_id is not null
),
breach_fr as (
  select ticket_id, avg(cast(minutes_over as numeric(18,6))) as minutes_over
  from sla_breaches
  where breach_kind = 'first_response'
  group by ticket_id
),
breach_res as (
  select ticket_id, avg(cast(minutes_over as numeric(18,6))) as minutes_over
  from sla_breaches
  where breach_kind = 'resolution'
  group by ticket_id
),
per_priority as (
  select
    CAST(b.priority AS text) as priority,
    count(*) as ticket_count_with_sla,
    avg(cast(b.first_response_target_minutes as numeric(18,6))) as typical_first_response_target_minutes,
    avg(cast(b.resolution_target_minutes as numeric(18,6))) as typical_resolution_target_minutes,
    {{divide_decimal(100.0 * count(fr.ticket_id), count(*))}} as first_response_breach_rate,
    {{divide_decimal(100.0 * count(res.ticket_id), count(*))}} as resolution_breach_rate,
    avg(fr.minutes_over) as avg_minutes_over_first_response,
    avg(res.minutes_over) as avg_minutes_over_resolution
  from base b
  left join breach_fr fr on fr.ticket_id = b.ticket_id
  left join breach_res res on res.ticket_id = b.ticket_id
  group by b.priority
),
overall as (
  select
    CAST('All priorities' AS text) as priority,
    count(*) as ticket_count_with_sla,
    CAST(null AS numeric(18,6)) as typical_first_response_target_minutes,
    CAST(null AS numeric(18,6)) as typical_resolution_target_minutes,
    {{divide_decimal(100.0 * count(fr.ticket_id), NULLIF(count(*), 0))}} as first_response_breach_rate,
    {{divide_decimal(100.0 * count(res.ticket_id), NULLIF(count(*), 0))}} as resolution_breach_rate,
    avg(fr.minutes_over) as avg_minutes_over_first_response,
    avg(res.minutes_over) as avg_minutes_over_resolution
  from base b
  left join breach_fr fr on fr.ticket_id = b.ticket_id
  left join breach_res res on res.ticket_id = b.ticket_id
),
combined as (
  select 0 as sort_rank, * from overall
  union all
  select 1 as sort_rank, * from per_priority
)
select
  priority,
  ticket_count_with_sla,
  typical_first_response_target_minutes,
  typical_resolution_target_minutes,
  first_response_breach_rate,
  resolution_breach_rate,
  avg_minutes_over_first_response,
  avg_minutes_over_resolution
from combined
order by sort_rank NULLS LAST, resolution_breach_rate desc nulls last, priority NULLS LAST
