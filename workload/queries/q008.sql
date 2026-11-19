WITH payout_eur AS (
  SELECT
    p.id AS id,
    cd.year_num AS year_num,
    cd.quarter_num AS quarter_num,
    CAST({{divide_decimal(p.gross_amount, er.rate)}} AS NUMERIC(18,6)) AS gross_eur,
    CAST({{divide_decimal(p.fee_amount, er.rate)}} AS NUMERIC(18,6)) AS fee_eur
  FROM payouts p
  JOIN calendar_days cd ON cd.calendar_date = CAST(p.paid_at AS date)
  JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = p.currency_code
   AND er.as_of = CAST(p.paid_at AS date)
  WHERE p.status = 'paid'
    AND cd.year_num IN (2024, 2025)
),
quarterly AS (
  SELECT
    year_num,
    quarter_num,
    SUM(gross_eur) AS gross_volume_eur,
    SUM(fee_eur) AS fee_revenue_eur
  FROM payout_eur
  GROUP BY year_num, quarter_num
)
SELECT
  (CAST(year_num AS text) || '-Q' || CAST(quarter_num AS text)) AS quarter,
  gross_volume_eur AS gross_volume_eur,
  fee_revenue_eur AS fee_revenue_eur,
  {{divide_decimal(100.0 * fee_revenue_eur, NULLIF(gross_volume_eur, 0))}} AS take_rate_pct,
  {{divide_decimal(100.0 * fee_revenue_eur, NULLIF(gross_volume_eur, 0))}}
  - LAG({{divide_decimal(100.0 * fee_revenue_eur, NULLIF(gross_volume_eur, 0))}}) OVER (ORDER BY year_num NULLS LAST, quarter_num NULLS LAST) AS take_rate_change_pp
FROM quarterly
ORDER BY year_num NULLS LAST, quarter_num NULLS LAST
