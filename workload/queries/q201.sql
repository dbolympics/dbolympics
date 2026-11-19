WITH base AS (
  SELECT
    t.id AS ticket_id,
    t.created_at AS created_at,
    t.first_response_at AS first_response_at,
    cd.day_name AS day_name,
    cd.iso_day_of_week AS iso_day_of_week,
    CAST(EXTRACT(HOUR FROM t.created_at) AS int) AS hr
  FROM tickets t
  JOIN calendar_days cd ON cd.calendar_date = CAST(t.created_at AS date)
  WHERE t.created_at >= DATE '2025-01-01'
    AND t.created_at < DATE '2026-01-01'
    AND t.sla_policy_id IS NOT NULL
),
bucketed AS (
  SELECT
    ticket_id,
    created_at,
    first_response_at,
    day_name,
    iso_day_of_week,
    CASE
      WHEN hr >= 0 AND hr < 6 THEN 'Night (00-06)'
      WHEN hr >= 6 AND hr < 12 THEN 'Morning (06-12)'
      WHEN hr >= 12 AND hr < 18 THEN 'Afternoon (12-18)'
      ELSE 'Evening (18-24)'
    END AS time_of_day_bucket,
    CASE
      WHEN hr >= 0 AND hr < 6 THEN 1
      WHEN hr >= 6 AND hr < 12 THEN 2
      WHEN hr >= 12 AND hr < 18 THEN 3
      ELSE 4
    END AS bucket_order
  FROM base
),
breaches AS (
  SELECT
    ticket_id,
    MAX(CASE WHEN breach_kind = 'first_response' THEN 1 ELSE 0 END) AS fr_breach,
    MAX(CASE WHEN breach_kind = 'resolution' THEN 1 ELSE 0 END) AS res_breach
  FROM sla_breaches
  GROUP BY ticket_id
),
joined AS (
  SELECT
    b.*,
    COALESCE(br.fr_breach, 0) AS fr_breach,
    COALESCE(br.res_breach, 0) AS res_breach
  FROM bucketed b
  LEFT JOIN breaches br ON br.ticket_id = b.ticket_id
)
SELECT
  day_name AS day_of_week,
  time_of_day_bucket,
  COUNT(*) AS ticket_count,
  {{divide_decimal(100.0 * SUM(fr_breach), COUNT(*))}} AS first_response_breach_rate,
  {{divide_decimal(100.0 * SUM(res_breach), COUNT(*))}} AS resolution_breach_rate,
  AVG(CASE WHEN first_response_at IS NOT NULL
           THEN {{divide_decimal({{seconds_between(created_at, first_response_at)}}, 60.0)}}
      END) AS avg_first_response_minutes
FROM joined
GROUP BY day_name, iso_day_of_week, time_of_day_bucket, bucket_order
ORDER BY iso_day_of_week NULLS LAST, bucket_order NULLS LAST, day_name NULLS LAST
