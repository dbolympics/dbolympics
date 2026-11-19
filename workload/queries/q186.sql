WITH cycle_counts AS (
  SELECT
    sm.quantity AS quantity,
    sm.lot_id AS lot_id,
    sm.occurred_at AS occurred_at,
    pv.id AS variant_id,
    COALESCE(c.name, 'Uncategorized') AS category_name
  FROM stock_movements sm
  JOIN product_variants pv ON pv.id = sm.variant_id
  JOIN products p ON p.id = pv.product_id
  LEFT JOIN categories c ON c.id = p.primary_category_id
  WHERE sm.kind = 'cycle_count'
    AND sm.occurred_at >= DATE '2025-01-01'
    AND sm.occurred_at < DATE '2026-01-01'
),
cost_per_variant AS (
  SELECT variant_id, unit_cost, currency_code
  FROM (
    SELECT sp.variant_id AS variant_id, sp.unit_cost AS unit_cost, sp.currency_code AS currency_code,
       ROW_NUMBER() OVER (PARTITION BY sp.variant_id ORDER BY sp.is_preferred DESC NULLS FIRST, sp.id NULLS LAST) AS rn
    FROM supplier_products sp
    WHERE sp.unit_cost IS NOT NULL
  ) x
  WHERE rn = 1
),
cc_valued AS (
  SELECT
    cc.category_name AS category_name,
    cc.quantity AS quantity,
    cc.lot_id AS lot_id,
    CASE WHEN cv.currency_code = 'EUR' THEN cv.unit_cost
         WHEN cv.unit_cost IS NULL THEN NULL
         ELSE CAST({{divide_decimal(cv.unit_cost, er.rate)}} AS NUMERIC(18,6))
    END AS unit_cost_eur
  FROM cycle_counts cc
  LEFT JOIN cost_per_variant cv ON cv.variant_id = cc.variant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = cv.currency_code
   AND er.as_of = CAST(cc.occurred_at AS DATE)
),
category_cc AS (
  SELECT
    category_name,
    COUNT(*) AS cycle_count_events,
    SUM(ABS(quantity)) AS abs_units_variance,
    SUM(quantity) AS net_units_variance,
    SUM(ABS(quantity) * COALESCE(unit_cost_eur, 0)) AS estimated_value_eur,
    {{divide_decimal(100.0 * SUM(CASE WHEN lot_id IS NOT NULL THEN 1 ELSE 0 END), COUNT(*))}} AS pct_lot_or_serial
  FROM cc_valued
  GROUP BY category_name
),
sales AS (
  SELECT
    COALESCE(c.name, 'Uncategorized') AS category_name,
    SUM(oi.quantity) AS total_units_sold
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  JOIN product_variants pv ON pv.id = oi.product_variant_id
  JOIN products p ON p.id = pv.product_id
  LEFT JOIN categories c ON c.id = p.primary_category_id
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY COALESCE(c.name, 'Uncategorized')
)
SELECT
  cc.category_name AS category_name,
  cc.cycle_count_events AS cycle_count_events,
  cc.abs_units_variance AS abs_units_variance,
  cc.net_units_variance AS net_units_variance,
  cc.estimated_value_eur AS estimated_value_eur,
  cc.pct_lot_or_serial AS pct_events_lot_or_serial_tracked,
  {{divide_decimal(COALESCE(s.total_units_sold, 0), 12.0)}} AS avg_monthly_units_sold,
  CASE WHEN COALESCE(s.total_units_sold, 0) = 0 THEN NULL
       ELSE {{divide_decimal(CAST(cc.abs_units_variance AS NUMERIC(18,6)) * 1000, COALESCE(s.total_units_sold, 0))}}
  END AS variance_per_1000_units_sold
FROM category_cc cc
LEFT JOIN sales s ON s.category_name = cc.category_name
ORDER BY cc.estimated_value_eur DESC NULLS FIRST, cc.category_name ASC NULLS LAST
