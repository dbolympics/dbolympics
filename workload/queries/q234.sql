WITH base AS (
  SELECT
    s.carrier AS carrier,
    co.name AS destination_country,
    s.id AS shipment_id,
    s.delivered_at AS delivered_at,
    {{date_diff_days(s.shipped_at, s.delivered_at)}} AS transit_days
  FROM shipments s
  JOIN fulfillments f ON f.id = s.fulfillment_id
  JOIN orders o ON o.id = f.order_id
  JOIN addresses a ON a.id = o.shipping_address_id
  JOIN countries co ON co.id = a.country_id
  WHERE s.carrier IN ('Landfall Freight','Lowlands Express')
    AND s.shipped_at >= TIMESTAMP '2025-01-01'
    AND s.shipped_at < TIMESTAMP '2026-01-01'
),
carrier_totals AS (
  SELECT carrier, COUNT(*) AS carrier_shipments
  FROM base
  GROUP BY carrier
),
country_stats AS (
  SELECT
    carrier,
    destination_country,
    COUNT(*) AS shipments_shipped,
    AVG(CAST(transit_days AS NUMERIC(18,6))) FILTER (WHERE delivered_at IS NOT NULL) AS avg_transit_days,
    COUNT(*) FILTER (WHERE delivered_at IS NOT NULL AND transit_days <= 3) AS within_3_count
  FROM base
  GROUP BY carrier, destination_country
)
SELECT
  cs.carrier AS carrier,
  cs.destination_country AS destination_country,
  cs.shipments_shipped AS shipments_shipped,
  cs.avg_transit_days AS avg_transit_days,
  {{divide_decimal(100.0 * cs.within_3_count, cs.shipments_shipped)}} AS pct_within_3_days,
  {{divide_decimal(100.0 * cs.shipments_shipped, ct.carrier_shipments)}} AS share_of_carrier_shipments_pct
FROM country_stats cs
JOIN carrier_totals ct ON ct.carrier = cs.carrier
WHERE cs.shipments_shipped >= 15
ORDER BY cs.carrier ASC NULLS LAST, cs.shipments_shipped DESC NULLS FIRST, cs.destination_country ASC NULLS LAST
