WITH late_refunds AS (
  SELECT pr.tenant_id AS tenant_id, pr.processed_at AS processed_at, pr.amount AS amount, pr.currency_code AS currency_code
  FROM payment_refunds pr
  JOIN payout_items pi ON pi.payment_id = pr.payment_id
  JOIN payouts po ON po.id = pi.payout_id
  WHERE pr.status = 'succeeded'
    AND pr.processed_at >= DATE '2025-01-01'
    AND pr.processed_at < DATE '2026-01-01'
    AND pr.processed_at > po.paid_at
),
converted AS (
  SELECT
    lr.tenant_id AS tenant_id,
    lr.processed_at AS processed_at,
    CASE WHEN lr.currency_code = 'EUR' THEN lr.amount
         ELSE CAST({{divide_decimal(lr.amount, er.rate)}} AS NUMERIC(18,6)) END AS eur_amount
  FROM late_refunds lr
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR' AND er.quote_code = lr.currency_code
    AND er.as_of = CAST(lr.processed_at AS date)
),
tenant_totals AS (
  SELECT
    tenant_id,
    SUM(eur_amount) FILTER (WHERE processed_at < DATE '2025-07-01') AS h1_2025_late_refund_eur,
    SUM(eur_amount) FILTER (WHERE processed_at >= DATE '2025-07-01') AS h2_2025_late_refund_eur
  FROM converted
  GROUP BY tenant_id
),
totals AS (
  SELECT tenant_id,
    COALESCE(h1_2025_late_refund_eur,0) + COALESCE(h2_2025_late_refund_eur,0) AS total_2025_late_refund_eur,
    h1_2025_late_refund_eur, h2_2025_late_refund_eur
  FROM tenant_totals
),
grand_total AS (
  SELECT SUM(total_2025_late_refund_eur) AS grand_total_eur FROM totals
)
SELECT
  t.name AS tenant_name,
  tot.h1_2025_late_refund_eur AS h1_2025_late_refund_eur,
  tot.h2_2025_late_refund_eur AS h2_2025_late_refund_eur,
  CASE WHEN COALESCE(tot.h1_2025_late_refund_eur,0) = 0 THEN NULL
       ELSE {{divide_decimal((tot.h2_2025_late_refund_eur - tot.h1_2025_late_refund_eur), tot.h1_2025_late_refund_eur)}} * 100
  END AS change_pct,
  tot.total_2025_late_refund_eur AS total_2025_late_refund_eur,
  {{divide_decimal(tot.total_2025_late_refund_eur, gt.grand_total_eur)}} * 100 AS pct_of_all_late_refunds_2025
FROM totals tot
JOIN tenants t ON t.id = tot.tenant_id
CROSS JOIN grand_total gt
ORDER BY tot.total_2025_late_refund_eur DESC NULLS FIRST, t.name ASC NULLS LAST, t.id NULLS LAST
{{fetch_first(20)}}
