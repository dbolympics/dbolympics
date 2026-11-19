select
  t.name as tenant_name,
  count(*) as ticket_count,
  avg({{divide_decimal({{seconds_between(tk.created_at, tk.first_response_at)}}, 60)}}) as avg_first_response_minutes,
  avg({{divide_decimal({{seconds_between(tk.first_response_at, tk.resolved_at)}}, 60)}}) as avg_post_response_minutes,
  avg({{divide_decimal({{seconds_between(tk.created_at, tk.resolved_at)}}, 60)}}) as avg_resolution_minutes
from tickets tk
join tenants t on t.id = tk.tenant_id
where t.name in ('Marrowby & Vane', 'Studio Vrij', 'Cragsley Outfitters')
  and tk.created_at >= timestamp '2025-01-01'
  and tk.created_at < timestamp '2026-01-01'
  and tk.first_response_at is not null
  and tk.resolved_at is not null
group by t.name
order by avg_post_response_minutes desc NULLS FIRST, tenant_name NULLS LAST
