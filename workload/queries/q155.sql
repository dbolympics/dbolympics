SELECT
  d.name AS discount_name,
  COALESCE(cc.coupon_code, 'automatic') AS coupon_code,
  disc.order_count AS discounted_order_count,
  disc.customer_count AS distinct_customers,
  disc.avg_subtotal_eur AS avg_discounted_subtotal_eur,
  cmp.avg_subtotal_eur AS avg_comparison_subtotal_eur,
  disc.avg_subtotal_eur - cmp.avg_subtotal_eur AS subtotal_lift_eur,
  CASE WHEN cmp.avg_subtotal_eur IS NULL OR cmp.avg_subtotal_eur = 0 THEN NULL
       ELSE (disc.avg_subtotal_eur - cmp.avg_subtotal_eur) * 100 / cmp.avg_subtotal_eur END AS subtotal_lift_pct,
  CASE WHEN disc.customer_count = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * cmp.customers_with_comparison, disc.customer_count)}} END AS pct_customers_with_comparison_order,
  (disc.customer_count - cmp.customers_with_comparison) AS customers_with_no_comparison_order
FROM discounts d
JOIN (
  SELECT dconv.discount_id AS discount_id,
         COUNT(*) AS order_count,
         COUNT(DISTINCT dconv.user_id) AS customer_count,
         AVG(dconv.subtotal_eur) AS avg_subtotal_eur
  FROM (
    SELECT DISTINCT od.discount_id AS discount_id, o.id AS order_id, o.user_id AS user_id,
           CASE WHEN o.currency_code = 'EUR' THEN CAST(o.subtotal AS NUMERIC(18,6)) ELSE CAST({{divide_decimal(o.subtotal, er.rate)}} AS NUMERIC(18,6)) END AS subtotal_eur
    FROM order_discounts od
    JOIN orders o ON o.id = od.order_id AND o.tenant_id = od.tenant_id
    LEFT JOIN exchange_rates er ON er.base_code = 'EUR'
           AND er.quote_code = o.currency_code
           AND er.as_of = CAST(o.placed_at AS date)
    WHERE o.status <> 'cancelled'
      AND o.placed_at >= DATE '2025-01-01'
      AND o.placed_at < DATE '2026-01-01'
      AND od.discount_id IN (
        SELECT id FROM discounts
        WHERE name IN ('Welcome 10% off', 'Black Friday 2025', 'January Sale 2025', 'Summer Sale 2025')
      )
  ) dconv
  GROUP BY dconv.discount_id
) disc ON disc.discount_id = d.id
JOIN (
  SELECT dcust.discount_id AS discount_id,
         COUNT(cp.user_id) AS customers_with_comparison,
         {{divide_decimal(SUM(cp.cmp_subtotal_sum), NULLIF(SUM(cp.cmp_order_count), 0))}} AS avg_subtotal_eur
  FROM (
    SELECT DISTINCT od.discount_id AS discount_id, o.tenant_id AS tenant_id, o.user_id AS user_id
    FROM order_discounts od
    JOIN orders o ON o.id = od.order_id AND o.tenant_id = od.tenant_id
    WHERE o.status <> 'cancelled'
      AND o.placed_at >= DATE '2025-01-01'
      AND o.placed_at < DATE '2026-01-01'
      AND od.discount_id IN (
        SELECT id FROM discounts
        WHERE name IN ('Welcome 10% off', 'Black Friday 2025', 'January Sale 2025', 'Summer Sale 2025')
      )
  ) dcust
  LEFT JOIN (
    SELECT o2.tenant_id AS tenant_id, o2.user_id AS user_id,
           COUNT(*) AS cmp_order_count,
           SUM(CASE WHEN o2.currency_code = 'EUR' THEN CAST(o2.subtotal AS NUMERIC(18,6)) ELSE CAST({{divide_decimal(o2.subtotal, er2.rate)}} AS NUMERIC(18,6)) END) AS cmp_subtotal_sum
    FROM orders o2
    LEFT JOIN exchange_rates er2 ON er2.base_code = 'EUR'
           AND er2.quote_code = o2.currency_code
           AND er2.as_of = CAST(o2.placed_at AS date)
    WHERE o2.status <> 'cancelled'
      AND o2.placed_at >= DATE '2025-01-01'
      AND o2.placed_at < DATE '2026-01-01'
      AND NOT EXISTS (
        SELECT 1 FROM order_discounts od2 WHERE od2.order_id = o2.id
      )
    GROUP BY o2.tenant_id, o2.user_id
  ) cp ON cp.tenant_id = dcust.tenant_id AND cp.user_id = dcust.user_id
  GROUP BY dcust.discount_id
) cmp ON cmp.discount_id = d.id
LEFT JOIN (
  SELECT discount_id, {{string_agg_distinct_sorted(code, ', ')}} AS coupon_code
  FROM order_discounts
  WHERE code IS NOT NULL
  GROUP BY discount_id
) cc ON cc.discount_id = d.id
WHERE d.name IN ('Welcome 10% off', 'Black Friday 2025', 'January Sale 2025', 'Summer Sale 2025')
ORDER BY subtotal_lift_pct ASC NULLS LAST, discount_name ASC NULLS LAST, d.id ASC NULLS LAST
