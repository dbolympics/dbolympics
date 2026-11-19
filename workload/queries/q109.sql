SELECT entity_table,
 total_soft_deleted,
 matching_audit_rows,
 CASE WHEN total_soft_deleted = 0 THEN NULL
      ELSE LEAST({{divide_decimal(CAST(matching_audit_rows AS numeric(18,6)), total_soft_deleted)}} * 100, 100)
 END AS coverage_rate_pct,
 distinct_tenants,
 earliest_deleted_at,
 most_recent_deleted_at
FROM (
  SELECT 'products' AS entity_table,
    (SELECT count(*) FROM products WHERE deleted_at IS NOT NULL) AS total_soft_deleted,
    (SELECT count(*) FROM audit_log WHERE action = 'delete' AND entity_table = 'products') AS matching_audit_rows,
    (SELECT count(DISTINCT tenant_id) FROM products WHERE deleted_at IS NOT NULL) AS distinct_tenants,
    (SELECT min(deleted_at) FROM products WHERE deleted_at IS NOT NULL) AS earliest_deleted_at,
    (SELECT max(deleted_at) FROM products WHERE deleted_at IS NOT NULL) AS most_recent_deleted_at
  UNION ALL
  SELECT 'users',
    (SELECT count(*) FROM users WHERE deleted_at IS NOT NULL),
    (SELECT count(*) FROM audit_log WHERE action = 'delete' AND entity_table = 'users'),
    (SELECT count(DISTINCT tenant_id) FROM users WHERE deleted_at IS NOT NULL),
    (SELECT min(deleted_at) FROM users WHERE deleted_at IS NOT NULL),
    (SELECT max(deleted_at) FROM users WHERE deleted_at IS NOT NULL)
  UNION ALL
  SELECT 'discounts',
    (SELECT count(*) FROM discounts WHERE deleted_at IS NOT NULL),
    (SELECT count(*) FROM audit_log WHERE action = 'delete' AND entity_table = 'discounts'),
    (SELECT count(DISTINCT tenant_id) FROM discounts WHERE deleted_at IS NOT NULL),
    (SELECT min(deleted_at) FROM discounts WHERE deleted_at IS NOT NULL),
    (SELECT max(deleted_at) FROM discounts WHERE deleted_at IS NOT NULL)
  UNION ALL
  SELECT 'coupons',
    (SELECT count(*) FROM coupons WHERE deleted_at IS NOT NULL),
    (SELECT count(*) FROM audit_log WHERE action = 'delete' AND entity_table = 'coupons'),
    (SELECT count(DISTINCT tenant_id) FROM coupons WHERE deleted_at IS NOT NULL),
    (SELECT min(deleted_at) FROM coupons WHERE deleted_at IS NOT NULL),
    (SELECT max(deleted_at) FROM coupons WHERE deleted_at IS NOT NULL)
  UNION ALL
  SELECT 'campaigns',
    (SELECT count(*) FROM campaigns WHERE deleted_at IS NOT NULL),
    (SELECT count(*) FROM audit_log WHERE action = 'delete' AND entity_table = 'campaigns'),
    (SELECT count(DISTINCT tenant_id) FROM campaigns WHERE deleted_at IS NOT NULL),
    (SELECT min(deleted_at) FROM campaigns WHERE deleted_at IS NOT NULL),
    (SELECT max(deleted_at) FROM campaigns WHERE deleted_at IS NOT NULL)
  UNION ALL
  SELECT 'promotions',
    (SELECT count(*) FROM promotions WHERE deleted_at IS NOT NULL),
    (SELECT count(*) FROM audit_log WHERE action = 'delete' AND entity_table = 'promotions'),
    (SELECT count(DISTINCT tenant_id) FROM promotions WHERE deleted_at IS NOT NULL),
    (SELECT min(deleted_at) FROM promotions WHERE deleted_at IS NOT NULL),
    (SELECT max(deleted_at) FROM promotions WHERE deleted_at IS NOT NULL)
) t
ORDER BY coverage_rate_pct ASC NULLS LAST, entity_table ASC NULLS LAST
