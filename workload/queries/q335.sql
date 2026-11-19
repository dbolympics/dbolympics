WITH sync_webhooks AS (
  SELECT id, tenant_id
  FROM webhooks
  WHERE lower(name) LIKE '%erp%sync%'
     OR lower(name) LIKE '%wms%sync%'
     OR lower(name) LIKE '%accounting%sync%'
),
distinct_sync_tenants AS (
  SELECT DISTINCT tenant_id FROM sync_webhooks
),
sync_deliveries_2025 AS (
  SELECT wd.tenant_id AS tenant_id, wd.status AS status
  FROM webhook_deliveries wd
  JOIN sync_webhooks sw ON sw.id = wd.webhook_id
  WHERE wd.created_at >= DATE '2025-01-01' AND wd.created_at < DATE '2026-01-01'
),
delivery_stats AS (
  SELECT
    tenant_id,
    COUNT(*) AS total_sync_deliveries_2025,
    {{divide_decimal(100.0 * SUM(CASE WHEN status = 'success' THEN 1 ELSE 0 END), COUNT(*))}} AS success_rate_pct,
    {{divide_decimal(100.0 * SUM(CASE WHEN status IN ('pending','retrying') THEN 1 ELSE 0 END), COUNT(*))}} AS pending_or_retrying_rate_pct
  FROM sync_deliveries_2025
  GROUP BY tenant_id
),
order_eur_amounts AS (
  SELECT
    o.tenant_id AS tenant_id,
    o.id AS order_id,
    CASE WHEN o.currency_code = 'EUR' THEN o.grand_total
         ELSE CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) END AS revenue_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.placed_at >= DATE '2025-01-01' AND o.placed_at < DATE '2026-01-01'
),
tenant_revenue_all AS (
  SELECT
    tenant_id,
    COUNT(*) AS total_orders_2025,
    SUM(revenue_eur) AS total_revenue_eur_2025
  FROM order_eur_amounts
  GROUP BY tenant_id
),
revenue_ranked AS (
  SELECT
    tenant_id,
    total_orders_2025,
    total_revenue_eur_2025,
    DENSE_RANK() OVER (ORDER BY total_revenue_eur_2025 DESC NULLS FIRST) AS revenue_rank
  FROM tenant_revenue_all
)
SELECT
  t.name AS tenant_name,
  COALESCE(ds.total_sync_deliveries_2025, 0) AS total_sync_deliveries_2025,
  ds.success_rate_pct AS success_rate_pct,
  ds.pending_or_retrying_rate_pct AS pending_or_retrying_rate_pct,
  COALESCE(rr.total_orders_2025, 0) AS total_orders_2025,
  rr.total_revenue_eur_2025 AS total_revenue_eur_2025,
  rr.revenue_rank AS revenue_rank
FROM distinct_sync_tenants dst
JOIN tenants t ON t.id = dst.tenant_id
LEFT JOIN delivery_stats ds ON ds.tenant_id = dst.tenant_id
LEFT JOIN revenue_ranked rr ON rr.tenant_id = dst.tenant_id
ORDER BY ds.pending_or_retrying_rate_pct DESC NULLS LAST, t.name ASC NULLS LAST, t.id NULLS LAST
