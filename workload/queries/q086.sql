SELECT
  delivery_bucket,
  MAX(bucket_shipment_count) AS shipments_count,
  COUNT(*) AS distinct_customers,
  100.0 * SUM(CASE WHEN min_days_to_next IS NOT NULL THEN 1 ELSE 0 END) / COUNT(*) AS pct_customers_with_next_order,
  {{percentile_cont_filter(0.5, min_days_to_next, min_days_to_next IS NOT NULL)}} AS median_days_to_next_order
FROM (
  SELECT
    tenant_id,
    user_id,
    delivery_bucket,
    MIN(days_to_next) AS min_days_to_next,
    MAX(bucket_shipment_count) AS bucket_shipment_count
  FROM (
    SELECT
      tenant_id,
      user_id,
      delivery_bucket,
      {{seconds_between(delivered_at, next_order_at)}} / 86400.0 AS days_to_next,
      COUNT(*) OVER (PARTITION BY delivery_bucket) AS bucket_shipment_count
    FROM (
      SELECT
        o.tenant_id AS tenant_id,
        o.user_id AS user_id,
        CASE WHEN s.delivered_at <= s.shipped_at + INTERVAL '7' DAY THEN 'on-time' ELSE 'late' END AS delivery_bucket,
        s.delivered_at AS delivered_at,
        (
          SELECT MIN(o2.placed_at)
          FROM orders o2
          WHERE o2.tenant_id = o.tenant_id
            AND o2.user_id = o.user_id
            AND o2.placed_at > s.delivered_at
            AND o2.placed_at <= s.delivered_at + INTERVAL '90 days'
        ) AS next_order_at
      FROM shipments s
      JOIN fulfillments f ON f.id = s.fulfillment_id
      JOIN orders o ON o.id = f.order_id
      JOIN tenants t ON t.id = o.tenant_id
      WHERE t.name IN (
          'Kibblewick', 'Studio Vrij', 'Petalcourt Beauty',
          'Marrowby & Vane', 'Cragsley Outfitters', 'Ampfeld Elektronik'
        )
        AND s.delivered_at >= DATE '2025-09-01'
        AND s.delivered_at < DATE '2025-10-01'
        AND s.shipped_at IS NOT NULL
    ) shipment_level
  ) days_level
  GROUP BY tenant_id, user_id, delivery_bucket
) customer_level
GROUP BY delivery_bucket
ORDER BY CASE WHEN delivery_bucket = 'on-time' THEN 0 ELSE 1 END NULLS LAST, delivery_bucket NULLS LAST
