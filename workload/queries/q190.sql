WITH variant_cost AS (
  SELECT sp.variant_id AS variant_id, sp.unit_cost AS unit_cost, sp.currency_code AS currency_code,
    ROW_NUMBER() OVER (PARTITION BY sp.variant_id ORDER BY sp.is_preferred DESC NULLS FIRST, sp.unit_cost ASC NULLS LAST, sp.supplier_id NULLS LAST) AS rn
  FROM supplier_products sp
  WHERE sp.unit_cost IS NOT NULL
),
best_cost AS (
  SELECT variant_id, unit_cost, currency_code FROM variant_cost WHERE rn = 1
),
movements AS (
  SELECT sm.id AS id, sm.variant_id AS variant_id, sm.quantity AS quantity, sm.occurred_at AS occurred_at,
         CAST(sm.occurred_at AS date) AS occ_date
  FROM stock_movements sm
  WHERE sm.kind = 'adjustment'
    AND sm.occurred_at >= DATE '2025-01-01'
    AND sm.occurred_at < DATE '2026-01-01'
),
valued AS (
  SELECT m.id AS id, m.quantity AS quantity,
    {{date_trunc('month', m.occurred_at)}} AS month_start,
    CASE WHEN bc.currency_code = 'EUR' THEN bc.unit_cost
         WHEN bc.currency_code IS NULL THEN NULL
         ELSE CAST(bc.unit_cost / er.rate AS NUMERIC(18,6))
    END AS unit_cost_eur
  FROM movements m
  LEFT JOIN best_cost bc ON bc.variant_id = m.variant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = bc.currency_code AND er.as_of = m.occ_date
)
SELECT
  {{year_month(month_start)}} AS month,
  COUNT(*) AS adjustment_events,
  SUM(CASE WHEN quantity < 0 THEN -quantity ELSE 0 END) AS units_short,
  SUM(CASE WHEN quantity > 0 THEN quantity ELSE 0 END) AS units_over,
  SUM(quantity) AS net_units_variance,
  SUM(ABS(quantity)) AS abs_units_variance,
  SUM(ABS(quantity) * COALESCE(unit_cost_eur,0)) AS estimated_value_eur,
  AVG(CAST(ABS(quantity) AS NUMERIC(18,6))) AS avg_abs_units_per_event
FROM valued
GROUP BY month_start
ORDER BY month_start NULLS LAST
