SELECT
  coalesce(t.industry, '(none)') as industry,
  count(distinct p.tenant_id) as tenant_count,
  sum(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) as total_2025_money_collected_eur,
  {{divide_decimal(sum(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))) * 100.0, sum(sum(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6)))) over ())}} as pct_of_total_revenue
FROM payments p
JOIN tenants t ON t.id = p.tenant_id
JOIN exchange_rates er
  ON er.base_code = 'EUR'
  AND er.quote_code = p.currency_code
  AND er.as_of = CAST(p.captured_at AS DATE)
WHERE p.status IN ('captured', 'refunded', 'partially_refunded')
  AND p.captured_at >= timestamp '2025-01-01'
  AND p.captured_at < timestamp '2026-01-01'
GROUP BY coalesce(t.industry, '(none)')
ORDER BY total_2025_money_collected_eur DESC NULLS FIRST, industry NULLS LAST
