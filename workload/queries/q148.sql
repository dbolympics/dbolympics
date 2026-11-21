WITH fod AS (
  SELECT
    od.id AS od_id,
    od.tenant_id AS tenant_id,
    od.order_id AS order_id,
    od.discount_id AS discount_id,
    od.coupon_id AS coupon_id,
    od.amount AS discount_amount_local,
    od.currency_code AS discount_currency_code,
    o.grand_total AS order_grand_total_local,
    o.currency_code AS order_currency_code,
    o.user_id AS user_id,
    o.placed_at AS placed_at,
    CAST(o.placed_at AS date) AS placed_date
  FROM order_discounts od
  JOIN orders o
    ON o.id = od.order_id
   AND o.tenant_id = od.tenant_id
  WHERE od.discount_id IS NOT NULL
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
    AND o.status <> 'cancelled'
),
discount_base AS (
  SELECT DISTINCT discount_id FROM fod
),
coupon_codes AS (
  SELECT DISTINCT fod.discount_id AS discount_id, c.code AS code
  FROM fod
  JOIN coupons c
    ON c.id = fod.coupon_id
   AND c.tenant_id = fod.tenant_id
  WHERE fod.coupon_id IS NOT NULL
),
coupon_codes_agg AS (
  SELECT
    cc.discount_id AS discount_id,
    {{string_agg_sorted(cc.code, ', ')}} AS coupon_codes
  FROM coupon_codes cc
  GROUP BY cc.discount_id
),
m_discount_amount AS (
  SELECT
    fod.discount_id AS discount_id,
    SUM(CAST({{divide_decimal(fod.discount_amount_local, fxd.rate)}} AS NUMERIC(18,6))) AS discount_amount_eur
  FROM fod
  JOIN exchange_rates fxd
    ON fxd.base_code = 'EUR'
   AND fxd.quote_code = fod.discount_currency_code
   AND fxd.as_of = fod.placed_date
  GROUP BY fod.discount_id
),
m_orders AS (
  SELECT
    fod.discount_id AS discount_id,
    COUNT(DISTINCT fod.order_id) AS order_count,
    COUNT(DISTINCT fod.user_id) AS distinct_customers,
    MIN(fod.placed_at) AS first_order_date,
    MAX(fod.placed_at) AS last_order_date
  FROM fod
  GROUP BY fod.discount_id
),
distinct_orders AS (
  SELECT DISTINCT
    discount_id,
    order_id,
    order_grand_total_local,
    order_currency_code,
    placed_date
  FROM fod
),
m_revenue AS (
  SELECT
    do1.discount_id AS discount_id,
    SUM(CAST({{divide_decimal(do1.order_grand_total_local, fxo.rate)}} AS NUMERIC(18,6))) AS revenue_eur
  FROM distinct_orders do1
  JOIN exchange_rates fxo
    ON fxo.base_code = 'EUR'
   AND fxo.quote_code = do1.order_currency_code
   AND fxo.as_of = do1.placed_date
  GROUP BY do1.discount_id
)
SELECT
  d.name AS discount_name,
  d.kind AS discount_kind,
  COALESCE(cca.coupon_codes, 'automatic') AS coupon_codes,
  COALESCE(mda.discount_amount_eur, 0) AS discount_amount_eur,
  COALESCE(mo.order_count, 0) AS order_count,
  COALESCE(mr.revenue_eur, 0) AS order_revenue_eur,
  CASE WHEN COALESCE(mr.revenue_eur, 0) = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * COALESCE(mda.discount_amount_eur, 0), mr.revenue_eur)}}
  END AS discount_pct_of_revenue,
  COALESCE(mo.distinct_customers, 0) AS distinct_customers,
  mo.first_order_date AS first_order_date,
  mo.last_order_date AS last_order_date
FROM discount_base db
JOIN discounts d ON d.id = db.discount_id
LEFT JOIN coupon_codes_agg cca ON cca.discount_id = db.discount_id
LEFT JOIN m_discount_amount mda ON mda.discount_id = db.discount_id
LEFT JOIN m_orders mo ON mo.discount_id = db.discount_id
LEFT JOIN m_revenue mr ON mr.discount_id = db.discount_id
ORDER BY discount_amount_eur DESC NULLS FIRST, d.name ASC NULLS LAST, d.id ASC NULLS LAST
