SELECT
    {{year_month({{date_trunc('month', t0.created_at)}})}} AS month,
    COUNT(*) AS adjustment_count,
    SUM(ABS(t0.quantity_delta)) AS total_abs_quantity_delta,
    SUM(t0.quantity_delta) AS net_quantity_delta,
    COUNT(DISTINCT t0.variant_id) AS distinct_variants_affected,
    AVG(CAST(ABS(t0.quantity_delta) AS NUMERIC(18,6))) AS avg_abs_quantity_delta
FROM stock_adjustments t0
WHERE t0.created_at >= DATE '2025-01-01'
  AND t0.created_at < DATE '2026-01-01'
GROUP BY {{date_trunc('month', t0.created_at)}}
ORDER BY month ASC NULLS LAST
