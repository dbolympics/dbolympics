select
  w.name as webhook_name,
  t.name as tenant_name,
  count(*) as total_deliveries_2025,
  {{divide_decimal(100.0 * sum(case when wd.status = 'success' then 1 else 0 end), count(*))}} as success_rate_pct,
  {{divide_decimal(100.0 * sum(case when wd.status = 'failed' then 1 else 0 end), count(*))}} as failed_rate_pct,
  {{divide_decimal(100.0 * sum(case when wd.status in ('pending','retrying') then 1 else 0 end), count(*))}} as pending_or_retrying_rate_pct,
  avg(cast(wd.duration_ms as numeric(18,6))) as avg_duration_ms
from webhook_deliveries wd
join webhooks w on w.id = wd.webhook_id
join tenants t on t.id = w.tenant_id
where wd.created_at >= date '2025-01-01' and wd.created_at < date '2026-01-01'
group by w.id, w.name, t.name
having count(*) >= 20
order by pending_or_retrying_rate_pct desc NULLS FIRST, failed_rate_pct desc NULLS FIRST, webhook_name asc NULLS LAST, w.id asc NULLS LAST
{{fetch_first(20)}}
