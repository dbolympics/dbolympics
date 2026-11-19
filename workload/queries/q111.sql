SELECT
    severity,
    COUNT(*) AS total_events,
    SUM(CASE WHEN resolved THEN 1 ELSE 0 END) AS resolved_count,
    SUM(CASE WHEN NOT resolved THEN 1 ELSE 0 END) AS unresolved_count,
    {{divide_decimal(100.0 * SUM(CASE WHEN resolved THEN 1 ELSE 0 END), COUNT(*))}} AS resolution_rate_pct,
    MAX(CASE WHEN NOT resolved THEN DATE '2026-01-05' - CAST(occurred_at AS date) END) AS oldest_unresolved_age_days,
    MAX(occurred_at) AS most_recent_occurred_at
FROM compliance_events
GROUP BY severity
ORDER BY unresolved_count DESC NULLS FIRST, severity ASC NULLS LAST
