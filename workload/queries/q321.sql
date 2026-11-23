SELECT
  bucket AS age_bucket,
  COUNT(DISTINCT ak_id) AS total_active_keys,
  COUNT(DISTINCT CASE WHEN has_admin_api THEN ak_id END) AS admin_api_scoped_keys,
  {{divide_decimal(100.0 * COUNT(DISTINCT CASE WHEN has_admin_api THEN ak_id END), NULLIF(COUNT(DISTINCT ak_id), 0))}} AS admin_api_share_pct,
  COUNT(DISTINCT CASE WHEN no_scope_recorded THEN ak_id END) AS no_scope_recorded_keys,
  COUNT(DISTINCT tenant_id) AS distinct_tenants
FROM (
  SELECT
    ak.id AS ak_id,
    ak.tenant_id AS tenant_id,
    CASE
      WHEN (DATE '2026-01-05' - CAST(ak.created_at AS DATE)) < 90 THEN 'Under 90 days'
      WHEN (DATE '2026-01-05' - CAST(ak.created_at AS DATE)) < 365 THEN '90 days-1 year'
      WHEN (DATE '2026-01-05' - CAST(ak.created_at AS DATE)) < 730 THEN '1-2 years'
      WHEN (DATE '2026-01-05' - CAST(ak.created_at AS DATE)) < 1460 THEN '2-4 years'
      ELSE '4+ years'
    END AS bucket,
    CASE
      WHEN (DATE '2026-01-05' - CAST(ak.created_at AS DATE)) < 90 THEN 1
      WHEN (DATE '2026-01-05' - CAST(ak.created_at AS DATE)) < 365 THEN 2
      WHEN (DATE '2026-01-05' - CAST(ak.created_at AS DATE)) < 730 THEN 3
      WHEN (DATE '2026-01-05' - CAST(ak.created_at AS DATE)) < 1460 THEN 4
      ELSE 5
    END AS bucket_order,
    CASE WHEN rl.has_admin_api = 1 THEN TRUE ELSE FALSE END AS has_admin_api,
    CASE WHEN rl.api_key_id IS NULL THEN TRUE ELSE FALSE END AS no_scope_recorded
  FROM api_keys ak
  LEFT JOIN (
    SELECT api_key_id, MAX(CASE WHEN limit_scope = 'admin_api' THEN 1 ELSE 0 END) AS has_admin_api
    FROM rate_limits
    WHERE api_key_id IS NOT NULL
    GROUP BY api_key_id
  ) rl ON rl.api_key_id = ak.id
  WHERE ak.status = 'active'
) sub
GROUP BY bucket, bucket_order
ORDER BY bucket_order NULLS LAST
