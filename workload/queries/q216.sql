WITH t_industry AS (
  SELECT
    t0.id AS tenant_id,
    COALESCE(NULLIF(TRIM(t0.industry), ''), 'Unspecified') AS vertical
  FROM tenants t0
),
d_vertical AS (
  SELECT DISTINCT ti0.vertical AS vertical
  FROM t_industry ti0
),
m_merchants AS (
  SELECT
    ti1.vertical AS vertical,
    COUNT(DISTINCT ti1.tenant_id) AS merchant_count
  FROM t_industry ti1
  GROUP BY ti1.vertical
),
m_fee AS (
  SELECT
    ti2.vertical AS vertical,
    SUM(CAST({{divide_decimal(p0.fee_amount, COALESCE(er0.rate, CASE WHEN p0.currency_code = 'EUR' THEN 1.0 END))}} AS NUMERIC(18,6))) AS fee_revenue_eur
  FROM payouts p0
  JOIN t_industry ti2 ON ti2.tenant_id = p0.tenant_id
  LEFT JOIN exchange_rates er0
    ON er0.base_code = 'EUR'
    AND er0.quote_code = p0.currency_code
    AND er0.as_of = CAST(p0.paid_at AS date)
  WHERE p0.status = 'paid'
    AND p0.paid_at >= DATE '2025-01-01'
    AND p0.paid_at < DATE '2026-01-01'
  GROUP BY ti2.vertical
),
m_shipping AS (
  SELECT
    ti3.vertical AS vertical,
    SUM(CAST({{divide_decimal(s0.shipping_cost, COALESCE(er1.rate, CASE WHEN s0.currency_code = 'EUR' THEN 1.0 END))}} AS NUMERIC(18,6))) AS shipping_cost_eur
  FROM shipments s0
  JOIN t_industry ti3 ON ti3.tenant_id = s0.tenant_id
  LEFT JOIN exchange_rates er1
    ON er1.base_code = 'EUR'
    AND er1.quote_code = s0.currency_code
    AND er1.as_of = CAST(s0.shipped_at AS date)
  WHERE s0.shipped_at >= DATE '2025-01-01'
    AND s0.shipped_at < DATE '2026-01-01'
    AND s0.shipping_cost IS NOT NULL
  GROUP BY ti3.vertical
),
m_refund AS (
  SELECT
    ti4.vertical AS vertical,
    SUM(CAST({{divide_decimal(r0.refund_total, COALESCE(er2.rate, CASE WHEN r0.currency_code = 'EUR' THEN 1.0 END))}} AS NUMERIC(18,6))) AS refund_amount_eur
  FROM order_returns r0
  JOIN t_industry ti4 ON ti4.tenant_id = r0.tenant_id
  LEFT JOIN exchange_rates er2
    ON er2.base_code = 'EUR'
    AND er2.quote_code = r0.currency_code
    AND er2.as_of = CAST(COALESCE(r0.refunded_at, r0.requested_at) AS date)
  WHERE r0.status = 'refunded'
    AND COALESCE(r0.refunded_at, r0.requested_at) >= DATE '2025-01-01'
    AND COALESCE(r0.refunded_at, r0.requested_at) < DATE '2026-01-01'
  GROUP BY ti4.vertical
),
m_tickets AS (
  SELECT
    ti5.vertical AS vertical,
    COUNT(*) AS ticket_count
  FROM tickets tk0
  JOIN t_industry ti5 ON ti5.tenant_id = tk0.tenant_id
  WHERE tk0.created_at >= DATE '2025-01-01'
    AND tk0.created_at < DATE '2026-01-01'
  GROUP BY ti5.vertical
)
SELECT
  d0.vertical AS vertical,
  COALESCE(mm0.merchant_count, 0) AS merchant_count,
  COALESCE(mf0.fee_revenue_eur, 0) AS fee_revenue_eur,
  COALESCE(ms0.shipping_cost_eur, 0) AS shipping_cost_eur,
  COALESCE(mr0.refund_amount_eur, 0) AS refund_amount_eur,
  COALESCE(mt0.ticket_count, 0) AS support_ticket_count,
  COALESCE(mf0.fee_revenue_eur, 0) - COALESCE(ms0.shipping_cost_eur, 0) - COALESCE(mr0.refund_amount_eur, 0) AS rough_net_contribution_eur,
  CASE WHEN COALESCE(mf0.fee_revenue_eur, 0) = 0 THEN NULL
  ELSE {{divide_decimal(100.0 * (COALESCE(mf0.fee_revenue_eur, 0) - COALESCE(ms0.shipping_cost_eur, 0) - COALESCE(mr0.refund_amount_eur, 0)), mf0.fee_revenue_eur)}}
  END AS net_contribution_pct_of_fee_revenue
FROM d_vertical d0
LEFT JOIN m_merchants mm0 ON mm0.vertical = d0.vertical
LEFT JOIN m_fee mf0 ON mf0.vertical = d0.vertical
LEFT JOIN m_shipping ms0 ON ms0.vertical = d0.vertical
LEFT JOIN m_refund mr0 ON mr0.vertical = d0.vertical
LEFT JOIN m_tickets mt0 ON mt0.vertical = d0.vertical
ORDER BY rough_net_contribution_eur DESC NULLS FIRST, d0.vertical ASC NULLS LAST
