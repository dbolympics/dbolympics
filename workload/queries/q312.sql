SELECT
  'order cancellations' AS entity_type,
  COUNT(*) AS total_events,
  COUNT(*) FILTER (
    WHERE EXISTS (
      SELECT 1 FROM audit_log al
      WHERE al.entity_table = 'orders'
        AND al.entity_id = o.id
        AND al.tenant_id = o.tenant_id
    )
  ) AS events_with_match,
  {{divide_decimal(100.0 * COUNT(*) FILTER (
    WHERE EXISTS (
      SELECT 1 FROM audit_log al
      WHERE al.entity_table = 'orders'
        AND al.entity_id = o.id
        AND al.tenant_id = o.tenant_id
    )
  ), NULLIF(COUNT(*), 0))}} AS coverage_rate_pct,
  COUNT(DISTINCT o.tenant_id) AS distinct_tenants
FROM orders o
WHERE o.status = 'cancelled'
  AND o.cancelled_at >= DATE '2023-01-01'
  AND o.cancelled_at < DATE '2026-01-01'

UNION ALL

SELECT
  'invoice voids' AS entity_type,
  COUNT(*) AS total_events,
  COUNT(*) FILTER (
    WHERE EXISTS (
      SELECT 1 FROM audit_log al
      WHERE al.entity_table = 'invoices'
        AND al.entity_id = i.id
        AND al.tenant_id = i.tenant_id
    )
  ) AS events_with_match,
  {{divide_decimal(100.0 * COUNT(*) FILTER (
    WHERE EXISTS (
      SELECT 1 FROM audit_log al
      WHERE al.entity_table = 'invoices'
        AND al.entity_id = i.id
        AND al.tenant_id = i.tenant_id
    )
  ), NULLIF(COUNT(*), 0))}} AS coverage_rate_pct,
  COUNT(DISTINCT i.tenant_id) AS distinct_tenants
FROM invoices i
WHERE i.status = 'void'
  AND i.voided_at >= DATE '2023-01-01'
  AND i.voided_at < DATE '2026-01-01'

ORDER BY entity_type NULLS LAST
