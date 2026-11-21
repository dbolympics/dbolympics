WITH q4_shipments AS (
    SELECT
        carrier,
        shipped_at,
        delivered_at,
        CASE WHEN delivered_at IS NOT NULL
             THEN {{divide_decimal({{seconds_between(shipped_at, delivered_at)}}, 86400.0)}}
        END AS transit_days
    FROM shipments
    WHERE shipped_at >= DATE '2025-10-01'
      AND shipped_at < DATE '2026-01-01'
),
carrier_stats AS (
    SELECT
        carrier,
        COUNT(*) AS shipments_shipped,
        COUNT(delivered_at) AS shipments_delivered,
        AVG(transit_days) AS avg_transit_days,
        {{percentile_cont(0.5, transit_days)}} AS median_transit_days,
        {{percentile_cont(0.9, transit_days)}} AS p90_transit_days,
        COUNT(CASE WHEN transit_days <= 3 THEN 1 END) AS delivered_within_3_days
    FROM q4_shipments
    GROUP BY carrier
),
totals AS (
    SELECT SUM(shipments_shipped) AS total_q4_shipments
    FROM carrier_stats
)
SELECT
    cs.carrier AS carrier,
    cs.shipments_shipped AS shipments_shipped,
    cs.shipments_delivered AS shipments_delivered,
    cs.avg_transit_days AS avg_transit_days,
    cs.median_transit_days AS median_transit_days,
    cs.p90_transit_days AS p90_transit_days,
    {{divide_decimal(100.0 * cs.delivered_within_3_days, NULLIF(cs.shipments_delivered, 0))}} AS pct_within_3_days,
    {{divide_decimal(100.0 * cs.shipments_delivered, NULLIF(cs.shipments_shipped, 0))}} AS pct_delivered,
    {{divide_decimal(100.0 * cs.shipments_shipped, NULLIF(t.total_q4_shipments, 0))}} AS share_of_q4_shipments_pct
FROM carrier_stats cs
CROSS JOIN totals t
ORDER BY cs.shipments_shipped DESC NULLS FIRST, cs.carrier ASC NULLS LAST
