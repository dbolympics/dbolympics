WITH churned_tenants AS (
  SELECT id AS tenant_id, name, industry
  FROM tenants
  WHERE status = 'churned'
),
anchor_dates AS (
  SELECT ct.tenant_id AS tenant_id, MAX(o.placed_at) AS anchor_at
  FROM churned_tenants ct
  JOIN orders o ON o.tenant_id = ct.tenant_id AND o.status <> 'cancelled'
  GROUP BY ct.tenant_id
),
windows AS (
  SELECT
    tenant_id,
    anchor_at - interval '90 days' AS final_start,
    anchor_at AS final_end,
    anchor_at - interval '180 days' AS prior_start,
    anchor_at - interval '91 days' AS prior_end
  FROM anchor_dates
),
orders_with_fx AS (
  SELECT
    o.tenant_id AS tenant_id, o.id AS order_id, o.user_id AS user_id, o.placed_at AS placed_at, o.currency_code AS currency_code, o.grand_total AS grand_total,
    er.rate AS rate
  FROM orders o
  JOIN churned_tenants ct ON ct.tenant_id = o.tenant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = o.currency_code AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.status <> 'cancelled'
),
orders_classified AS (
  SELECT
    ow.tenant_id AS tenant_id,
    ow.order_id AS order_id,
    ow.user_id AS user_id,
    CASE WHEN ow.currency_code = 'EUR' THEN ow.grand_total ELSE CAST({{divide_decimal(ow.grand_total, ow.rate)}} AS NUMERIC(18,6)) END AS revenue_eur,
    CASE
      WHEN ow.placed_at BETWEEN w.final_start AND w.final_end THEN 'final'
      WHEN ow.placed_at BETWEEN w.prior_start AND w.prior_end THEN 'prior'
      ELSE NULL
    END AS period
  FROM orders_with_fx ow
  JOIN windows w ON w.tenant_id = ow.tenant_id
),
order_metrics AS (
  SELECT
    tenant_id,
    COUNT(*) FILTER (WHERE period = 'final') AS orders_final,
    COUNT(*) FILTER (WHERE period = 'prior') AS orders_prior,
    SUM(revenue_eur) FILTER (WHERE period = 'final') AS revenue_final,
    SUM(revenue_eur) FILTER (WHERE period = 'prior') AS revenue_prior
  FROM orders_classified
  GROUP BY tenant_id
),
user_period_counts AS (
  SELECT tenant_id, user_id, period, COUNT(*) AS order_cnt
  FROM orders_classified
  WHERE period IS NOT NULL
  GROUP BY tenant_id, user_id, period
),
repeat_metrics AS (
  SELECT
    tenant_id, period,
    COUNT(*) AS customers_total,
    COUNT(*) FILTER (WHERE order_cnt >= 2) AS customers_repeat
  FROM user_period_counts
  GROUP BY tenant_id, period
),
repeat_pivot AS (
  SELECT
    tenant_id,
    MAX(CASE WHEN period = 'final' THEN {{divide_decimal(CAST(customers_repeat AS numeric(18,6)), NULLIF(customers_total, 0))}} END) AS repeat_rate_final,
    MAX(CASE WHEN period = 'prior' THEN {{divide_decimal(CAST(customers_repeat AS numeric(18,6)), NULLIF(customers_total, 0))}} END) AS repeat_rate_prior
  FROM repeat_metrics
  GROUP BY tenant_id
),
payments_with_fx AS (
  SELECT
    p.tenant_id AS tenant_id, p.captured_at AS captured_at, p.currency_code AS currency_code, p.amount AS amount, er.rate AS rate
  FROM payments p
  JOIN churned_tenants ct ON ct.tenant_id = p.tenant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = p.currency_code AND er.as_of = CAST(p.captured_at AS date)
  WHERE p.captured_at IS NOT NULL
),
payments_classified AS (
  SELECT
    pw.tenant_id AS tenant_id,
    CASE WHEN pw.currency_code = 'EUR' THEN pw.amount ELSE CAST({{divide_decimal(pw.amount, pw.rate)}} AS NUMERIC(18,6)) END AS amount_eur,
    CASE
      WHEN pw.captured_at BETWEEN w.final_start AND w.final_end THEN 'final'
      WHEN pw.captured_at BETWEEN w.prior_start AND w.prior_end THEN 'prior'
      ELSE NULL
    END AS period
  FROM payments_with_fx pw
  JOIN windows w ON w.tenant_id = pw.tenant_id
),
payment_metrics AS (
  SELECT
    tenant_id,
    SUM(amount_eur) FILTER (WHERE period = 'final') AS payments_final,
    SUM(amount_eur) FILTER (WHERE period = 'prior') AS payments_prior
  FROM payments_classified
  GROUP BY tenant_id
),
refunds_with_fx AS (
  SELECT
    r.tenant_id AS tenant_id, r.processed_at AS processed_at, r.currency_code AS currency_code, r.amount AS amount, er.rate AS rate
  FROM payment_refunds r
  JOIN churned_tenants ct ON ct.tenant_id = r.tenant_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = r.currency_code AND er.as_of = CAST(r.processed_at AS date)
  WHERE r.status = 'succeeded' AND r.processed_at IS NOT NULL
),
refunds_classified AS (
  SELECT
    rw.tenant_id AS tenant_id,
    CASE WHEN rw.currency_code = 'EUR' THEN rw.amount ELSE CAST({{divide_decimal(rw.amount, rw.rate)}} AS NUMERIC(18,6)) END AS amount_eur,
    CASE
      WHEN rw.processed_at BETWEEN w.final_start AND w.final_end THEN 'final'
      WHEN rw.processed_at BETWEEN w.prior_start AND w.prior_end THEN 'prior'
      ELSE NULL
    END AS period
  FROM refunds_with_fx rw
  JOIN windows w ON w.tenant_id = rw.tenant_id
),
refund_metrics AS (
  SELECT
    tenant_id,
    SUM(amount_eur) FILTER (WHERE period = 'final') AS refunds_final,
    SUM(amount_eur) FILTER (WHERE period = 'prior') AS refunds_prior
  FROM refunds_classified
  GROUP BY tenant_id
),
tickets_classified AS (
  SELECT
    t.tenant_id AS tenant_id,
    CASE
      WHEN t.created_at BETWEEN w.final_start AND w.final_end THEN 'final'
      WHEN t.created_at BETWEEN w.prior_start AND w.prior_end THEN 'prior'
      ELSE NULL
    END AS period
  FROM tickets t
  JOIN windows w ON w.tenant_id = t.tenant_id
),
ticket_metrics AS (
  SELECT
    tenant_id,
    COUNT(*) FILTER (WHERE period = 'final') AS tickets_final,
    COUNT(*) FILTER (WHERE period = 'prior') AS tickets_prior
  FROM tickets_classified
  GROUP BY tenant_id
),
report AS (
  SELECT
    ct.tenant_id AS tenant_id,
    ct.name AS merchant_name,
    ct.industry AS industry,
    COALESCE(om.orders_final, 0) AS orders_final_90d,
    COALESCE(om.orders_prior, 0) AS orders_prior_90d,
    CASE
      WHEN om.revenue_prior IS NULL OR om.revenue_prior = 0 THEN NULL
      ELSE ({{divide_decimal((om.revenue_final - om.revenue_prior), om.revenue_prior)}}) * 100
    END AS revenue_growth_pct,
    rp.repeat_rate_final * 100 AS repeat_rate_final_pct,
    rp.repeat_rate_prior * 100 AS repeat_rate_prior_pct,
    CASE
      WHEN pm.payments_final IS NULL OR pm.payments_final = 0 THEN NULL
      ELSE {{divide_decimal(COALESCE(rfm.refunds_final, 0), pm.payments_final)}} * 100
    END AS refund_rate_final_pct,
    CASE
      WHEN pm.payments_prior IS NULL OR pm.payments_prior = 0 THEN NULL
      ELSE {{divide_decimal(COALESCE(rfm.refunds_prior, 0), pm.payments_prior)}} * 100
    END AS refund_rate_prior_pct,
    COALESCE(tm.tickets_final, 0) AS tickets_final_90d,
    COALESCE(tm.tickets_prior, 0) AS tickets_prior_90d,
    COUNT(*) OVER () AS total_churned_merchants
  FROM churned_tenants ct
  LEFT JOIN order_metrics om ON om.tenant_id = ct.tenant_id
  LEFT JOIN repeat_pivot rp ON rp.tenant_id = ct.tenant_id
  LEFT JOIN payment_metrics pm ON pm.tenant_id = ct.tenant_id
  LEFT JOIN refund_metrics rfm ON rfm.tenant_id = ct.tenant_id
  LEFT JOIN ticket_metrics tm ON tm.tenant_id = ct.tenant_id
)
SELECT
  merchant_name,
  industry,
  orders_final_90d,
  orders_prior_90d,
  revenue_growth_pct,
  repeat_rate_final_pct,
  repeat_rate_prior_pct,
  refund_rate_final_pct,
  refund_rate_prior_pct,
  tickets_final_90d,
  tickets_prior_90d,
  total_churned_merchants
FROM report
ORDER BY orders_final_90d ASC NULLS LAST, tenant_id ASC NULLS LAST
{{fetch_first(50)}}
