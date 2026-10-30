select
  CAST({{date_trunc('month', queued_at)}} AS date) as month,
  count(*) as total_job_runs,
  count(*) filter (where status = 'failed') as failed_runs,
  100.0 * count(*) filter (where status = 'failed') / nullif(count(*), 0) as failure_rate_pct,
  count(*) filter (where status = 'cancelled') as cancelled_runs,
  100.0 * count(*) filter (where status = 'cancelled') / nullif(count(*), 0) as cancelled_rate_pct,
  avg({{seconds_between(started_at, finished_at)}}) filter (where started_at is not null and finished_at is not null) as avg_duration_seconds,
  {{percentile_cont_filter(0.95, {{seconds_between(started_at, finished_at)}}, started_at is not null and finished_at is not null)}} as p95_duration_seconds
from job_runs
where queued_at >= date '2025-01-01' and queued_at < date '2026-01-01'
group by 1
order by 1 asc NULLS LAST
