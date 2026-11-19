WITH t0_shopper_last_order AS (
  SELECT
    o0.tenant_id AS tenant_id,
    o0.user_id AS user_id,
    MAX(CAST(o0.placed_at AS DATE)) AS last_order_date
  FROM orders o0
  WHERE o0.placed_at IS NOT NULL
  GROUP BY o0.tenant_id, o0.user_id
),
t1_shopper_group AS (
  SELECT
    t0.tenant_id AS tenant_id,
    t0.user_id AS user_id,
    CASE
      WHEN t0.last_order_date BETWEEN (DATE '2025-12-31' - 365) AND (DATE '2025-12-31' - 180) THEN 'lapsed'
      WHEN t0.last_order_date BETWEEN (DATE '2025-12-31' - 90) AND DATE '2025-12-31' THEN 'active'
      ELSE NULL
    END AS shopper_group,
    CASE
      WHEN t0.last_order_date BETWEEN (DATE '2025-12-31' - 365) AND (DATE '2025-12-31' - 180) THEN t0.last_order_date
      ELSE DATE '2025-12-31'
    END AS reference_date
  FROM t0_shopper_last_order t0
),
t2_shoppers AS (
  SELECT t1.tenant_id AS tenant_id, t1.user_id AS user_id, t1.shopper_group AS shopper_group, t1.reference_date AS reference_date
  FROM t1_shopper_group t1
  WHERE t1.shopper_group IS NOT NULL
),
t3_windows AS (
  SELECT
    t2.tenant_id AS tenant_id,
    t2.user_id AS user_id,
    t2.shopper_group AS shopper_group,
    '0-90 days before reference' AS window_label,
    1 AS window_sort,
    t2.reference_date - 90 AS window_start,
    t2.reference_date AS window_end
  FROM t2_shoppers t2
  UNION ALL
  SELECT
    t2.tenant_id AS tenant_id,
    t2.user_id AS user_id,
    t2.shopper_group AS shopper_group,
    '91-180 days before reference' AS window_label,
    2 AS window_sort,
    t2.reference_date - 180 AS window_start,
    t2.reference_date - 91 AS window_end
  FROM t2_shoppers t2
),
t4_grain AS (
  SELECT DISTINCT t3.shopper_group AS shopper_group, t3.window_label AS window_label, t3.window_sort AS window_sort
  FROM t3_windows t3
),
t5_shopper_counts AS (
  SELECT t2.shopper_group AS shopper_group, COUNT(*) AS shopper_count
  FROM t2_shoppers t2
  GROUP BY t2.shopper_group
),
t6_tickets AS (
  SELECT
    t3.shopper_group AS shopper_group,
    t3.window_label AS window_label,
    COUNT(tk.id) AS ticket_count,
    AVG({{divide_decimal({{seconds_between(tk.created_at, tk.first_response_at)}}, 3600.0)}}) AS avg_first_response_hours
  FROM t3_windows t3
  JOIN tickets tk
    ON tk.tenant_id = t3.tenant_id
   AND tk.requester_user_id = t3.user_id
   AND CAST(tk.created_at AS DATE) BETWEEN t3.window_start AND t3.window_end
  GROUP BY t3.shopper_group, t3.window_label
),
t7_csat AS (
  SELECT
    t3.shopper_group AS shopper_group,
    t3.window_label AS window_label,
    AVG(CAST(cs.score AS NUMERIC(18,6))) AS avg_csat_score
  FROM t3_windows t3
  JOIN csat_responses cs
    ON cs.tenant_id = t3.tenant_id
   AND cs.respondent_user_id = t3.user_id
   AND CAST(cs.submitted_at AS DATE) BETWEEN t3.window_start AND t3.window_end
  GROUP BY t3.shopper_group, t3.window_label
)
SELECT
  t4.shopper_group AS shopper_group,
  t4.window_label AS window_before_reference,
  COALESCE(t5.shopper_count, 0) AS shopper_count,
  COALESCE(t6.ticket_count, 0) AS tickets,
  COALESCE(t6.avg_first_response_hours, 0) AS avg_first_response_hours,
  COALESCE(t7.avg_csat_score, 0) AS avg_csat_score
FROM t4_grain t4
LEFT JOIN t5_shopper_counts t5 ON t5.shopper_group = t4.shopper_group
LEFT JOIN t6_tickets t6 ON t6.shopper_group = t4.shopper_group AND t6.window_label = t4.window_label
LEFT JOIN t7_csat t7 ON t7.shopper_group = t4.shopper_group AND t7.window_label = t4.window_label
ORDER BY t4.shopper_group ASC NULLS LAST, t4.window_sort ASC NULLS LAST
