WITH order_rev AS (
  SELECT
    COALESCE(NULLIF(t.industry, ''), 'Unspecified') AS vertical,
    COUNT(*) AS order_count,
    SUM(CAST({{divide_decimal(o.shipping_total, er.rate)}} AS NUMERIC(18,6))) AS shipping_revenue_eur
  FROM orders o
  JOIN tenants t ON t.id = o.tenant_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.status IN ('paid', 'partially_fulfilled', 'fulfilled', 'refunded')
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
  GROUP BY 1
),
ship_cost AS (
  SELECT
    COALESCE(NULLIF(t.industry, ''), 'Unspecified') AS vertical,
    SUM(CAST({{divide_decimal(s.shipping_cost, er.rate)}} AS NUMERIC(18,6))) AS shipping_cost_eur
  FROM shipments s
  JOIN fulfillments f ON f.id = s.fulfillment_id
  JOIN orders o ON o.id = f.order_id
  JOIN tenants t ON t.id = o.tenant_id
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = s.currency_code
   AND er.as_of = CAST(s.shipped_at AS date)
  WHERE s.shipped_at >= DATE '2025-01-01'
    AND s.shipped_at < DATE '2026-01-01'
  GROUP BY 1
)
SELECT
  COALESCE(r.vertical, c.vertical) AS vertical,
  COALESCE(r.order_count, 0) AS order_count,
  COALESCE(r.shipping_revenue_eur, 0) AS shipping_revenue_eur,
  COALESCE(c.shipping_cost_eur, 0) AS shipping_cost_eur,
  COALESCE(r.shipping_revenue_eur, 0) - COALESCE(c.shipping_cost_eur, 0) AS shipping_margin_eur,
  CASE WHEN COALESCE(r.shipping_revenue_eur, 0) <> 0
    THEN {{divide_decimal((COALESCE(r.shipping_revenue_eur, 0) - COALESCE(c.shipping_cost_eur, 0)), r.shipping_revenue_eur)}} * 100
    ELSE NULL
  END AS shipping_margin_pct
FROM order_rev r
FULL OUTER JOIN ship_cost c ON r.vertical = c.vertical
ORDER BY shipping_margin_eur ASC NULLS LAST, vertical ASC NULLS LAST
