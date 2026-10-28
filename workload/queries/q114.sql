SELECT
  {{year_month(date_trunc('month', occurred_at))}} as month,
  severity,
  count(*) as incidents_detected,
  count(*) filter (where resolved) as resolved_count,
  count(*) filter (where not resolved) as unresolved_count,
  ({{percentile_cont_filter(0.5, {{seconds_between(occurred_at, resolved_at)}}/86400.0, resolved)}}) as median_days_to_resolve,
  count(*) filter (
    where not resolved
      and occurred_at < TIMESTAMP '2026-01-05' - INTERVAL '30 days'
  ) as unresolved_over_30d
FROM compliance_events
WHERE occurred_at >= timestamp '2023-01-01'
  AND occurred_at < timestamp '2026-01-01'
GROUP BY 1, 2
ORDER BY 1 NULLS LAST, 2 NULLS LAST
