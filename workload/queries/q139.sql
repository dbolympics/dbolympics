WITH apparel_tenants AS (
    SELECT id AS tenant_id
    FROM tenants
    WHERE industry = 'Apparel & Footwear'
),
base_products AS (
    SELECT p.id AS product_id,
           p.tenant_id AS tenant_id,
           p.description AS description
    FROM products p
    JOIN apparel_tenants t ON t.tenant_id = p.tenant_id
    WHERE p.status = 'active'
      AND p.deleted_at IS NULL
),
image_counts AS (
    SELECT bp.product_id AS product_id,
           COUNT(pm.id) AS image_count
    FROM base_products bp
    LEFT JOIN product_media pm
           ON pm.product_id = bp.product_id
          AND pm.kind = 'image'
    GROUP BY bp.product_id
),
variant_counts AS (
    SELECT bp.product_id AS product_id,
           COUNT(pv.id) AS variant_count
    FROM base_products bp
    LEFT JOIN product_variants pv
           ON pv.product_id = bp.product_id
          AND pv.deleted_at IS NULL
    GROUP BY bp.product_id
),
review_stats AS (
    SELECT bp.product_id AS product_id,
           COUNT(pr.id) AS review_count,
           AVG(CAST(pr.rating AS numeric(18,6))) AS avg_rating_for_product
    FROM base_products bp
    LEFT JOIN product_reviews pr
           ON pr.product_id = bp.product_id
          AND pr.is_approved = true
    GROUP BY bp.product_id
),
order_items_in_window AS (
    SELECT oi.product_variant_id AS product_variant_id,
           oi.quantity AS quantity,
           oi.line_total AS line_total,
           oi.currency_code AS currency_code,
           o.placed_at AS placed_at
    FROM order_items oi
    JOIN orders o ON o.id = oi.order_id
    WHERE o.placed_at >= TIMESTAMP '2025-01-01'
      AND o.placed_at < TIMESTAMP '2026-01-01'
      AND o.status <> 'cancelled'
),
order_items_eur AS (
    SELECT oiw.product_variant_id AS product_variant_id,
           oiw.quantity AS quantity,
           CAST({{divide_decimal(oiw.line_total, er.rate)}} AS NUMERIC(18,6)) AS line_total_eur
    FROM order_items_in_window oiw
    JOIN exchange_rates er
           ON er.base_code = 'EUR'
          AND er.quote_code = oiw.currency_code
          AND er.as_of = CAST(oiw.placed_at AS date)
),
variant_product_map AS (
    SELECT pv.id AS variant_id,
           pv.product_id AS product_id
    FROM product_variants pv
    JOIN base_products bp ON bp.product_id = pv.product_id
),
product_sales AS (
    SELECT vpm.product_id AS product_id,
           SUM(oie.quantity) AS units_sold,
           SUM(oie.line_total_eur) AS revenue_eur
    FROM variant_product_map vpm
    JOIN order_items_eur oie ON oie.product_variant_id = vpm.variant_id
    GROUP BY vpm.product_id
),
product_metrics AS (
    SELECT
        bp.product_id AS product_id,
        CASE
            WHEN ic.image_count = 0 THEN '0'
            WHEN ic.image_count = 1 THEN '1'
            WHEN ic.image_count BETWEEN 2 AND 3 THEN '2-3'
            WHEN ic.image_count BETWEEN 4 AND 6 THEN '4-6'
            ELSE '7+'
        END AS image_count_bucket,
        CASE WHEN bp.description IS NOT NULL AND bp.description <> '' THEN 1 ELSE 0 END AS has_description,
        COALESCE(vc.variant_count, 0) AS variant_count,
        COALESCE(rs.review_count, 0) AS review_count,
        rs.avg_rating_for_product AS avg_rating_for_product,
        COALESCE(ps.units_sold, 0) AS units_sold,
        COALESCE(ps.revenue_eur, 0) AS revenue_eur
    FROM base_products bp
    JOIN image_counts ic ON ic.product_id = bp.product_id
    LEFT JOIN variant_counts vc ON vc.product_id = bp.product_id
    LEFT JOIN review_stats rs ON rs.product_id = bp.product_id
    LEFT JOIN product_sales ps ON ps.product_id = bp.product_id
)
SELECT
    image_count_bucket,
    COUNT(*) AS product_count,
    {{divide_decimal(100.0 * SUM(has_description), COUNT(*))}} AS pct_with_description,
    AVG(CAST(variant_count AS NUMERIC(18,6))) AS avg_variants_per_product,
    AVG(CAST(review_count AS NUMERIC(18,6))) AS avg_reviews_per_product,
    AVG(avg_rating_for_product) FILTER (WHERE review_count > 0) AS avg_rating,
    AVG(CAST(units_sold AS NUMERIC(18,6))) AS avg_units_sold_per_product_last_12mo,
    AVG(revenue_eur) AS avg_revenue_per_product_eur_last_12mo
FROM product_metrics
GROUP BY image_count_bucket
ORDER BY
    CASE image_count_bucket
        WHEN '0' THEN 1
        WHEN '1' THEN 2
        WHEN '2-3' THEN 3
        WHEN '4-6' THEN 4
        WHEN '7+' THEN 5
    END NULLS LAST
