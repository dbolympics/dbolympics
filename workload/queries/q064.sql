SELECT
  t.name AS merchant_name,
  t.industry AS industry,
  coalesce(rr.refund_rate_last, 0) * 100 AS refund_rate_last_90d_pct,
  coalesce(rr.refund_rate_prior, 0) * 100 AS refund_rate_prior_90d_pct,
  coalesce(cr.cancel_rate_last, 0) * 100 AS cancellation_rate_last_90d_pct,
  coalesce(cr.cancel_rate_prior, 0) * 100 AS cancellation_rate_prior_90d_pct,
  coalesce(ov.overdue_eur, 0) AS overdue_invoice_amount_eur,
  coalesce(ws.sessions_last, 0) AS web_sessions_last_90d,
  coalesce(ws.sessions_prior, 0) AS web_sessions_prior_90d,
  CASE WHEN coalesce(ws.sessions_prior, 0) = 0 THEN NULL
       ELSE {{divide_decimal((ws.sessions_last - ws.sessions_prior) * 100.0, ws.sessions_prior)}}
  END AS session_growth_pct
FROM tenants t
LEFT JOIN (
  SELECT ra.tenant_id AS tenant_id,
         {{divide_decimal(ra.refund_last_eur, NULLIF(ca.captured_last_eur, 0))}} AS refund_rate_last,
         {{divide_decimal(ra.refund_prior_eur, NULLIF(ca.captured_prior_eur, 0))}} AS refund_rate_prior
  FROM (
    SELECT tenant_id,
           SUM(CASE WHEN processed_at >= DATE '2025-10-03' AND processed_at < DATE '2026-01-01' THEN amount_eur ELSE 0 END) AS refund_last_eur,
           SUM(CASE WHEN processed_at >= DATE '2025-07-05' AND processed_at < DATE '2025-10-03' THEN amount_eur ELSE 0 END) AS refund_prior_eur
    FROM (
      SELECT pr.tenant_id AS tenant_id, pr.processed_at AS processed_at,
             CAST({{divide_decimal(pr.amount, COALESCE(er.rate, 1))}} AS NUMERIC(18,6)) AS amount_eur
      FROM payment_refunds pr
      LEFT JOIN exchange_rates er
        ON er.base_code = 'EUR' AND er.quote_code = pr.currency_code AND er.as_of = CAST(pr.processed_at AS date)
      WHERE pr.status = 'succeeded'
        AND pr.processed_at >= DATE '2025-07-05' AND pr.processed_at < DATE '2026-01-01'
    ) ra_inner
    GROUP BY tenant_id
  ) ra
  JOIN (
    SELECT tenant_id,
           SUM(CASE WHEN captured_at >= DATE '2025-10-03' AND captured_at < DATE '2026-01-01' THEN amount_eur ELSE 0 END) AS captured_last_eur,
           SUM(CASE WHEN captured_at >= DATE '2025-07-05' AND captured_at < DATE '2025-10-03' THEN amount_eur ELSE 0 END) AS captured_prior_eur
    FROM (
      SELECT p.tenant_id AS tenant_id, p.captured_at AS captured_at,
             CAST({{divide_decimal(p.amount, COALESCE(er.rate, 1))}} AS NUMERIC(18,6)) AS amount_eur
      FROM payments p
      LEFT JOIN exchange_rates er
        ON er.base_code = 'EUR' AND er.quote_code = p.currency_code AND er.as_of = CAST(p.captured_at AS date)
      WHERE p.status = 'captured'
        AND p.captured_at >= DATE '2025-07-05' AND p.captured_at < DATE '2026-01-01'
    ) ca_inner
    GROUP BY tenant_id
  ) ca ON ca.tenant_id = ra.tenant_id
) rr ON rr.tenant_id = t.id
LEFT JOIN (
  SELECT tenant_id,
         {{divide_decimal(CAST(SUM(CASE WHEN placed_at >= DATE '2025-10-03' AND placed_at < DATE '2026-01-01' AND status = 'cancelled' THEN 1 ELSE 0 END) AS decimal(18,6)), NULLIF(SUM(CASE WHEN placed_at >= DATE '2025-10-03' AND placed_at < DATE '2026-01-01' THEN 1 ELSE 0 END), 0))}} AS cancel_rate_last,
         {{divide_decimal(CAST(SUM(CASE WHEN placed_at >= DATE '2025-07-05' AND placed_at < DATE '2025-10-03' AND status = 'cancelled' THEN 1 ELSE 0 END) AS decimal(18,6)), NULLIF(SUM(CASE WHEN placed_at >= DATE '2025-07-05' AND placed_at < DATE '2025-10-03' THEN 1 ELSE 0 END), 0))}} AS cancel_rate_prior
  FROM orders
  WHERE placed_at >= DATE '2025-07-05' AND placed_at < DATE '2026-01-01'
  GROUP BY tenant_id
) cr ON cr.tenant_id = t.id
LEFT JOIN (
  SELECT i.tenant_id AS tenant_id,
         SUM(CAST({{divide_decimal(i.amount_due, COALESCE(er.rate, 1))}} AS NUMERIC(18,6))) AS overdue_eur
  FROM invoices i
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = i.currency_code
   AND er.as_of = (
        SELECT MAX(er2.as_of) FROM exchange_rates er2
        WHERE er2.base_code = 'EUR' AND er2.quote_code = i.currency_code AND er2.as_of <= DATE '2026-01-05'
      )
  WHERE i.status = 'past_due' OR (i.status = 'open' AND i.due_at < DATE '2026-01-05')
  GROUP BY i.tenant_id
) ov ON ov.tenant_id = t.id
LEFT JOIN (
  SELECT tenant_id,
         SUM(CASE WHEN started_at >= DATE '2025-10-03' AND started_at < DATE '2026-01-01' THEN 1 ELSE 0 END) AS sessions_last,
         SUM(CASE WHEN started_at >= DATE '2025-07-05' AND started_at < DATE '2025-10-03' THEN 1 ELSE 0 END) AS sessions_prior
  FROM web_sessions
  WHERE started_at >= DATE '2025-07-05' AND started_at < DATE '2026-01-01'
  GROUP BY tenant_id
) ws ON ws.tenant_id = t.id
ORDER BY overdue_invoice_amount_eur DESC NULLS FIRST, refund_rate_last_90d_pct DESC NULLS FIRST, t.id NULLS LAST
{{fetch_first(50)}}
