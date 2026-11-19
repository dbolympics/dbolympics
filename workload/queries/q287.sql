WITH tenant_filter AS (
  SELECT id FROM tenants WHERE name IN ('Kibblewick','Studio Vrij','Petalcourt Beauty','Marrowby & Vane','Cragsley Outfitters','Ampfeld Elektronik')
),
cart_base AS (
  SELECT c.id AS id, c.tenant_id AS tenant_id, c.status AS status, c.item_count AS item_count, c.subtotal AS subtotal, c.currency_code AS currency_code, c.created_at AS created_at,
         coalesce(c.converted_at, c.abandoned_at, c.expires_at) AS resolved_at,
         er.rate AS eur_rate
  FROM carts c
  JOIN tenant_filter tf ON tf.id = c.tenant_id
  LEFT JOIN exchange_rates er ON er.base_code='EUR' AND er.quote_code = c.currency_code AND er.as_of = CAST(c.created_at AS date)
  WHERE c.created_at >= DATE '2025-01-01' AND c.created_at < DATE '2026-01-01'
),
cart_calc AS (
  SELECT *,
    CASE WHEN currency_code='EUR' THEN subtotal ELSE CAST({{divide_decimal(subtotal, NULLIF(eur_rate,0))}} AS NUMERIC(18,6)) END AS subtotal_eur,
    CASE WHEN resolved_at IS NULL THEN NULL ELSE {{divide_decimal({{seconds_between(created_at, resolved_at)}}, 3600.0)}} END AS resolution_hours
  FROM cart_base
),
bucketed AS (
  SELECT *,
    CASE
      WHEN resolution_hours IS NULL THEN 'unresolved/still active'
      WHEN resolution_hours < 1 THEN '<1 hour'
      WHEN resolution_hours < 24 THEN '1-24 hours'
      WHEN resolution_hours < 168 THEN '1-7 days'
      ELSE '>7 days'
    END AS duration_bucket
  FROM cart_calc
),
order_discount_flag AS (
  SELECT o.cart_id AS cart_id, CASE WHEN EXISTS (SELECT 1 FROM order_discounts od WHERE od.order_id = o.id) THEN 1 ELSE 0 END AS has_discount
  FROM orders o
  WHERE o.cart_id IS NOT NULL
)
SELECT
  b.duration_bucket AS duration_bucket,
  COUNT(*) AS cart_count,
  AVG(CAST(b.item_count AS NUMERIC(18,6))) AS avg_item_count,
  AVG(b.subtotal_eur) AS avg_subtotal_eur,
  {{percentile_cont(0.5, b.subtotal_eur)}} AS median_subtotal_eur,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE b.status='converted'), COUNT(*))}} AS pct_converted,
  {{divide_decimal(100.0 * COUNT(*) FILTER (WHERE b.status='converted' AND odf.has_discount=1), NULLIF(COUNT(*) FILTER (WHERE b.status='converted'),0))}} AS pct_converted_with_discount
FROM bucketed b
LEFT JOIN order_discount_flag odf ON odf.cart_id = b.id
GROUP BY b.duration_bucket
ORDER BY CASE b.duration_bucket
  WHEN '<1 hour' THEN 1
  WHEN '1-24 hours' THEN 2
  WHEN '1-7 days' THEN 3
  WHEN '>7 days' THEN 4
  WHEN 'unresolved/still active' THEN 5
END NULLS LAST
