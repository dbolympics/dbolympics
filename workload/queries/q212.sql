SELECT t0.name AS merchant_name,
       COALESCE(t0.industry, 'Unknown') AS vertical,
       COALESCE(m1.total_unpaid_eur,0) AS total_unpaid_balance_eur,
       COALESCE(m2.open_invoice_count,0) AS open_invoice_count,
       COALESCE(m3.days_overdue_oldest,0) AS days_overdue_oldest,
       COALESCE(m4.largest_unpaid_eur,0) AS largest_unpaid_invoice_eur,
       m5.net_terms_days AS net_terms_days
FROM tenants t0
INNER JOIN (
    SELECT i0.tenant_id AS tenant_id,
           SUM({{divide_decimal(i0.amount_due, CASE WHEN i0.currency_code = 'EUR' THEN 1 ELSE fx0.rate END)}}) AS total_unpaid_eur
    FROM invoices i0
    LEFT JOIN (
        SELECT er0.quote_code AS currency_code, er0.rate AS rate
        FROM exchange_rates er0
        WHERE er0.base_code = 'EUR'
          AND er0.as_of = (
              SELECT MAX(er1.as_of)
              FROM exchange_rates er1
              WHERE er1.base_code = 'EUR'
                AND er1.quote_code = er0.quote_code
                AND er1.as_of <= DATE '2025-12-31'
          )
    ) fx0 ON fx0.currency_code = i0.currency_code
    WHERE i0.status IN ('open','past_due') AND i0.amount_due > 0
    GROUP BY i0.tenant_id
) m1 ON m1.tenant_id = t0.id
LEFT JOIN (
    SELECT i2.tenant_id AS tenant_id, COUNT(*) AS open_invoice_count
    FROM invoices i2
    WHERE i2.status IN ('open','past_due') AND i2.amount_due > 0
    GROUP BY i2.tenant_id
) m2 ON m2.tenant_id = t0.id
LEFT JOIN (
    SELECT i3.tenant_id AS tenant_id,
           GREATEST(0, CAST(DATE '2026-01-05' - CAST(MIN(i3.due_at) AS DATE) AS INTEGER)) AS days_overdue_oldest
    FROM invoices i3
    WHERE i3.status IN ('open','past_due') AND i3.amount_due > 0
    GROUP BY i3.tenant_id
) m3 ON m3.tenant_id = t0.id
LEFT JOIN (
    SELECT i4.tenant_id AS tenant_id,
           MAX({{divide_decimal(i4.amount_due, CASE WHEN i4.currency_code='EUR' THEN 1 ELSE fx4.rate END)}}) AS largest_unpaid_eur
    FROM invoices i4
    LEFT JOIN (
        SELECT er2.quote_code AS currency_code, er2.rate AS rate
        FROM exchange_rates er2
        WHERE er2.base_code='EUR'
          AND er2.as_of = (
              SELECT MAX(er3.as_of) FROM exchange_rates er3
              WHERE er3.base_code='EUR' AND er3.quote_code=er2.quote_code AND er3.as_of <= DATE '2025-12-31'
          )
    ) fx4 ON fx4.currency_code = i4.currency_code
    WHERE i4.status IN ('open','past_due') AND i4.amount_due > 0
    GROUP BY i4.tenant_id
) m4 ON m4.tenant_id = t0.id
LEFT JOIN (
    SELECT bp0.tenant_id AS tenant_id, MAX(bp0.net_terms_days) AS net_terms_days
    FROM billing_profiles bp0
    WHERE bp0.is_default = true AND bp0.deleted_at IS NULL
    GROUP BY bp0.tenant_id
) m5 ON m5.tenant_id = t0.id
WHERE COALESCE(m1.total_unpaid_eur,0) <> 0
ORDER BY total_unpaid_balance_eur DESC NULLS FIRST, days_overdue_oldest DESC NULLS FIRST, t0.id ASC NULLS LAST
{{fetch_first(50)}}
