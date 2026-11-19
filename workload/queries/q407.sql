WITH base AS (
  SELECT
    s.id AS id,
    s.shipped_at AS shipped_at,
    s.delivered_at AS delivered_at,
    {{year_month(s.shipped_at)}} AS month_label
  FROM shipments s
  JOIN tenants t ON t.id = s.tenant_id
  WHERE t.name = 'Marrowby & Vane'
    AND s.carrier = 'Albion Parcel'
    AND s.shipped_at >= DATE '2025-01-01'
    AND s.shipped_at < DATE '2026-01-01'
),
monthly_shipment_counts AS (
  SELECT
    month_label,
    COUNT(*) AS shipment_count
  FROM base
  GROUP BY month_label
),
delivered_base AS (
  SELECT
    month_label,
    {{divide_decimal({{seconds_between(shipped_at, delivered_at)}}, 86400.0)}} AS delivery_days
  FROM base
  WHERE shipped_at IS NOT NULL
    AND delivered_at IS NOT NULL
),
monthly_delivery_stats AS (
  SELECT
    month_label,
    AVG(delivery_days) AS avg_delivery_days,
    {{divide_decimal(100.0 * SUM(CASE WHEN delivery_days <= 3 THEN 1 ELSE 0 END), COUNT(*))}} AS pct_delivered_within_3_days
  FROM delivered_base
  GROUP BY month_label
)
SELECT
  c.month_label AS month_label,
  c.shipment_count AS shipment_count,
  d.avg_delivery_days AS avg_delivery_days,
  d.pct_delivered_within_3_days AS pct_delivered_within_3_days
FROM monthly_shipment_counts c
LEFT JOIN monthly_delivery_stats d ON c.month_label = d.month_label
ORDER BY c.month_label ASC NULLS LAST
