WITH kinds AS (
  SELECT DISTINCT kind AS location_kind
  FROM stock_locations
),
location_counts AS (
  SELECT kind AS location_kind,
         COUNT(DISTINCT id) AS total_locations_of_this_kind
  FROM stock_locations
  GROUP BY kind
),
cycle_counts AS (
  SELECT sl.kind AS location_kind,
         sm.stock_location_id AS stock_location_id,
         sm.variant_id AS variant_id,
         sm.quantity AS quantity,
         sm.occurred_at AS occurred_at
  FROM stock_movements sm
  JOIN stock_locations sl ON sl.id = sm.stock_location_id
  WHERE sm.kind = 'cycle_count'
    AND sm.occurred_at >= TIMESTAMP '2025-01-01'
    AND sm.occurred_at < TIMESTAMP '2026-01-01'
),
variant_cost AS (
  SELECT variant_id, unit_cost, currency_code
  FROM (
    SELECT variant_id, unit_cost, currency_code,
           ROW_NUMBER() OVER (PARTITION BY variant_id ORDER BY is_preferred DESC NULLS FIRST, unit_cost ASC NULLS LAST, supplier_id NULLS LAST) AS rn
    FROM supplier_products
    WHERE unit_cost IS NOT NULL
  ) ranked
  WHERE rn = 1
),
valued AS (
  SELECT cc.location_kind AS location_kind,
         cc.stock_location_id AS stock_location_id,
         cc.quantity AS quantity,
         CASE
           WHEN vc.unit_cost IS NOT NULL AND er.rate IS NOT NULL
           THEN CAST({{divide_decimal(ABS(cc.quantity) * vc.unit_cost, er.rate)}} AS NUMERIC(18,6))
           ELSE 0
         END AS value_eur
  FROM cycle_counts cc
  LEFT JOIN variant_cost vc ON vc.variant_id = cc.variant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = vc.currency_code
   AND er.as_of = CAST(cc.occurred_at AS date)
),
agg AS (
  SELECT location_kind,
         COUNT(DISTINCT stock_location_id) AS distinct_locations_with_activity,
         COUNT(*) AS cycle_count_events,
         SUM(ABS(quantity)) AS abs_units_variance,
         SUM(quantity) AS net_units_variance,
         SUM(value_eur) AS estimated_value_eur
  FROM valued
  GROUP BY location_kind
)
SELECT
  k.location_kind AS location_kind,
  COALESCE(a.distinct_locations_with_activity, 0) AS distinct_locations_with_activity,
  COALESCE(lc.total_locations_of_this_kind, 0) AS total_locations_of_this_kind,
  COALESCE(a.cycle_count_events, 0) AS cycle_count_events,
  COALESCE(a.abs_units_variance, 0) AS abs_units_variance,
  COALESCE(a.net_units_variance, 0) AS net_units_variance,
  COALESCE(a.estimated_value_eur, 0) AS estimated_value_eur,
  {{divide_decimal(100.0 * COALESCE(a.estimated_value_eur, 0), NULLIF(SUM(COALESCE(a.estimated_value_eur, 0)) OVER (), 0))}} AS share_of_total_value_pct
FROM kinds k
LEFT JOIN location_counts lc ON lc.location_kind = k.location_kind
LEFT JOIN agg a ON a.location_kind = k.location_kind
ORDER BY COALESCE(a.estimated_value_eur, 0) DESC NULLS FIRST, k.location_kind ASC NULLS LAST
