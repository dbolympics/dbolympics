WITH ticket_base AS (
    SELECT
        t0.id AS ticket_id,
        t0.created_at AS created_at,
        t0.resolved_at AS resolved_at,
        CASE
            WHEN EXISTS (SELECT 1 FROM ticket_tags_map t1 WHERE t1.ticket_id = t0.id)
            THEN 'Tagged'
            ELSE 'Untagged'
        END AS coverage_status
    FROM tickets t0
    WHERE t0.created_at >= DATE '2025-01-01'
      AND t0.created_at < DATE '2026-01-01'
),
counts AS (
    SELECT
        t2.coverage_status AS coverage_status,
        COUNT(*) AS ticket_count
    FROM ticket_base t2
    GROUP BY t2.coverage_status
),
grand_total AS (
    SELECT COUNT(*) AS total_tickets
    FROM ticket_base t3
),
resolution_time AS (
    SELECT
        t4.coverage_status AS coverage_status,
        AVG({{divide_decimal({{seconds_between(t4.created_at, t4.resolved_at)}}, 60.0)}}) AS avg_resolution_minutes
    FROM ticket_base t4
    WHERE t4.resolved_at IS NOT NULL
    GROUP BY t4.coverage_status
),
resolution_breaches AS (
    SELECT
        t5.coverage_status AS coverage_status,
        COUNT(DISTINCT t6.ticket_id) AS resolution_breach_count
    FROM ticket_base t5
    JOIN sla_breaches t6
        ON t6.ticket_id = t5.ticket_id
        AND t6.breach_kind = 'resolution'
    GROUP BY t5.coverage_status
),
first_response_breaches AS (
    SELECT
        t7.coverage_status AS coverage_status,
        COUNT(DISTINCT t8.ticket_id) AS first_response_breach_count
    FROM ticket_base t7
    JOIN sla_breaches t8
        ON t8.ticket_id = t7.ticket_id
        AND t8.breach_kind = 'first_response'
    GROUP BY t7.coverage_status
)
SELECT
    t9.coverage_status AS coverage_status,
    t9.ticket_count AS ticket_count,
    {{divide_decimal(100.0 * t9.ticket_count, NULLIF(t10.total_tickets, 0))}} AS pct_of_total_tickets,
    COALESCE(t11.avg_resolution_minutes, 0) AS avg_resolution_minutes,
    {{divide_decimal(100.0 * COALESCE(t12.resolution_breach_count, 0), NULLIF(t9.ticket_count, 0))}} AS resolution_breach_rate,
    {{divide_decimal(100.0 * COALESCE(t13.first_response_breach_count, 0), NULLIF(t9.ticket_count, 0))}} AS first_response_breach_rate
FROM counts t9
CROSS JOIN grand_total t10
LEFT JOIN resolution_time t11 ON t11.coverage_status = t9.coverage_status
LEFT JOIN resolution_breaches t12 ON t12.coverage_status = t9.coverage_status
LEFT JOIN first_response_breaches t13 ON t13.coverage_status = t9.coverage_status
ORDER BY
    CASE WHEN t9.coverage_status = 'Tagged' THEN 0 ELSE 1 END NULLS LAST,
    t9.coverage_status NULLS LAST
