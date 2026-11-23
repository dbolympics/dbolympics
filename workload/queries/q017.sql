SELECT
  vertical,
  merchant_count,
  payment_count,
  gross_captured_eur,
  amount_refunded_eur,
  CASE WHEN gross_captured_eur = 0 THEN NULL ELSE {{divide_decimal(amount_refunded_eur, gross_captured_eur)}} * 100 END AS refund_rate_pct,
  avg_refund_rate_pct AS avg_refund_rate_per_merchant_pct
FROM (
  SELECT
    vertical,
    COUNT(*) AS merchant_count,
    SUM(payment_count) AS payment_count,
    SUM(gross_captured_eur) AS gross_captured_eur,
    SUM(amount_refunded_eur) AS amount_refunded_eur,
    AVG(tenant_refund_rate_pct) AS avg_refund_rate_pct
  FROM (
    SELECT
      COALESCE(t.industry, 'Unknown') AS vertical,
      t.id AS tenant_id,
      COUNT(*) AS payment_count,
      SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) AS gross_captured_eur,
      SUM(CAST({{divide_decimal(p.amount_refunded, er.rate)}} AS NUMERIC(18,6))) AS amount_refunded_eur,
      CASE WHEN SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) = 0 THEN 0
           ELSE {{divide_decimal(SUM(CAST({{divide_decimal(p.amount_refunded, er.rate)}} AS NUMERIC(18,6))), SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))))}} * 100
      END AS tenant_refund_rate_pct
    FROM payments p
    JOIN tenants t ON t.id = p.tenant_id
    JOIN exchange_rates er
      ON er.base_code = 'EUR'
     AND er.quote_code = p.currency_code
     AND er.as_of = CAST(p.captured_at AS DATE)
    WHERE p.captured_at >= DATE '2025-01-01'
      AND p.captured_at < DATE '2026-01-01'
      AND p.status IN ('captured','refunded','partially_refunded')
    GROUP BY COALESCE(t.industry, 'Unknown'), t.id
  ) AS tenant_agg
  GROUP BY vertical
) AS vertical_agg
ORDER BY refund_rate_pct DESC NULLS FIRST, vertical ASC NULLS LAST
