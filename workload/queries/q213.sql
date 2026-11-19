WITH shipment_costs AS (
  SELECT o.tenant_id AS tenant_id,
         COUNT(*) AS shipment_count,
         SUM(CAST({{divide_decimal(s.shipping_cost, er.rate)}} AS NUMERIC(18,6))) AS shipping_cost_eur
  FROM shipments s
  JOIN fulfillments f ON f.id = s.fulfillment_id
  JOIN orders o ON o.id = f.order_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = s.currency_code
   AND er.as_of = CAST(s.shipped_at AS date)
  WHERE s.shipped_at >= DATE '2025-01-01' AND s.shipped_at < DATE '2026-01-01'
  GROUP BY o.tenant_id
),
returns_counts AS (
  SELECT o.tenant_id AS tenant_id, COUNT(*) AS return_count
  FROM order_returns r
  JOIN orders o ON o.id = r.order_id
  WHERE r.requested_at >= DATE '2025-01-01' AND r.requested_at < DATE '2026-01-01'
  GROUP BY o.tenant_id
),
refund_amounts AS (
  SELECT pr.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(pr.amount, er.rate)}} AS NUMERIC(18,6))) AS refund_amount_eur
  FROM payment_refunds pr
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = pr.currency_code
   AND er.as_of = CAST(pr.processed_at AS date)
  WHERE pr.status = 'succeeded'
    AND pr.processed_at >= DATE '2025-01-01' AND pr.processed_at < DATE '2026-01-01'
  GROUP BY pr.tenant_id
),
ticket_counts AS (
  SELECT tenant_id, COUNT(*) AS ticket_count
  FROM tickets
  WHERE created_at >= DATE '2025-01-01' AND created_at < DATE '2026-01-01'
  GROUP BY tenant_id
),
failed_webhooks AS (
  SELECT w.tenant_id AS tenant_id, COUNT(*) AS failed_webhook_count
  FROM webhook_deliveries wd
  JOIN webhooks w ON w.id = wd.webhook_id
  WHERE wd.status = 'failed'
    AND wd.created_at >= DATE '2025-01-01' AND wd.created_at < DATE '2026-01-01'
  GROUP BY w.tenant_id
)
SELECT
  t.name AS merchant_name,
  t.industry AS vertical,
  COALESCE(sc.shipment_count, 0) AS shipment_count_2025,
  COALESCE(sc.shipping_cost_eur, 0) AS total_shipping_cost_eur_2025,
  COALESCE(rc.return_count, 0) AS return_count_2025,
  COALESCE(ra.refund_amount_eur, 0) AS refund_amount_eur_2025,
  COALESCE(tc.ticket_count, 0) AS ticket_count_2025,
  COALESCE(fw.failed_webhook_count, 0) AS failed_webhook_count_2025
FROM tenants t
LEFT JOIN shipment_costs sc ON sc.tenant_id = t.id
LEFT JOIN returns_counts rc ON rc.tenant_id = t.id
LEFT JOIN refund_amounts ra ON ra.tenant_id = t.id
LEFT JOIN ticket_counts tc ON tc.tenant_id = t.id
LEFT JOIN failed_webhooks fw ON fw.tenant_id = t.id
ORDER BY total_shipping_cost_eur_2025 DESC NULLS FIRST, merchant_name ASC NULLS LAST, t.id NULLS LAST
{{fetch_first(50)}}
