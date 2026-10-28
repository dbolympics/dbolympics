WITH refund_base AS (
  SELECT
    t_pr.id AS refund_id,
    t_pr.tenant_id AS tenant_id,
    t_o.id AS order_id,
    t_o.user_id AS user_id,
    t_pr.created_at AS created_at,
    t_pr.processed_at AS processed_at,
    CASE
      WHEN t_pr.processed_at <= t_pr.created_at + INTERVAL '7 days' THEN 'fast'
      ELSE 'slow'
    END AS refund_group
  FROM payment_refunds t_pr
  JOIN payments t_pm ON t_pm.id = t_pr.payment_id
  JOIN orders t_o ON t_o.id = t_pm.order_id
  WHERE t_pr.status = 'succeeded'
    AND t_pr.processed_at IS NOT NULL
    AND t_pr.created_at IS NOT NULL
),
grain AS (
  SELECT DISTINCT t0.refund_group AS refund_group
  FROM refund_base t0
),
m_count_days AS (
  SELECT
    t1.refund_group AS refund_group,
    COUNT(*) AS refund_count,
    AVG({{seconds_between(t1.created_at, t1.processed_at)}} / 86400.0) AS avg_processing_days
  FROM refund_base t1
  GROUP BY t1.refund_group
),
repeat_flags AS (
  SELECT
    t2.refund_id AS refund_id,
    t2.refund_group AS refund_group,
    CASE WHEN EXISTS (
      SELECT 1
      FROM orders t2o
      WHERE t2o.tenant_id = t2.tenant_id
        AND t2o.user_id = t2.user_id
        AND t2o.id <> t2.order_id
        AND t2o.status <> 'cancelled'
        AND t2o.placed_at IS NOT NULL
        AND t2o.placed_at BETWEEN t2.processed_at AND (t2.processed_at + INTERVAL '90 days')
    ) THEN 1 ELSE 0 END AS has_repeat_order
  FROM refund_base t2
),
m_repeat AS (
  SELECT
    t3.refund_group AS refund_group,
    AVG(CAST(t3.has_repeat_order AS NUMERIC(18,6))) * 100.0 AS pct_with_repeat_order
  FROM repeat_flags t3
  GROUP BY t3.refund_group
),
csat_per_refund AS (
  SELECT
    t4.refund_id AS refund_id,
    t4.refund_group AS refund_group,
    (
      SELECT AVG(CAST(t4c.score AS NUMERIC(18,6)))
      FROM csat_responses t4c
      WHERE t4c.tenant_id = t4.tenant_id
        AND t4c.respondent_user_id = t4.user_id
        AND t4c.submitted_at BETWEEN t4.processed_at AND (t4.processed_at + INTERVAL '30 days')
    ) AS csat_avg_for_refund
  FROM refund_base t4
),
m_csat AS (
  SELECT
    t5.refund_group AS refund_group,
    AVG(t5.csat_avg_for_refund) AS avg_csat_score
  FROM csat_per_refund t5
  GROUP BY t5.refund_group
)
SELECT
  t_g.refund_group AS refund_speed_group,
  COALESCE(t_cd.refund_count, 0) AS refund_count,
  COALESCE(t_cd.avg_processing_days, 0) AS avg_processing_days,
  COALESCE(t_rp.pct_with_repeat_order, 0) AS pct_with_order_within_90d,
  COALESCE(t_cs.avg_csat_score, 0) AS avg_csat_within_30d
FROM grain t_g
LEFT JOIN m_count_days t_cd ON t_cd.refund_group = t_g.refund_group
LEFT JOIN m_repeat t_rp ON t_rp.refund_group = t_g.refund_group
LEFT JOIN m_csat t_cs ON t_cs.refund_group = t_g.refund_group
ORDER BY t_g.refund_group NULLS LAST
