select
  entity_table,
  count(distinct tenant_id) as tenants_with_policy,
  {{divide_decimal(100.0 * count(distinct tenant_id), 120)}} as pct_tenants_with_policy,
  avg(cast(retention_days as numeric(18,6))) as avg_retention_days,
  min(retention_days) as min_retention_days,
  max(retention_days) as max_retention_days,
  {{divide_decimal(100.0 * sum(case when is_active then 1 else 0 end), count(*))}} as pct_policies_active,
  {{divide_decimal(100.0 * sum(case when last_run_at >= date '2025-10-03' then 1 else 0 end), count(*))}} as pct_policies_run_in_last_90_days
from retention_policies
where entity_table in ('audit_log', 'access_log', 'change_history', 'data_subject_requests', 'compliance_events', 'login_attempts')
group by entity_table
order by entity_table NULLS LAST
