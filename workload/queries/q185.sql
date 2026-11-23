WITH variant_cost AS (
  SELECT variant_id, unit_cost, currency_code
  FROM (
    SELECT variant_id, unit_cost, currency_code,
           ROW_NUMBER() OVER (
             PARTITION BY variant_id
             ORDER BY CASE WHEN is_preferred THEN 0 ELSE 1 END NULLS LAST, unit_cost ASC NULLS LAST, supplier_id NULLS LAST
           ) AS rn
    FROM supplier_products
    WHERE unit_cost IS NOT NULL
  ) ranked
  WHERE rn = 1
),
agg AS (
  SELECT
    t.id AS tenant_id,
    t.name AS tenant_name,
    w.id AS warehouse_id,
    w.name AS warehouse_name,
    sl.kind AS location_kind,
    COUNT(*) AS cycle_count_events,
    SUM(sm.quantity) AS net_units_variance,
    SUM(ABS(sm.quantity)) AS abs_units_variance,
    SUM({{divide_decimal(ABS(sm.quantity) * vc.unit_cost, CASE WHEN vc.currency_code = 'EUR' THEN 1 ELSE er.rate END)}}) AS estimated_value_eur
  FROM stock_movements sm
  JOIN stock_locations sl ON sl.id = sm.stock_location_id
  JOIN warehouses w ON w.id = sl.warehouse_id
  JOIN tenants t ON t.id = w.tenant_id
  JOIN variant_cost vc ON vc.variant_id = sm.variant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = vc.currency_code
   AND er.as_of = CAST(sm.occurred_at AS date)
  WHERE sm.kind = 'cycle_count'
    AND sm.occurred_at >= DATE '2025-01-01'
    AND sm.occurred_at < DATE '2026-01-01'
  GROUP BY t.id, t.name, w.id, w.name, sl.kind
)
SELECT
  tenant_name,
  warehouse_name,
  location_kind,
  cycle_count_events,
  net_units_variance,
  abs_units_variance,
  estimated_value_eur AS estimated_value_eur,
  estimated_value_eur / SUM(estimated_value_eur) OVER () * 100 AS share_of_total_value_pct
FROM agg
ORDER BY estimated_value_eur DESC NULLS FIRST, abs_units_variance DESC NULLS FIRST, tenant_name NULLS LAST, warehouse_name NULLS LAST, location_kind NULLS LAST, warehouse_id NULLS LAST
{{fetch_first(50)}}
