WITH orders_window AS (
  SELECT o.tenant_id AS tenant_id, o.id AS order_id, o.currency_code AS currency_code, o.grand_total AS grand_total, o.placed_at AS placed_at
  FROM orders o
  WHERE o.placed_at >= TIMESTAMP '2025-10-03'
    AND o.placed_at < TIMESTAMP '2026-01-01'
    AND o.status <> 'cancelled'
),
fx_rates AS (
  SELECT quote_code, as_of, rate
  FROM exchange_rates
  WHERE base_code = 'EUR'
),
orders_eur AS (
  SELECT ow.tenant_id AS tenant_id, ow.order_id AS order_id, CAST({{divide_decimal(ow.grand_total, fx.rate)}} AS NUMERIC(18,6)) AS revenue_eur
  FROM orders_window ow
  JOIN fx_rates fx
    ON fx.quote_code = ow.currency_code
   AND fx.as_of = CAST(ow.placed_at AS date)
),
tenant_revenue AS (
  SELECT tenant_id, SUM(revenue_eur) AS revenue_eur_total, COUNT(*) AS order_count
  FROM orders_eur
  GROUP BY tenant_id
),
top15 AS (
  SELECT tenant_id, revenue_eur_total, order_count
  FROM tenant_revenue
  ORDER BY revenue_eur_total DESC NULLS FIRST, tenant_id NULLS LAST
  {{fetch_first(15)}}
),
tickets_window AS (
  SELECT t.tenant_id AS tenant_id, t.id AS ticket_id,
    {{divide_decimal({{seconds_between(t.created_at, t.first_response_at)}}, 3600.0)}} AS first_response_hours,
    {{divide_decimal({{seconds_between(t.created_at, t.resolved_at)}}, 3600.0)}} AS resolution_hours
  FROM tickets t
  JOIN top15 ON top15.tenant_id = t.tenant_id
  WHERE t.created_at >= TIMESTAMP '2025-10-03'
    AND t.created_at < TIMESTAMP '2026-01-01'
),
tickets_agg AS (
  SELECT tenant_id,
    COUNT(*) AS ticket_count,
    AVG(first_response_hours) AS avg_first_response_hours,
    AVG(resolution_hours) AS avg_resolution_hours
  FROM tickets_window
  GROUP BY tenant_id
),
csat_window AS (
  SELECT c.tenant_id AS tenant_id, c.score AS score
  FROM csat_responses c
  JOIN top15 ON top15.tenant_id = c.tenant_id
  WHERE c.submitted_at >= TIMESTAMP '2025-10-03'
    AND c.submitted_at < TIMESTAMP '2026-01-01'
),
csat_agg AS (
  SELECT tenant_id, AVG(CAST(score AS NUMERIC(18,6))) AS csat_avg_score, COUNT(*) AS csat_response_count
  FROM csat_window
  GROUP BY tenant_id
)
SELECT
  tn.name AS merchant_name,
  tn.industry AS industry,
  COALESCE(ta.ticket_count, 0) AS tickets_last_90_days,
  {{divide_decimal(COALESCE(ta.ticket_count,0) * 100.0, NULLIF(top15.order_count,0))}} AS tickets_per_100_orders,
  ta.avg_first_response_hours AS avg_first_response_hours,
  ta.avg_resolution_hours AS avg_resolution_hours,
  ca.csat_avg_score AS csat_avg_score,
  COALESCE(ca.csat_response_count, 0) AS csat_response_count
FROM top15
JOIN tenants tn ON tn.id = top15.tenant_id
LEFT JOIN tickets_agg ta ON ta.tenant_id = top15.tenant_id
LEFT JOIN csat_agg ca ON ca.tenant_id = top15.tenant_id
ORDER BY tickets_last_90_days DESC NULLS FIRST, top15.tenant_id ASC NULLS LAST
{{fetch_first(50)}}
