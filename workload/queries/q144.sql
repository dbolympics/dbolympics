WITH tenant_revenue AS (
  SELECT o.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) AS revenue_eur,
         COUNT(*) AS orders_cnt
  FROM orders o
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY o.tenant_id
),
active_products AS (
  SELECT tenant_id, COUNT(*) AS active_product_count
  FROM products
  WHERE status = 'active' AND deleted_at IS NULL
  GROUP BY tenant_id
),
products_in_collection AS (
  SELECT p.tenant_id AS tenant_id, COUNT(DISTINCT p.id) AS cnt
  FROM products p
  JOIN collection_products cp ON cp.product_id = p.id AND cp.tenant_id = p.tenant_id
  JOIN collections c ON c.id = cp.collection_id AND c.tenant_id = p.tenant_id AND c.deleted_at IS NULL
  WHERE p.status = 'active' AND p.deleted_at IS NULL
  GROUP BY p.tenant_id
),
products_in_bundle AS (
  SELECT p.tenant_id AS tenant_id, COUNT(DISTINCT p.id) AS cnt
  FROM products p
  JOIN product_variants pv ON pv.product_id = p.id AND pv.tenant_id = p.tenant_id
  JOIN bundle_items bi ON bi.variant_id = pv.id AND bi.tenant_id = pv.tenant_id
  JOIN product_bundles pb ON pb.id = bi.bundle_id AND pb.tenant_id = pv.tenant_id AND pb.is_active = true
  WHERE p.status = 'active' AND p.deleted_at IS NULL
  GROUP BY p.tenant_id
),
collection_counts AS (
  SELECT tenant_id, COUNT(*) AS active_collection_count
  FROM collections
  WHERE deleted_at IS NULL
  GROUP BY tenant_id
),
bundle_counts AS (
  SELECT tenant_id, COUNT(*) AS active_bundle_count
  FROM product_bundles
  WHERE is_active = true
  GROUP BY tenant_id
)
SELECT t.name AS merchant_name,
       t.industry AS industry,
       COALESCE(cc.active_collection_count,0) AS active_collection_count,
       {{divide_decimal(100.0 * COALESCE(pic.cnt,0), NULLIF(ap.active_product_count,0))}} AS pct_active_products_in_a_collection,
       COALESCE(bc.active_bundle_count,0) AS active_bundle_count,
       {{divide_decimal(100.0 * COALESCE(pib.cnt,0), NULLIF(ap.active_product_count,0))}} AS pct_active_products_in_a_bundle,
       tr.revenue_eur AS revenue_eur_last_12mo,
       {{divide_decimal(tr.revenue_eur, NULLIF(tr.orders_cnt,0))}} AS avg_order_value_eur_last_12mo
FROM tenant_revenue tr
JOIN tenants t ON t.id = tr.tenant_id
LEFT JOIN active_products ap ON ap.tenant_id = tr.tenant_id
LEFT JOIN products_in_collection pic ON pic.tenant_id = tr.tenant_id
LEFT JOIN products_in_bundle pib ON pib.tenant_id = tr.tenant_id
LEFT JOIN collection_counts cc ON cc.tenant_id = tr.tenant_id
LEFT JOIN bundle_counts bc ON bc.tenant_id = tr.tenant_id
ORDER BY revenue_eur_last_12mo DESC NULLS FIRST, merchant_name ASC NULLS LAST, t.id NULLS LAST
{{fetch_first(50)}}
