SELECT
  sub.tenant_name AS tenant_name,
  sub.industry AS industry,
  sub.adjustment_events AS adjustment_events,
  sub.abs_units_variance AS abs_units_variance,
  sub.net_units_variance AS net_units_variance,
  sub.estimated_value_eur AS estimated_value_eur,
  {{divide_decimal(sub.estimated_value_eur * 100.0, SUM(sub.estimated_value_eur) OVER ())}} AS share_of_total_value_pct
FROM (
  SELECT
    t.name AS tenant_name,
    t.industry AS industry,
    COUNT(*) AS adjustment_events,
    SUM(ABS(sm.quantity)) AS abs_units_variance,
    SUM(sm.quantity) AS net_units_variance,
    SUM(
ABS(sm.quantity) * COALESCE(
  (SELECT CAST({{divide_decimal(sp.unit_cost, er.rate)}} AS NUMERIC(18,6))
   FROM supplier_products sp
   JOIN exchange_rates er
     ON er.base_code = 'EUR'
    AND er.quote_code = sp.currency_code
    AND er.as_of = CAST(sm.occurred_at AS date)
   WHERE sp.variant_id = sm.variant_id
     AND sp.is_preferred = true
     AND sp.unit_cost IS NOT NULL
   ORDER BY sp.id NULLS LAST
   {{fetch_first(1)}}
  ), 0)
) AS estimated_value_eur
  FROM stock_movements sm
  JOIN stock_locations sl ON sl.id = sm.stock_location_id
  JOIN warehouses w ON w.id = sl.warehouse_id
  JOIN tenants t ON t.id = w.tenant_id
  WHERE sm.kind = 'adjustment'
    AND sm.occurred_at >= DATE '2025-01-01'
    AND sm.occurred_at < DATE '2026-01-01'
  GROUP BY t.id, t.name, t.industry
) sub
ORDER BY sub.estimated_value_eur DESC NULLS FIRST, sub.tenant_name ASC NULLS LAST, sub.industry NULLS LAST, sub.adjustment_events NULLS LAST, sub.abs_units_variance NULLS LAST, sub.net_units_variance NULLS LAST
