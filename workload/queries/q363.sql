SELECT
  CASE
    WHEN buckets.bucket_num = 1 THEN '1 item'
    WHEN buckets.bucket_num = 2 THEN '2 items'
    WHEN buckets.bucket_num = 3 THEN '3 items'
    WHEN buckets.bucket_num = 4 THEN '4 items'
    ELSE '5+ items'
  END AS item_count_bucket,
  COALESCE(disc.discounted_order_count, 0) AS discounted_order_count,
  disc.avg_subtotal_eur AS avg_discounted_subtotal_eur_pre_discount,
  COALESCE(nondisc.nondiscounted_order_count, 0) AS nondiscounted_order_count,
  nondisc.avg_subtotal_eur AS avg_nondiscounted_subtotal_eur,
  disc.avg_subtotal_eur - nondisc.avg_subtotal_eur AS lift_eur,
  100.0 * (disc.avg_subtotal_eur - nondisc.avg_subtotal_eur) / NULLIF(nondisc.avg_subtotal_eur, 0) AS lift_pct
FROM (SELECT 1 AS bucket_num UNION ALL SELECT 2 UNION ALL SELECT 3 UNION ALL SELECT 4 UNION ALL SELECT 5) buckets
LEFT JOIN (
  SELECT
    CASE WHEN item_count >= 5 THEN 5 ELSE item_count END AS bucket_num,
    COUNT(*) AS discounted_order_count,
    AVG(eur_subtotal) AS avg_subtotal_eur
  FROM (
    SELECT
      o.id AS id,
      (SELECT COUNT(*) FROM order_items oi WHERE oi.order_id = o.id) AS item_count,
      CASE WHEN o.currency_code = 'EUR' THEN o.subtotal
           ELSE {{divide_decimal(o.subtotal, (SELECT er.rate FROM exchange_rates er WHERE er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS DATE)))}}
      END AS eur_subtotal
    FROM orders o
    WHERE o.status <> 'cancelled'
      AND o.placed_at >= DATE '2025-01-01'
      AND o.placed_at < DATE '2026-01-01'
      AND EXISTS (
        SELECT 1
        FROM order_discounts od
        LEFT JOIN discounts d1 ON od.discount_id = d1.id
        LEFT JOIN coupons cp ON od.coupon_id = cp.id
        LEFT JOIN discounts d2 ON cp.discount_id = d2.id
        WHERE od.order_id = o.id
          AND COALESCE(d1.name, d2.name) IN ('Welcome 10% off', 'Black Friday 2025', 'January Sale 2025', 'Summer Sale 2025')
      )
  ) disc_orders
  GROUP BY CASE WHEN item_count >= 5 THEN 5 ELSE item_count END
) disc ON disc.bucket_num = buckets.bucket_num
LEFT JOIN (
  SELECT
    CASE WHEN item_count >= 5 THEN 5 ELSE item_count END AS bucket_num,
    COUNT(*) AS nondiscounted_order_count,
    AVG(eur_subtotal) AS avg_subtotal_eur
  FROM (
    SELECT
      o.id AS id,
      (SELECT COUNT(*) FROM order_items oi WHERE oi.order_id = o.id) AS item_count,
      CASE WHEN o.currency_code = 'EUR' THEN o.subtotal
           ELSE {{divide_decimal(o.subtotal, (SELECT er.rate FROM exchange_rates er WHERE er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS DATE)))}}
      END AS eur_subtotal
    FROM orders o
    WHERE o.status <> 'cancelled'
      AND o.placed_at >= DATE '2025-01-01'
      AND o.placed_at < DATE '2026-01-01'
      AND o.tenant_id IN (
        SELECT DISTINCT o2.tenant_id AS tenant_id
        FROM orders o2
        WHERE o2.status <> 'cancelled'
          AND o2.placed_at >= DATE '2025-01-01'
          AND o2.placed_at < DATE '2026-01-01'
          AND EXISTS (
            SELECT 1
            FROM order_discounts od2
            LEFT JOIN discounts d1b ON od2.discount_id = d1b.id
            LEFT JOIN coupons cp2 ON od2.coupon_id = cp2.id
            LEFT JOIN discounts d2b ON cp2.discount_id = d2b.id
            WHERE od2.order_id = o2.id
              AND COALESCE(d1b.name, d2b.name) IN ('Welcome 10% off', 'Black Friday 2025', 'January Sale 2025', 'Summer Sale 2025')
          )
      )
      AND NOT EXISTS (
        SELECT 1 FROM order_discounts od3 WHERE od3.order_id = o.id
      )
  ) nondisc_orders
  GROUP BY CASE WHEN item_count >= 5 THEN 5 ELSE item_count END
) nondisc ON nondisc.bucket_num = buckets.bucket_num
ORDER BY buckets.bucket_num NULLS LAST
