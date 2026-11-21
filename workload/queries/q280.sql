SELECT
  severity,
  count(*) AS total_events,
  count(*) FILTER (WHERE resolved) AS resolved_count,
  count(*) FILTER (WHERE NOT resolved) AS unresolved_count,
  {{divide_decimal(100.0 * count(*) FILTER (WHERE resolved), NULLIF(count(*), 0))}} AS pct_resolved,
  avg({{divide_decimal({{seconds_between(occurred_at, resolved_at)}}, 86400.0)}}) FILTER (WHERE resolved) AS avg_days_to_resolve,
  ({{percentile_cont_filter(0.5, {{divide_decimal({{seconds_between(occurred_at, resolved_at)}}, 86400.0)}}, resolved)}}) AS median_days_to_resolve,
  max(CASE WHEN NOT resolved THEN {{divide_decimal({{seconds_between(occurred_at, timestamp '2025-12-31')}}, 86400.0)}} END) AS oldest_unresolved_age_days,
  count(DISTINCT event_type) AS distinct_event_types
FROM compliance_events
WHERE occurred_at >= timestamp '2023-01-01'
  AND occurred_at < timestamp '2026-01-01'
GROUP BY severity
ORDER BY total_events DESC NULLS FIRST, severity NULLS LAST
