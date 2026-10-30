WITH months AS (
  SELECT DISTINCT month_start, month_label FROM calendar_days WHERE month_start BETWEEN DATE '2025-07-01' AND DATE '2025-12-01'
),
tenants_filtered AS (
  SELECT id AS tenant_id, name AS merchant_name FROM tenants WHERE name IN ('Fennel & Flint','Wiesgrund Wohnen')
),
base AS (
  SELECT t.tenant_id AS tenant_id, t.merchant_name AS merchant_name, m.month_start AS month_start, m.month_label AS month_label
  FROM tenants_filtered t CROSS JOIN months m
),
reviews AS (
  SELECT tenant_id,
    CAST({{date_trunc('month', created_at)}} AS date) AS month_start,
    COUNT(*) AS review_count,
    AVG(CAST(rating AS NUMERIC(18,6))) AS avg_rating,
    SUM(CASE WHEN rating IN (1,2) THEN 1 ELSE 0 END) AS cnt_low
  FROM product_reviews
  WHERE is_approved = true
    AND tenant_id IN (SELECT tenant_id FROM tenants_filtered)
    AND created_at >= DATE '2025-07-01' AND created_at < DATE '2026-01-01'
  GROUP BY tenant_id, CAST({{date_trunc('month', created_at)}} AS date)
),
ship AS (
  SELECT o.tenant_id AS tenant_id,
    CAST({{date_trunc('month', s.shipped_at)}} AS date) AS month_start,
    COUNT(*) AS shipments_count,
    SUM(CASE WHEN s.delivered_at IS NOT NULL AND s.delivered_at <= s.shipped_at + INTERVAL '5 days' THEN 1 ELSE 0 END) AS delivered_within_5,
    SUM(CASE WHEN s.delivered_at IS NOT NULL THEN 1 ELSE 0 END) AS delivered_known,
    SUM(CASE WHEN s.carrier = 'Albion Parcel' THEN 1 ELSE 0 END) AS albion_count
  FROM shipments s
  JOIN fulfillments f ON f.id = s.fulfillment_id
  JOIN orders o ON o.id = f.order_id
  WHERE o.tenant_id IN (SELECT tenant_id FROM tenants_filtered)
    AND s.shipped_at >= DATE '2025-07-01' AND s.shipped_at < DATE '2026-01-01'
  GROUP BY o.tenant_id, CAST({{date_trunc('month', s.shipped_at)}} AS date)
)
SELECT
  b.merchant_name AS merchant_name,
  b.month_label AS month,
  COALESCE(r.review_count,0) AS review_count,
  r.avg_rating AS avg_rating,
  CASE WHEN r.review_count > 0 THEN CAST(r.cnt_low AS numeric(18,6)) / r.review_count * 100 ELSE NULL END AS pct_1_2_star,
  COALESCE(sh.shipments_count,0) AS shipments_count,
  CASE WHEN sh.delivered_known > 0 THEN CAST(sh.delivered_within_5 AS numeric(18,6)) / sh.delivered_known * 100 ELSE NULL END AS pct_delivered_within_5_days,
  CASE WHEN sh.shipments_count > 0 THEN CAST(sh.albion_count AS numeric(18,6)) / sh.shipments_count * 100 ELSE NULL END AS pct_shipped_via_albion_parcel
FROM base b
LEFT JOIN reviews r ON r.tenant_id = b.tenant_id AND r.month_start = b.month_start
LEFT JOIN ship sh ON sh.tenant_id = b.tenant_id AND sh.month_start = b.month_start
ORDER BY b.merchant_name NULLS LAST, b.month_start NULLS LAST, b.tenant_id NULLS LAST, b.month_label NULLS LAST
