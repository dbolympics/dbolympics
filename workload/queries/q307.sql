WITH refund_eur AS (
  SELECT pr.tenant_id AS tenant_id,
         CAST({{divide_decimal(pr.amount, er.rate)}} AS NUMERIC(18,6)) AS eur_amount,
         CASE WHEN po.paid_at IS NOT NULL AND pr.processed_at > po.paid_at THEN 1 ELSE 0 END AS is_late
  FROM payment_refunds pr
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = pr.currency_code
   AND er.as_of = CAST(pr.processed_at AS date)
  LEFT JOIN payout_items pi ON pi.payment_id = pr.payment_id
  LEFT JOIN payouts po ON po.id = pi.payout_id
  WHERE pr.status = 'succeeded'
    AND pr.processed_at >= DATE '2025-01-01'
    AND pr.processed_at < DATE '2026-01-01'
),
tenant_agg AS (
  SELECT tenant_id,
         SUM(eur_amount) AS total_refunds_2025_eur,
         SUM(CASE WHEN is_late = 1 THEN eur_amount ELSE 0 END) AS late_refunds_2025_eur
  FROM refund_eur
  GROUP BY tenant_id
),
company_agg AS (
  SELECT SUM(eur_amount) AS total_eur,
         SUM(CASE WHEN is_late = 1 THEN eur_amount ELSE 0 END) AS late_eur
  FROM refund_eur
)
SELECT t.name AS tenant_name,
       ta.total_refunds_2025_eur AS total_refunds_2025_eur,
       ta.late_refunds_2025_eur AS late_refunds_2025_eur,
       {{divide_decimal(ta.late_refunds_2025_eur, NULLIF(ta.total_refunds_2025_eur, 0))}} * 100 AS pct_of_own_refunds_late,
       {{divide_decimal(ca.late_eur, NULLIF(ca.total_eur, 0))}} * 100 AS company_avg_pct_late_2025
FROM tenant_agg ta
JOIN tenants t ON t.id = ta.tenant_id
CROSS JOIN company_agg ca
ORDER BY ta.total_refunds_2025_eur DESC NULLS FIRST, t.name ASC NULLS LAST, t.id ASC NULLS LAST
{{fetch_first(15)}}
