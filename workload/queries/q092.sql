SELECT
  {{year_month({{date_trunc('month', i.paid_at)}})}} as month,
  sum(case when i.currency_code = 'EUR' then i.total else CAST(i.total / er.rate AS NUMERIC(18,6)) end) as invoice_paid_total_eur,
  sum(case when i.order_id is not null then (case when i.currency_code = 'EUR' then i.total else CAST(i.total / er.rate AS NUMERIC(18,6)) end) else 0 end) as invoice_order_linked_eur,
  sum(case when i.order_id is null and i.subscription_id is not null then (case when i.currency_code = 'EUR' then i.total else CAST(i.total / er.rate AS NUMERIC(18,6)) end) else 0 end) as invoice_subscription_only_eur,
  sum(case when i.order_id is null and i.subscription_id is null then (case when i.currency_code = 'EUR' then i.total else CAST(i.total / er.rate AS NUMERIC(18,6)) end) else 0 end) as invoice_other_eur,
  100.0 * sum(case when i.order_id is not null then (case when i.currency_code = 'EUR' then i.total else CAST(i.total / er.rate AS NUMERIC(18,6)) end) else 0 end)
  / nullif(sum(case when i.currency_code = 'EUR' then i.total else CAST(i.total / er.rate AS NUMERIC(18,6)) end), 0) as pct_order_linked
FROM invoices i
LEFT JOIN exchange_rates er
  ON er.base_code = 'EUR'
  AND er.quote_code = i.currency_code
  AND er.as_of = CAST(i.paid_at AS DATE)
WHERE i.status = 'paid'
  AND i.paid_at >= date '2023-01-01'
  AND i.paid_at < date '2026-01-01'
GROUP BY {{date_trunc('month', i.paid_at)}}
ORDER BY {{date_trunc('month', i.paid_at)}} NULLS LAST
