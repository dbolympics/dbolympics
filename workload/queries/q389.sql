WITH periods AS (
  SELECT DISTINCT
    CAST({{date_trunc('month', calendar_date)}} AS date) AS month_start,
    CASE WHEN day_of_month <= 15 THEN 1 ELSE 2 END AS half
  FROM calendar_days
  WHERE calendar_date >= DATE '2025-01-01' AND calendar_date < DATE '2026-01-01'
),
adj AS (
  SELECT
    CAST({{date_trunc('month', sa.created_at)}} AS date) AS month_start,
    CASE WHEN CAST(EXTRACT(day FROM sa.created_at) AS int) <= 15 THEN 1 ELSE 2 END AS half,
    sa.stock_location_id AS stock_location_id,
    sa.quantity_delta AS quantity_delta
  FROM stock_adjustments sa
  JOIN stock_locations sl ON sl.id = sa.stock_location_id
  WHERE sa.created_at >= DATE '2025-01-01' AND sa.created_at < DATE '2026-01-01'
),
adj_agg AS (
  SELECT
    month_start, half,
    COUNT(*) AS events,
    SUM(ABS(quantity_delta)) AS abs_units_variance,
    SUM(quantity_delta) AS net_units_variance,
    COUNT(DISTINCT stock_location_id) AS distinct_locations_active
  FROM adj
  GROUP BY month_start, half
),
wh AS (
  SELECT
    CAST({{date_trunc('month', w.created_at)}} AS date) AS month_start,
    CASE WHEN CAST(EXTRACT(day FROM w.created_at) AS int) <= 15 THEN 1 ELSE 2 END AS half,
    COUNT(*) AS new_warehouses
  FROM warehouses w
  WHERE w.created_at >= DATE '2025-01-01' AND w.created_at < DATE '2026-01-01'
  GROUP BY month_start, half
)
SELECT
  {{year_month(p.month_start)}} || ' (' ||
    CASE WHEN p.half = 1 THEN '1-15'
         ELSE '16-' || CAST(EXTRACT(DAY FROM (p.month_start + INTERVAL '1 month' - INTERVAL '1 day')) AS int)
    END || ')' AS period_label,
  COALESCE(a.events, 0) AS events,
  COALESCE(a.abs_units_variance, 0) AS abs_units_variance,
  COALESCE(a.net_units_variance, 0) AS net_units_variance,
  COALESCE(a.distinct_locations_active, 0) AS distinct_locations_active,
  CASE WHEN COALESCE(a.distinct_locations_active, 0) = 0 THEN NULL
       ELSE CAST(a.events AS numeric(18,6)) / a.distinct_locations_active
  END AS events_per_active_location,
  COALESCE(w.new_warehouses, 0) AS new_warehouses_opened_this_period
FROM periods p
LEFT JOIN adj_agg a ON a.month_start = p.month_start AND a.half = p.half
LEFT JOIN wh w ON w.month_start = p.month_start AND w.half = p.half
ORDER BY p.month_start NULLS LAST, p.half NULLS LAST
