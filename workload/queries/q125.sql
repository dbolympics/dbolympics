SELECT t.name as tenant_name,
  jr.total_job_runs_2025 AS total_job_runs_2025,
  jr.failed_runs_2025 AS failed_runs_2025,
  {{divide_decimal(jr.failed_runs_2025 * 100.0, jr.total_job_runs_2025)}} as failure_rate_pct,
  jr.avg_duration_seconds_failed as avg_duration_seconds_failed,
  coalesce(o.total_orders_2025, 0) as total_orders_2025,
  case when coalesce(o.total_orders_2025, 0) = 0 then null
       else {{divide_decimal(cast(jr.failed_runs_2025 as numeric(18,6)) * 1000.0, o.total_orders_2025)}}
  end as failed_runs_per_1000_orders
FROM tenants t
JOIN (
  SELECT tenant_id,
    count(*) as total_job_runs_2025,
    count(*) FILTER (WHERE status = 'failed') as failed_runs_2025,
    avg({{divide_decimal(duration_ms, 1000.0)}}) FILTER (WHERE status = 'failed') as avg_duration_seconds_failed
  FROM job_runs
  WHERE queued_at >= timestamp '2025-01-01' AND queued_at < timestamp '2026-01-01'
  GROUP BY tenant_id
) jr ON jr.tenant_id = t.id
LEFT JOIN (
  SELECT tenant_id, count(*) as total_orders_2025
  FROM orders
  WHERE placed_at >= timestamp '2025-01-01' AND placed_at < timestamp '2026-01-01'
  GROUP BY tenant_id
) o ON o.tenant_id = t.id
ORDER BY jr.failed_runs_2025 DESC NULLS FIRST, t.name ASC NULLS LAST, t.id ASC NULLS LAST
{{fetch_first(20)}}
