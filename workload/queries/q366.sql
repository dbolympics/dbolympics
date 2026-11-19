select
  status,
  count(*) as total_subscriptions,
  count(*) filter (where ended_at is not null and ended_at < timestamp '2026-01-05') as past_ended_count,
  {{divide_decimal(100.0 * count(*) filter (where ended_at is not null and ended_at < timestamp '2026-01-05'), nullif(count(*), 0))}} as pct_past_ended,
  count(*) filter (where ended_at is null or ended_at >= timestamp '2026-01-05') as status_consistent_count
from subscriptions
where status in ('trialing', 'active', 'past_due')
group by status
order by pct_past_ended desc NULLS FIRST, status NULLS LAST
