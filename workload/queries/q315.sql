SELECT
  i.status AS invoice_status,
  COUNT(*) AS total_invoices,
  COUNT(i.voided_at) AS voided_at_populated,
  SUM(CASE WHEN i.voided_at IS NULL THEN 1 ELSE 0 END) AS voided_at_null,
  SUM(CASE WHEN EXISTS (
      SELECT 1 FROM audit_log a
      WHERE a.entity_table = 'invoices'
        AND a.entity_id = i.id
        AND a.tenant_id = i.tenant_id
  ) THEN 1 ELSE 0 END) AS matching_audit_log_rows,
  {{divide_decimal(100.0 * SUM(CASE WHEN EXISTS (
    SELECT 1 FROM audit_log a
    WHERE a.entity_table = 'invoices'
      AND a.entity_id = i.id
      AND a.tenant_id = i.tenant_id
  ) THEN 1 ELSE 0 END), COUNT(*))}} AS coverage_rate_pct,
  COUNT(DISTINCT i.tenant_id) AS distinct_tenants
FROM invoices i
WHERE i.status IN ('void', 'uncollectible')
GROUP BY i.status
ORDER BY total_invoices DESC NULLS FIRST, invoice_status NULLS LAST
