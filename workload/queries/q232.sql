WITH base AS (
  SELECT
    s.id AS id,
    s.shipped_at AS shipped_at,
    s.delivered_at AS delivered_at,
    c.name AS destination_country,
    {{date_diff_days(s.shipped_at, s.delivered_at)}} AS transit_days,
    CASE
      WHEN s.shipped_at >= DATE '2025-01-01' AND s.shipped_at < DATE '2025-11-01' THEN 'baseline'
      WHEN s.shipped_at >= DATE '2025-11-01' AND s.shipped_at < DATE '2026-01-01' THEN 'collapse'
    END AS period
  FROM shipments s
  JOIN fulfillments f ON s.fulfillment_id = f.id
  JOIN orders o ON f.order_id = o.id
  JOIN addresses a ON o.shipping_address_id = a.id
  JOIN countries c ON a.country_id = c.id
  WHERE s.carrier = 'Albion Parcel'
    AND s.shipped_at >= DATE '2025-01-01'
    AND s.shipped_at < DATE '2026-01-01'
),
agg AS (
  SELECT
    destination_country,
    period,
    COUNT(*) AS shipments_shipped,
    COUNT(*) FILTER (WHERE delivered_at IS NOT NULL) AS delivered_count,
    AVG(CAST(transit_days AS NUMERIC(18,6))) FILTER (WHERE delivered_at IS NOT NULL) AS avg_transit_days,
    COUNT(*) FILTER (WHERE delivered_at IS NOT NULL AND transit_days <= 3) AS within3
  FROM base
  WHERE period IS NOT NULL
  GROUP BY destination_country, period
),
totals AS (
  SELECT period, SUM(shipments_shipped) AS total_shipments
  FROM agg
  GROUP BY period
),
qualified AS (
  SELECT destination_country
  FROM agg
  GROUP BY destination_country
  HAVING MAX(shipments_shipped) >= 15
)
SELECT
  a.destination_country AS destination_country,
  a.period AS period,
  a.shipments_shipped AS shipments_shipped,
  a.avg_transit_days AS avg_transit_days,
  {{divide_decimal(100.0 * a.within3, NULLIF(a.delivered_count, 0))}} AS pct_within_3_days,
  {{divide_decimal(100.0 * a.shipments_shipped, t.total_shipments)}} AS share_of_period_shipments_pct
FROM agg a
JOIN totals t ON a.period = t.period
JOIN qualified q ON q.destination_country = a.destination_country
ORDER BY a.destination_country ASC NULLS LAST, a.period ASC NULLS LAST
