WITH selected_tenants AS (
  SELECT
    t0.id AS tenant_id,
    t0.name AS tenant_name,
    CASE
      WHEN t0.name IN ('Thistlecombe','Purrfect Pantry','Chocolaterie Mireille','Kayak Corner','Studio Vrij','Sourdough Club','Grind Collective','Spice Route Box','Kettle & Key','Polder Packaging') THEN 'worst'
      WHEN t0.name IN ('Pfotenglück','Cragsley Outfitters','Brennquell Kaffee','Feather & Fin','Ridgeback Gear','Wohnglück','Mirelle','Honeycomb Larder','Kontor24 Bürobedarf','Tail Wag Supply') THEN 'best'
    END AS performance_group
  FROM tenants t0
  WHERE t0.name IN (
    'Thistlecombe','Purrfect Pantry','Chocolaterie Mireille','Kayak Corner','Studio Vrij','Sourdough Club','Grind Collective','Spice Route Box','Kettle & Key','Polder Packaging',
    'Pfotenglück','Cragsley Outfitters','Brennquell Kaffee','Feather & Fin','Ridgeback Gear','Wohnglück','Mirelle','Honeycomb Larder','Kontor24 Bürobedarf','Tail Wag Supply'
  )
),
shipment_base AS (
  SELECT
    s1.tenant_id AS tenant_id,
    s1.carrier AS carrier,
    s1.shipped_at AS shipped_at,
    s1.delivered_at AS delivered_at
  FROM shipments s1
  JOIN fulfillments f1 ON f1.id = s1.fulfillment_id
  JOIN orders o1 ON o1.id = f1.order_id
  WHERE s1.shipped_at >= TIMESTAMP '2025-01-01'
    AND s1.shipped_at < TIMESTAMP '2026-01-01'
    AND s1.tenant_id IN (SELECT st0.tenant_id AS tenant_id FROM selected_tenants st0)
),
tenant_carrier_counts AS (
  SELECT
    sb0.tenant_id AS tenant_id,
    sb0.carrier AS carrier,
    COUNT(*) AS shipments_count
  FROM shipment_base sb0
  GROUP BY sb0.tenant_id, sb0.carrier
),
tenant_totals AS (
  SELECT
    sb1.tenant_id AS tenant_id,
    COUNT(*) AS total_shipments
  FROM shipment_base sb1
  GROUP BY sb1.tenant_id
),
transit_stats AS (
  SELECT
    sb2.tenant_id AS tenant_id,
    sb2.carrier AS carrier,
    AVG(CASE WHEN sb2.delivered_at IS NOT NULL THEN {{whole_days_between(sb2.shipped_at, sb2.delivered_at)}} END) AS avg_transit_days,
    {{divide_decimal(100.0 * SUM(CASE WHEN sb2.delivered_at IS NOT NULL AND {{whole_days_between(sb2.shipped_at, sb2.delivered_at)}} <= 3 THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN sb2.delivered_at IS NOT NULL THEN 1 ELSE 0 END), 0))}} AS pct_within_3_days
  FROM shipment_base sb2
  GROUP BY sb2.tenant_id, sb2.carrier
)
SELECT
  st.tenant_name AS tenant_name,
  st.performance_group AS performance_group,
  tcc.carrier AS carrier,
  tcc.shipments_count AS shipments_count,
  {{divide_decimal(100.0 * tcc.shipments_count, tt.total_shipments)}} AS share_of_tenant_shipments_pct,
  COALESCE(ts.avg_transit_days, 0) AS avg_transit_days,
  COALESCE(ts.pct_within_3_days, 0) AS pct_within_3_days
FROM tenant_carrier_counts tcc
JOIN selected_tenants st ON st.tenant_id = tcc.tenant_id
JOIN tenant_totals tt ON tt.tenant_id = tcc.tenant_id
LEFT JOIN transit_stats ts ON ts.tenant_id = tcc.tenant_id AND ts.carrier = tcc.carrier
ORDER BY
  CASE st.performance_group WHEN 'worst' THEN 0 ELSE 1 END NULLS LAST,
  st.tenant_name ASC NULLS LAST,
  tcc.shipments_count DESC NULLS FIRST,
  tcc.carrier ASC NULLS LAST,
  tcc.tenant_id ASC NULLS LAST
