WITH paid_orders AS (
  SELECT tenant_id, user_id, id, placed_at,
         ROW_NUMBER() OVER (PARTITION BY tenant_id, user_id ORDER BY placed_at NULLS LAST, id NULLS LAST) AS rn
  FROM orders
  WHERE status NOT IN ('pending','cancelled')
    AND placed_at IS NOT NULL
),
first_orders AS (
  SELECT tenant_id, user_id, placed_at AS first_placed_at
  FROM paid_orders WHERE rn = 1
),
second_orders AS (
  SELECT tenant_id, user_id, placed_at AS second_placed_at
  FROM paid_orders WHERE rn = 2
),
joined AS (
  SELECT
    f.tenant_id AS tenant_id,
    f.user_id AS user_id,
    f.first_placed_at AS first_placed_at,
    s.second_placed_at AS second_placed_at,
    CAST({{date_trunc('month', f.first_placed_at)}} AS date) AS cohort_month,
    CASE WHEN s.second_placed_at IS NOT NULL
         THEN ({{date_diff_days(f.first_placed_at, s.second_placed_at)}})
    END AS days_to_second
  FROM first_orders f
  LEFT JOIN second_orders s
    ON f.tenant_id = s.tenant_id AND f.user_id = s.user_id
)
SELECT
  {{year_month(cohort_month)}} AS cohort_month,
  COUNT(*) AS first_time_buyers,
  100.0 * COUNT(*) FILTER (WHERE days_to_second <= 30) / COUNT(*) AS repeat_within_30_pct,
  100.0 * COUNT(*) FILTER (WHERE days_to_second <= 60) / COUNT(*) AS repeat_within_60_pct,
  100.0 * COUNT(*) FILTER (WHERE days_to_second <= 90) / COUNT(*) AS repeat_within_90_pct,
  COUNT(*) FILTER (WHERE second_placed_at IS NOT NULL) AS repeat_buyers,
  {{percentile_cont(0.5, days_to_second)}} AS median_days_to_second_order
FROM joined
WHERE cohort_month >= DATE '2023-01-01' AND cohort_month <= DATE '2025-10-01'
GROUP BY cohort_month
ORDER BY cohort_month NULLS LAST
