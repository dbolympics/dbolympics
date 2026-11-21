WITH tenant_base AS (
  SELECT t.id AS tenant_id, t.name AS merchant_name, t.industry AS vertical, t.status AS tenant_status, t.created_at AS created_at
  FROM tenants t
  WHERE t.status IN ('past_due','suspended','churned') AND t.deleted_at IS NULL
),
last_order AS (
  SELECT tenant_id, MAX(placed_at) AS last_order_at
  FROM orders
  GROUP BY tenant_id
),
last_paid_payout AS (
  SELECT tenant_id, MAX(paid_at) AS last_paid_payout_at
  FROM payouts
  WHERE status = 'paid'
  GROUP BY tenant_id
),
fee_revenue_ttm AS (
  SELECT p.tenant_id AS tenant_id,
         SUM(CASE WHEN p.currency_code = 'EUR' THEN CAST(p.fee_amount AS NUMERIC(18,6)) ELSE CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6)) END) AS fee_revenue_eur
  FROM payouts p
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.paid_at AS date)
  WHERE p.status = 'paid'
    AND p.paid_at >= DATE '2025-01-01'
    AND p.paid_at < DATE '2026-01-01'
  GROUP BY p.tenant_id
)
SELECT
  tb.merchant_name AS merchant_name,
  tb.vertical AS vertical,
  tb.tenant_status AS tenant_status,
  (DATE '2026-01-05' - CAST(tb.created_at AS date)) AS tenure_days,
  (DATE '2026-01-05' - CAST(lo.last_order_at AS date)) AS days_since_last_order,
  (DATE '2026-01-05' - CAST(lp.last_paid_payout_at AS date)) AS days_since_last_paid_payout,
  COALESCE(fr.fee_revenue_eur, 0) AS fee_revenue_ttm_eur
FROM tenant_base tb
LEFT JOIN last_order lo ON lo.tenant_id = tb.tenant_id
LEFT JOIN last_paid_payout lp ON lp.tenant_id = tb.tenant_id
LEFT JOIN fee_revenue_ttm fr ON fr.tenant_id = tb.tenant_id
ORDER BY
  CASE tb.tenant_status WHEN 'churned' THEN 1 WHEN 'suspended' THEN 2 WHEN 'past_due' THEN 3 END NULLS LAST,
  fee_revenue_ttm_eur DESC NULLS FIRST,
  tb.merchant_name ASC NULLS LAST,
  tb.tenant_id ASC NULLS LAST
