WITH bundle_counts AS (
  SELECT tenant_id, COUNT(*) AS active_bundle_count
  FROM product_bundles
  WHERE is_active = true
  GROUP BY tenant_id
),
product_counts AS (
  SELECT tenant_id, COUNT(*) AS active_product_count
  FROM products
  WHERE status = 'active'
  GROUP BY tenant_id
),
variant_counts AS (
  SELECT p.tenant_id AS tenant_id,
         {{divide_decimal(CAST(COUNT(pv.id) AS decimal(18,6)), NULLIF(COUNT(DISTINCT p.id), 0))}} AS avg_variants_per_product
  FROM products p
  JOIN product_variants pv ON pv.product_id = p.id AND pv.is_active = true
  WHERE p.status = 'active'
  GROUP BY p.tenant_id
),
bundled_products AS (
  SELECT DISTINCT p.tenant_id AS tenant_id, p.id AS product_id
  FROM product_bundles pb
  JOIN bundle_items bi ON bi.bundle_id = pb.id
  JOIN product_variants pv ON pv.id = bi.variant_id
  JOIN products p ON p.id = pv.product_id
  WHERE pb.is_active = true AND p.status = 'active'
),
bundled_product_counts AS (
  SELECT tenant_id, COUNT(*) AS bundled_product_count
  FROM bundled_products
  GROUP BY tenant_id
),
order_stats AS (
  SELECT o.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS revenue_eur,
         COUNT(*) AS order_count
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
)
SELECT
  t.name AS merchant_name,
  t.industry AS industry,
  bc.active_bundle_count AS active_bundle_count,
  {{divide_decimal(100.0 * COALESCE(bpc.bundled_product_count, 0), NULLIF(pc.active_product_count, 0))}} AS pct_active_products_in_a_bundle,
  pc.active_product_count AS active_product_count,
  vc.avg_variants_per_product AS avg_variants_per_product,
  os.revenue_eur AS revenue_eur_last_12mo,
  {{divide_decimal(os.revenue_eur, NULLIF(os.order_count, 0))}} AS avg_order_value_eur_last_12mo
FROM bundle_counts bc
JOIN tenants t ON t.id = bc.tenant_id
LEFT JOIN product_counts pc ON pc.tenant_id = bc.tenant_id
LEFT JOIN variant_counts vc ON vc.tenant_id = bc.tenant_id
LEFT JOIN bundled_product_counts bpc ON bpc.tenant_id = bc.tenant_id
LEFT JOIN order_stats os ON os.tenant_id = bc.tenant_id
ORDER BY pct_active_products_in_a_bundle DESC NULLS LAST, revenue_eur_last_12mo DESC NULLS LAST, t.id ASC NULLS LAST
{{fetch_first(50)}}
