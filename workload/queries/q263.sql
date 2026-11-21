SELECT
  industry,
  attribution_status,
  orders_count,
  share_of_industry_orders_pct,
  new_customer_order_pct,
  avg_order_value_eur
FROM (
  SELECT
    industry,
    attribution_status,
    COUNT(*) AS orders_count,
    {{divide_decimal(COUNT(*) * 100.0, SUM(COUNT(*)) OVER (PARTITION BY industry))}} AS share_of_industry_orders_pct,
    {{divide_decimal(100.0 * SUM(is_new), COUNT(*))}} AS new_customer_order_pct,
    AVG(amount_eur) AS avg_order_value_eur
  FROM (
    SELECT
      t.industry AS industry,
      CASE WHEN EXISTS (
        SELECT 1 FROM attributions a WHERE a.order_id = o.id
      ) THEN 'attributed' ELSE 'unattributed' END AS attribution_status,
      CASE WHEN o.placed_at = (
        SELECT MIN(o3.placed_at)
        FROM orders o3
        WHERE o3.tenant_id = o.tenant_id
          AND o3.user_id = o.user_id
          AND o3.placed_at IS NOT NULL
      ) THEN 1 ELSE 0 END AS is_new,
      CASE WHEN o.currency_code = 'EUR' THEN o.grand_total
           ELSE {{divide_decimal(o.grand_total, (
             SELECT er.rate FROM exchange_rates er
             WHERE er.base_code = 'EUR' AND er.quote_code = o.currency_code
               AND er.as_of = CAST(o.placed_at AS DATE)
           ))}}
      END AS amount_eur
    FROM orders o
    JOIN tenants t ON t.id = o.tenant_id
    WHERE o.placed_at >= TIMESTAMP '2025-01-01'
      AND o.placed_at < TIMESTAMP '2026-01-01'
  ) base
  GROUP BY industry, attribution_status
) agg
ORDER BY industry ASC NULLS LAST, attribution_status ASC NULLS LAST
