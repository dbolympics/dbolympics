SELECT
  cd.month_label AS month,
  count(*) AS opportunities_closed,
  count(*) FILTER (WHERE o.is_won) AS closed_won,
  count(*) FILTER (WHERE NOT o.is_won) AS closed_lost,
  100.0 * count(*) FILTER (WHERE o.is_won) / NULLIF(count(*), 0) AS win_rate_pct,
  avg({{whole_days_between(o.created_at, o.closed_at)}}) AS avg_cycle_days,
  {{percentile_cont(0.5, {{whole_days_between(o.created_at, o.closed_at)}})}} AS median_cycle_days
FROM opportunities o
JOIN accounts a ON a.id = o.account_id
JOIN tenants t ON t.id = a.tenant_id
JOIN calendar_days cd ON cd.calendar_date = CAST(o.closed_at AS date)
WHERE (t.industry ILIKE '%industrial%' OR t.industry ILIKE '%office equipment%' OR t.industry ILIKE '%wholesal%')
  AND o.is_closed = true
  AND o.closed_at IS NOT NULL
  AND o.closed_at >= DATE '2023-01-01'
  AND o.closed_at < DATE '2026-01-01'
GROUP BY cd.month_label
ORDER BY month ASC NULLS LAST
