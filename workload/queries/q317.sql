select
  to_status,
  count(*) as total_transitions,
  count(*) filter (where changed_by_user_id is not null) as transitions_with_actor,
  {{divide_decimal(100.0 * count(*) filter (where changed_by_user_id is not null), nullif(count(*), 0))}} as share_with_actor_pct,
  count(distinct tenant_id) as distinct_tenants
from order_status_history
where created_at >= date '2023-01-01' and created_at < date '2026-01-01'
group by to_status
order by total_transitions desc NULLS FIRST, to_status NULLS LAST
