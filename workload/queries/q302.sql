SELECT
  tenant_agg.tenant_name AS tenant_name,
  tenant_agg.industry AS industry,
  tenant_agg.deal_count AS deal_count,
  tenant_agg.total_contract_value_eur AS total_contract_value_eur,
  tenant_agg.total_2025_revenue_eur AS total_2025_revenue_eur,
  {{divide_decimal(tenant_agg.total_2025_revenue_eur, NULLIF(company_total.total, 0))}} * 100 AS pct_of_total_2025_revenue,
  tenant_agg.open_amount_due_eur AS open_amount_due_eur,
  tenant_agg.pct_amount_due_overdue AS pct_amount_due_overdue
FROM (
  SELECT
    t.id AS id,
    t.name AS tenant_name,
    t.industry AS industry,
    (SELECT COUNT(*) FROM deals d WHERE d.tenant_id = t.id) AS deal_count,
    (SELECT COALESCE(SUM(CAST({{divide_decimal(d.contract_value, er.rate)}} AS NUMERIC(18,6))), 0)
       FROM deals d
       JOIN exchange_rates er
         ON er.base_code = 'EUR'
        AND er.quote_code = d.currency_code
        AND er.as_of = COALESCE(d.signed_at, CAST(d.created_at AS date))
      WHERE d.tenant_id = t.id
    ) AS total_contract_value_eur,
    (SELECT COALESCE(SUM(CAST({{divide_decimal(p.amount, er.rate)}} AS NUMERIC(18,6))), 0)
       FROM payments p
       JOIN exchange_rates er
         ON er.base_code = 'EUR'
        AND er.quote_code = p.currency_code
        AND er.as_of = CAST(p.captured_at AS date)
      WHERE p.tenant_id = t.id
        AND p.status IN ('captured', 'refunded', 'partially_refunded')
        AND p.captured_at >= DATE '2025-01-01'
        AND p.captured_at < DATE '2026-01-01'
    ) AS total_2025_revenue_eur,
    (SELECT COALESCE(SUM(CAST({{divide_decimal(i.amount_due, er.rate)}} AS NUMERIC(18,6))), 0)
       FROM invoices i
       JOIN exchange_rates er
         ON er.base_code = 'EUR'
        AND er.quote_code = i.currency_code
        AND er.as_of = DATE '2025-12-31'
      WHERE i.tenant_id = t.id
        AND i.status IN ('open', 'past_due')
        AND i.amount_due > 0
    ) AS open_amount_due_eur,
    (SELECT CASE
              WHEN SUM(CAST({{divide_decimal(i.amount_due, er.rate)}} AS NUMERIC(18,6))) = 0 THEN NULL
              ELSE {{divide_decimal(SUM(CASE WHEN i.due_at < TIMESTAMP '2025-12-31 00:00:00' THEN CAST({{divide_decimal(i.amount_due, er.rate)}} AS NUMERIC(18,6)) ELSE 0 END), SUM(CAST({{divide_decimal(i.amount_due, er.rate)}} AS NUMERIC(18,6))))}} * 100
            END
       FROM invoices i
       JOIN exchange_rates er
         ON er.base_code = 'EUR'
        AND er.quote_code = i.currency_code
        AND er.as_of = DATE '2025-12-31'
      WHERE i.tenant_id = t.id
        AND i.status IN ('open', 'past_due')
        AND i.amount_due > 0
    ) AS pct_amount_due_overdue
  FROM tenants t
  WHERE EXISTS (SELECT 1 FROM deals d WHERE d.tenant_id = t.id)
) AS tenant_agg
CROSS JOIN (
  SELECT COALESCE(SUM(CAST({{divide_decimal(p2.amount, er2.rate)}} AS NUMERIC(18,6))), 0) AS total
  FROM payments p2
  JOIN exchange_rates er2
    ON er2.base_code = 'EUR'
   AND er2.quote_code = p2.currency_code
   AND er2.as_of = CAST(p2.captured_at AS date)
  WHERE p2.status IN ('captured', 'refunded', 'partially_refunded')
    AND p2.captured_at >= DATE '2025-01-01'
    AND p2.captured_at < DATE '2026-01-01'
) AS company_total
ORDER BY tenant_agg.total_2025_revenue_eur DESC NULLS FIRST, tenant_agg.tenant_name NULLS LAST, tenant_agg.id NULLS LAST
