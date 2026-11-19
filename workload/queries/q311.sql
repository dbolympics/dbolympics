WITH soft_deleted AS (
  SELECT 'brands' AS entity_table, COUNT(*) AS total_soft_deleted, COUNT(DISTINCT tenant_id) AS tenant_count FROM brands WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'categories', COUNT(*), COUNT(DISTINCT tenant_id) FROM categories WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'products', COUNT(*), COUNT(DISTINCT tenant_id) FROM products WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'product_variants', COUNT(*), COUNT(DISTINCT tenant_id) FROM product_variants WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'collections', COUNT(*), COUNT(DISTINCT tenant_id) FROM collections WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'users', COUNT(*), COUNT(DISTINCT tenant_id) FROM users WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'billing_profiles', COUNT(*), COUNT(DISTINCT tenant_id) FROM billing_profiles WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'plans', COUNT(*), COUNT(DISTINCT tenant_id) FROM plans WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'price_lists', COUNT(*), COUNT(DISTINCT tenant_id) FROM price_lists WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'discounts', COUNT(*), COUNT(DISTINCT tenant_id) FROM discounts WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'coupons', COUNT(*), COUNT(DISTINCT tenant_id) FROM coupons WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'promotions', COUNT(*), COUNT(DISTINCT tenant_id) FROM promotions WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'campaigns', COUNT(*), COUNT(DISTINCT tenant_id) FROM campaigns WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'email_templates', COUNT(*), COUNT(DISTINCT tenant_id) FROM email_templates WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'segments', COUNT(*), COUNT(DISTINCT tenant_id) FROM segments WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'landing_pages', COUNT(*), COUNT(DISTINCT tenant_id) FROM landing_pages WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'referrals', COUNT(*), COUNT(DISTINCT tenant_id) FROM referrals WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'loyalty_programs', COUNT(*), COUNT(DISTINCT tenant_id) FROM loyalty_programs WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'ab_tests', COUNT(*), COUNT(DISTINCT tenant_id) FROM ab_tests WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'experiments', COUNT(*), COUNT(DISTINCT tenant_id) FROM experiments WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'cohorts', COUNT(*), COUNT(DISTINCT tenant_id) FROM cohorts WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'funnels', COUNT(*), COUNT(DISTINCT tenant_id) FROM funnels WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'contacts', COUNT(*), COUNT(DISTINCT tenant_id) FROM contacts WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'accounts', COUNT(*), COUNT(DISTINCT tenant_id) FROM accounts WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'knowledge_articles', COUNT(*), COUNT(DISTINCT tenant_id) FROM knowledge_articles WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'macros', COUNT(*), COUNT(DISTINCT tenant_id) FROM macros WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'files', COUNT(*), COUNT(DISTINCT tenant_id) FROM files WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'utm_links', COUNT(*), COUNT(DISTINCT tenant_id) FROM utm_links WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'suppliers', COUNT(*), COUNT(DISTINCT tenant_id) FROM suppliers WHERE deleted_at IS NOT NULL
  UNION ALL SELECT 'warehouses', COUNT(*), COUNT(DISTINCT tenant_id) FROM warehouses WHERE deleted_at IS NOT NULL
),
audit_counts AS (
  SELECT entity_table, COUNT(*) AS deleted_audit_rows
  FROM audit_log
  WHERE action = 'delete'
  GROUP BY entity_table
)
SELECT
  sd.entity_table AS entity_table,
  sd.total_soft_deleted AS total_soft_deleted,
  COALESCE(ac.deleted_audit_rows, 0) AS matching_audit_rows,
  CASE WHEN sd.total_soft_deleted = 0 THEN NULL
       ELSE {{divide_decimal(100.0 * COALESCE(ac.deleted_audit_rows, 0), sd.total_soft_deleted)}}
  END AS coverage_rate_pct,
  sd.tenant_count AS tenants_with_soft_deleted
FROM soft_deleted sd
LEFT JOIN audit_counts ac ON ac.entity_table = sd.entity_table
ORDER BY sd.total_soft_deleted DESC NULLS FIRST, sd.entity_table ASC NULLS LAST
