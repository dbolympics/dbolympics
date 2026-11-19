WITH target_tenants AS (
  SELECT id, name FROM tenants
  WHERE name IN ('Kibblewick','Studio Vrij','Petalcourt Beauty','Marrowby & Vane','Cragsley Outfitters','Ampfeld Elektronik')
),
cart_population AS (
  SELECT c.id AS id, c.tenant_id AS tenant_id, c.currency_code AS currency_code, c.subtotal AS subtotal, c.item_count AS item_count, c.status AS status, c.created_at AS created_at, c.converted_at AS converted_at
  FROM carts c
  JOIN target_tenants t ON t.id = c.tenant_id
  WHERE c.created_at >= DATE '2025-01-01' AND c.created_at < DATE '2026-01-01'
),
cart_with_eur AS (
  SELECT cp.*,
    CASE WHEN cp.currency_code = 'EUR' THEN CAST(cp.subtotal AS NUMERIC(18,6))
         ELSE CAST({{divide_decimal(cp.subtotal, er.rate)}} AS NUMERIC(18,6)) END AS subtotal_eur
  FROM cart_population cp
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = cp.currency_code
    AND er.as_of = CAST(cp.created_at AS DATE)
),
tiered_carts AS (
  SELECT *,
    CASE
      WHEN subtotal_eur < 50 THEN '<€50'
      WHEN subtotal_eur < 100 THEN '€50-100'
      WHEN subtotal_eur < 200 THEN '€100-200'
      ELSE '€200+'
    END AS price_tier,
    CASE WHEN status = 'converted' THEN 1 ELSE 0 END AS is_converted,
    CASE WHEN status = 'converted' AND converted_at <= created_at + INTERVAL '1 hour' THEN 1 ELSE 0 END AS resolved_1h,
    CASE WHEN status = 'converted' AND converted_at > created_at + INTERVAL '1 day' AND converted_at <= created_at + INTERVAL '7 days' THEN 1 ELSE 0 END AS resolved_1_7d
  FROM cart_with_eur
),
tier_totals AS (
  SELECT COUNT(*) AS total_carts FROM tiered_carts
),
tier_aggregates AS (
  SELECT
    price_tier,
    COUNT(*) AS cart_count,
    AVG(CAST(item_count AS NUMERIC(18,6))) AS avg_item_count,
    SUM(is_converted) AS converted_count,
    SUM(resolved_1h) AS resolved_1h_count,
    SUM(resolved_1_7d) AS resolved_1_7d_count
  FROM tiered_carts
  GROUP BY price_tier
)
SELECT
  ta.price_tier AS price_tier,
  ta.cart_count AS cart_count,
  {{divide_decimal(100.0 * ta.cart_count, tt.total_carts)}} AS pct_of_total_carts,
  ta.avg_item_count AS avg_item_count,
  {{divide_decimal(100.0 * ta.converted_count, ta.cart_count)}} AS overall_conversion_pct,
  {{divide_decimal(100.0 * ta.resolved_1h_count, ta.cart_count)}} AS pct_resolved_within_1_hour,
  {{divide_decimal(100.0 * ta.resolved_1_7d_count, ta.cart_count)}} AS pct_resolved_in_1_7_days
FROM tier_aggregates ta
CROSS JOIN tier_totals tt
ORDER BY
  CASE ta.price_tier
    WHEN '<€50' THEN 1
    WHEN '€50-100' THEN 2
    WHEN '€100-200' THEN 3
    WHEN '€200+' THEN 4
  END NULLS LAST
