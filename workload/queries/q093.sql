WITH payout_eur AS (
  SELECT
    po.id AS payout_id,
    cd.month_start AS month_start,
    cd.month_label AS month_label,
    CASE WHEN po.currency_code = 'EUR' THEN po.gross_amount ELSE CAST({{divide_decimal(po.gross_amount, er.rate)}} AS NUMERIC(18,6)) END AS gross_eur,
    CASE WHEN po.currency_code = 'EUR' THEN po.fee_amount ELSE CAST({{divide_decimal(po.fee_amount, er.rate)}} AS NUMERIC(18,6)) END AS fee_eur,
    CASE WHEN po.currency_code = 'EUR' THEN po.net_amount ELSE CAST({{divide_decimal(po.net_amount, er.rate)}} AS NUMERIC(18,6)) END AS net_eur
  FROM payouts po
  JOIN calendar_days cd ON cd.calendar_date = CAST(po.paid_at AS date)
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = po.currency_code
    AND er.as_of = cd.calendar_date
  WHERE po.paid_at >= DATE '2023-01-01' AND po.paid_at < DATE '2026-01-01'
),
refund_eur AS (
  SELECT
    po.id AS payout_id,
    CASE WHEN pr.currency_code = 'EUR' THEN pr.amount ELSE CAST({{divide_decimal(pr.amount, er.rate)}} AS NUMERIC(18,6)) END AS refund_eur
  FROM payouts po
  JOIN payout_items pi ON pi.payout_id = po.id
  JOIN payment_refunds pr ON pr.payment_id = pi.payment_id AND pr.status = 'succeeded'
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = pr.currency_code
    AND er.as_of = CAST(pr.processed_at AS date)
  WHERE po.paid_at >= DATE '2023-01-01' AND po.paid_at < DATE '2026-01-01'
),
payout_month_agg AS (
  SELECT month_start, month_label,
    SUM(gross_eur) AS payout_gross_eur,
    SUM(fee_eur) AS payout_fee_eur,
    SUM(net_eur) AS payout_net_eur
  FROM payout_eur
  GROUP BY month_start, month_label
),
refund_month_agg AS (
  SELECT pe.month_start AS month_start, pe.month_label AS month_label, SUM(re.refund_eur) AS linked_refunds_eur
  FROM refund_eur re
  JOIN (SELECT DISTINCT payout_id, month_start, month_label FROM payout_eur) pe ON pe.payout_id = re.payout_id
  GROUP BY pe.month_start, pe.month_label
),
months AS (
  SELECT DISTINCT month_start, month_label FROM calendar_days
  WHERE month_start >= DATE '2023-01-01' AND month_start <= DATE '2025-12-01'
)
SELECT
  m.month_label AS month,
  COALESCE(pg.payout_gross_eur,0) AS payout_gross_eur,
  COALESCE(pg.payout_fee_eur,0) AS payout_fee_eur,
  COALESCE(pg.payout_net_eur,0) AS payout_net_eur,
  COALESCE(rf.linked_refunds_eur,0) AS linked_refunds_eur,
  COALESCE(pg.payout_gross_eur,0) - COALESCE(pg.payout_fee_eur,0) - COALESCE(rf.linked_refunds_eur,0) AS implied_net_eur,
  COALESCE(pg.payout_net_eur,0) - (COALESCE(pg.payout_gross_eur,0) - COALESCE(pg.payout_fee_eur,0) - COALESCE(rf.linked_refunds_eur,0)) AS diff_eur,
  CASE WHEN COALESCE(pg.payout_net_eur,0) = 0 THEN NULL
  ELSE {{divide_decimal((COALESCE(pg.payout_net_eur,0) - (COALESCE(pg.payout_gross_eur,0) - COALESCE(pg.payout_fee_eur,0) - COALESCE(rf.linked_refunds_eur,0))), pg.payout_net_eur)}} * 100
  END AS diff_pct
FROM months m
LEFT JOIN payout_month_agg pg ON pg.month_start = m.month_start
LEFT JOIN refund_month_agg rf ON rf.month_start = m.month_start
ORDER BY m.month_start NULLS LAST, m.month_label NULLS LAST, pg.month_label NULLS LAST, rf.month_label NULLS LAST
