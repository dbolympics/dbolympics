WITH sales AS (
  SELECT
    c.name AS category_name,
    SUM(oi.quantity) AS units_sold
  FROM order_items oi
  JOIN orders o ON o.id = oi.order_id
  JOIN product_variants pv ON pv.id = oi.product_variant_id
  JOIN products p ON p.id = pv.product_id
  JOIN categories c ON c.id = p.primary_category_id
  JOIN tenants t ON t.id = p.tenant_id
  WHERE t.industry = 'Home & Living'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
  GROUP BY c.name
),
returns AS (
  SELECT
    c.name AS category_name,
    COUNT(*) AS return_count,
    SUM(CASE
          WHEN LOWER(orr.reason) LIKE '%damage%'
            OR LOWER(orr.reason) LIKE '%broken%'
            OR LOWER(orr.reason) LIKE '%crack%'
            OR LOWER(orr.reason) LIKE '%chip%'
            OR LOWER(orr.reason) LIKE '%shattered%'
          THEN 1 ELSE 0
        END) AS damage_count
  FROM return_items ri
  JOIN order_returns orr ON orr.id = ri.return_id
  JOIN order_items oi ON oi.id = ri.order_item_id
  JOIN product_variants pv ON pv.id = oi.product_variant_id
  JOIN products p ON p.id = pv.product_id
  JOIN categories c ON c.id = p.primary_category_id
  JOIN tenants t ON t.id = p.tenant_id
  WHERE t.industry = 'Home & Living'
    AND orr.requested_at >= DATE '2025-01-01'
    AND orr.requested_at < DATE '2026-01-01'
  GROUP BY c.name
)
SELECT
  s.category_name AS category_name,
  s.units_sold AS units_sold_last_12mo,
  COALESCE(r.return_count, 0) AS return_count,
  {{divide_decimal(COALESCE(r.return_count, 0) * 100.0, NULLIF(s.units_sold, 0))}} AS return_rate_pct,
  {{divide_decimal(COALESCE(r.damage_count, 0) * 100.0, NULLIF(r.return_count, 0))}} AS pct_returns_damage_related
FROM sales s
LEFT JOIN returns r ON r.category_name = s.category_name
ORDER BY return_rate_pct DESC NULLS LAST, s.category_name ASC NULLS LAST
