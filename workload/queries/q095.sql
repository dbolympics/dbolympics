SELECT
  timing_bucket,
  COUNT(*) AS refund_count,
  SUM(amount_eur) AS refund_amount_eur,
  {{divide_decimal(SUM(amount_eur), SUM(SUM(amount_eur)) OVER ())}} * 100 AS pct_of_total_refund_amount,
  AVG(CASE WHEN timing_bucket = 'refund after payout paid_at' THEN days_lag END) AS avg_days_lag
FROM (
  SELECT
    pr.id AS id,
    CASE
      WHEN po.id IS NULL THEN 'payment not yet settled in any payout'
      WHEN pr.processed_at <= po.paid_at THEN 'refund before payout paid_at'
      ELSE 'refund after payout paid_at'
    END AS timing_bucket,
    CASE WHEN pr.currency_code = 'EUR' THEN CAST(pr.amount AS NUMERIC(18,6)) ELSE CAST({{divide_decimal(pr.amount, er.rate)}} AS NUMERIC(18,6)) END AS amount_eur,
    {{divide_decimal({{seconds_between(po.paid_at, pr.processed_at)}}, 86400.0)}} AS days_lag
  FROM payment_refunds pr
  LEFT JOIN payout_items pi ON pi.payment_id = pr.payment_id
  LEFT JOIN payouts po ON po.id = pi.payout_id
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = pr.currency_code
    AND er.as_of = CAST(pr.processed_at AS date)
  WHERE pr.status = 'succeeded'
    AND pr.processed_at >= DATE '2023-01-01'
    AND pr.processed_at < DATE '2026-01-01'
) sub
GROUP BY timing_bucket
ORDER BY refund_amount_eur DESC NULLS FIRST, timing_bucket NULLS LAST
