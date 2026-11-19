WITH agg AS (
  SELECT
    p.currency_code AS currency_code,
    COUNT(*) AS payout_count,
    SUM(p.gross_amount) AS total_gross_native,
    SUM(p.fee_amount) AS total_fee_native,
    SUM(CAST({{divide_decimal(p.gross_amount, er.rate)}} AS NUMERIC(18,6))) AS total_gross_eur,
    SUM(CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6))) AS total_fee_eur
  FROM payouts p
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = p.currency_code
    AND er.as_of = CAST(p.paid_at AS DATE)
  WHERE p.status = 'paid'
    AND p.paid_at >= DATE '2025-01-01'
    AND p.paid_at < DATE '2026-01-01'
  GROUP BY p.currency_code
)
SELECT
  currency_code,
  payout_count,
  total_gross_native AS total_gross_native,
  total_fee_native AS total_fee_native,
  total_gross_eur AS total_gross_eur,
  total_fee_eur AS total_fee_eur,
  {{divide_decimal(total_fee_native, NULLIF(total_fee_eur,0))}} AS implied_avg_rate_native_per_eur,
  {{divide_decimal(100 * total_fee_eur, SUM(total_fee_eur) OVER ())}} AS share_of_total_fee_eur_pct
FROM agg
ORDER BY total_fee_eur DESC NULLS FIRST, currency_code ASC NULLS LAST
