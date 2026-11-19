WITH base AS (
  SELECT
    a.order_id AS order_id,
    a.touch_point AS touch_point,
    a.model AS model,
    a.attributed_revenue AS attributed_revenue,
    a.currency_code AS currency_code,
    a.occurred_at AS occurred_at,
    CASE
      WHEN a.campaign_id IS NULL THEN 'campaign_id is null'
      WHEN c.id IS NULL THEN 'campaign_id set but no matching campaigns row'
      ELSE 'campaign_id set and matches a campaigns row'
    END AS linkage_category
  FROM attributions a
  LEFT JOIN campaigns c ON c.id = a.campaign_id
  WHERE a.occurred_at >= DATE '2025-01-01'
    AND a.occurred_at < DATE '2026-01-01'
    AND a.order_id IS NOT NULL
)
SELECT
  b.linkage_category AS linkage_category,
  COUNT(*) AS attribution_rows_count,
  COUNT(DISTINCT b.order_id) AS distinct_orders_count,
  COUNT(DISTINCT b.touch_point) AS distinct_touch_point_values,
  COUNT(DISTINCT b.model) AS distinct_model_values,
  SUM(
CASE
WHEN COALESCE(b.currency_code, 'EUR') = 'EUR' THEN b.attributed_revenue
ELSE CAST({{divide_decimal(b.attributed_revenue, er.rate)}} AS NUMERIC(18,6))
END
) AS attributed_revenue_eur
FROM base b
LEFT JOIN exchange_rates er
  ON er.base_code = 'EUR'
  AND er.quote_code = b.currency_code
  AND er.as_of = CAST(b.occurred_at AS date)
GROUP BY b.linkage_category
ORDER BY attribution_rows_count DESC NULLS FIRST, b.linkage_category ASC NULLS LAST
