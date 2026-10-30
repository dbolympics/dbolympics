WITH months AS (
  SELECT DISTINCT month_start, month_label
  FROM calendar_days
  WHERE month_start BETWEEN DATE '2023-01-01' AND DATE '2025-12-01'
),

orders_rev AS (
  SELECT CAST({{date_trunc('month', o.placed_at)}} AS date) AS month_start,
         SUM(CAST(o.grand_total / er.rate AS NUMERIC(18,6))) AS orders_booked_revenue_eur,
         COUNT(*) AS order_count
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS DATE)
  WHERE o.status <> 'cancelled'
    AND o.placed_at IS NOT NULL
  GROUP BY 1
),

payments_rev AS (
  SELECT CAST({{date_trunc('month', p.captured_at)}} AS date) AS month_start,
         SUM(CAST(p.amount / er.rate AS NUMERIC(18,6))) AS payments_captured_eur,
         COUNT(*) AS payment_count
  FROM payments p
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.captured_at AS DATE)
  WHERE p.status = 'captured'
    AND p.captured_at IS NOT NULL
  GROUP BY 1
),

payouts_rev AS (
  SELECT CAST({{date_trunc('month', po.paid_at)}} AS date) AS month_start,
         SUM(CAST(po.gross_amount / er.rate AS NUMERIC(18,6))) AS payout_gross_eur
  FROM payouts po
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = po.currency_code
   AND er.as_of = CAST(po.paid_at AS DATE)
  WHERE po.paid_at IS NOT NULL
  GROUP BY 1
),

invoices_rev AS (
  SELECT CAST({{date_trunc('month', i.paid_at)}} AS date) AS month_start,
         SUM(CAST(i.total / er.rate AS NUMERIC(18,6))) AS invoice_paid_revenue_eur
  FROM invoices i
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = i.currency_code
   AND er.as_of = CAST(i.paid_at AS DATE)
  WHERE i.status = 'paid'
    AND i.paid_at IS NOT NULL
  GROUP BY 1
),

refunds_rev AS (
  SELECT CAST({{date_trunc('month', pr.processed_at)}} AS date) AS month_start,
         SUM(CAST(pr.amount / er.rate AS NUMERIC(18,6))) AS refunds_eur
  FROM payment_refunds pr
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = pr.currency_code
   AND er.as_of = CAST(pr.processed_at AS DATE)
  WHERE pr.status = 'succeeded'
    AND pr.processed_at IS NOT NULL
  GROUP BY 1
)

SELECT
  m.month_label AS month,
  COALESCE(orr.orders_booked_revenue_eur, 0) AS orders_booked_revenue_eur,
  COALESCE(pay.payments_captured_eur, 0) AS payments_captured_eur,
  COALESCE(pou.payout_gross_eur, 0) AS payout_gross_eur,
  COALESCE(inv.invoice_paid_revenue_eur, 0) AS invoice_paid_revenue_eur,
  COALESCE(ref.refunds_eur, 0) AS refunds_eur,
  COALESCE(orr.order_count, 0) AS order_count,
  COALESCE(pay.payment_count, 0) AS payment_count
FROM months m
LEFT JOIN orders_rev orr ON orr.month_start = m.month_start
LEFT JOIN payments_rev pay ON pay.month_start = m.month_start
LEFT JOIN payouts_rev pou ON pou.month_start = m.month_start
LEFT JOIN invoices_rev inv ON inv.month_start = m.month_start
LEFT JOIN refunds_rev ref ON ref.month_start = m.month_start
ORDER BY m.month_start NULLS LAST, m.month_label NULLS LAST
