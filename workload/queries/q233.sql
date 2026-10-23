WITH base AS (
  SELECT
    f.warehouse_id AS warehouse_id,
    w.name AS warehouse_name,
    t.name AS tenant_name,
    CASE
      WHEN s.shipped_at >= DATE '2025-01-01' AND s.shipped_at < DATE '2025-11-01' THEN 'baseline'
      WHEN s.shipped_at >= DATE '2025-11-01' AND s.shipped_at < DATE '2026-01-01' THEN 'collapse'
    END AS period,
    s.delivered_at AS delivered_at,
    s.shipped_at AS shipped_at
  FROM shipments s
  JOIN fulfillments f ON f.id = s.fulfillment_id
  JOIN warehouses w ON w.id = f.warehouse_id
  JOIN tenants t ON t.id = w.tenant_id
  WHERE s.carrier = 'Albion Parcel'
    AND s.shipped_at >= DATE '2025-01-01'
    AND s.shipped_at < DATE '2026-01-01'
),
agg AS (
  SELECT
    warehouse_id,
    warehouse_name,
    tenant_name,
    period,
    COUNT(*) AS shipments_shipped,
    AVG({{seconds_between(shipped_at, delivered_at)}} / 86400.0) FILTER (WHERE delivered_at IS NOT NULL) AS avg_transit_days_raw,
    100.0 * COUNT(*) FILTER (WHERE delivered_at IS NOT NULL AND delivered_at <= shipped_at + INTERVAL '3' DAY)
      / NULLIF(COUNT(*) FILTER (WHERE delivered_at IS NOT NULL), 0) AS pct_within_3_days_raw
  FROM base
  WHERE period IS NOT NULL
  GROUP BY warehouse_id, warehouse_name, tenant_name, period
),
period_totals AS (
  SELECT period, SUM(shipments_shipped) AS total_shipments
  FROM agg
  GROUP BY period
),
qualified AS (
  SELECT warehouse_id
  FROM agg
  GROUP BY warehouse_id
  HAVING MAX(shipments_shipped) >= 10
)
SELECT
  a.warehouse_name AS warehouse_name,
  a.tenant_name AS tenant_name,
  a.period AS period,
  a.shipments_shipped AS shipments_shipped,
  a.avg_transit_days_raw AS avg_transit_days,
  a.pct_within_3_days_raw AS pct_within_3_days,
  100.0 * a.shipments_shipped / pt.total_shipments AS share_of_period_shipments_pct
FROM agg a
JOIN period_totals pt ON pt.period = a.period
JOIN qualified q ON q.warehouse_id = a.warehouse_id
ORDER BY a.warehouse_name ASC NULLS LAST, CASE a.period WHEN 'baseline' THEN 0 ELSE 1 END NULLS LAST, a.warehouse_id NULLS LAST
