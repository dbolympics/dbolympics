WITH fx AS (
  SELECT quote_code, as_of, rate
  FROM exchange_rates
  WHERE base_code = 'EUR'
),
base AS (
  SELECT
    p.tenant_id AS tenant_id,
    p.currency_code AS currency_code,
    p.amount AS amount,
    p.amount_refunded AS amount_refunded,
    CAST(p.captured_at AS date) AS captured_date,
    CAST(EXTRACT(QUARTER FROM p.captured_at) AS int) AS q
  FROM payments p
  JOIN tenants t ON t.id = p.tenant_id
  WHERE (t.industry IS DISTINCT FROM 'Apparel & Footwear')
    AND p.status IN ('captured', 'refunded', 'partially_refunded')
    AND p.captured_at >= TIMESTAMP '2025-01-01'
    AND p.captured_at < TIMESTAMP '2026-01-01'
),
converted AS (
  SELECT
    b.tenant_id AS tenant_id,
    b.q AS q,
    CASE WHEN b.currency_code = 'EUR' THEN b.amount ELSE CAST({{divide_decimal(b.amount, fx.rate)}} AS NUMERIC(18,6)) END AS amount_eur,
    CASE WHEN b.currency_code = 'EUR' THEN b.amount_refunded ELSE CAST({{divide_decimal(b.amount_refunded, fx.rate)}} AS NUMERIC(18,6)) END AS refunded_eur
  FROM base b
  LEFT JOIN fx ON fx.quote_code = b.currency_code AND fx.as_of = b.captured_date
),
tenant_quarter AS (
  SELECT tenant_id, q,
         SUM(amount_eur) AS gross_eur,
         SUM(refunded_eur) AS refunded_eur,
         COUNT(*) AS cnt
  FROM converted
  GROUP BY tenant_id, q
),
tenant_total AS (
  SELECT tenant_id,
         SUM(gross_eur) AS gross_eur_fy,
         SUM(refunded_eur) AS refunded_eur_fy,
         SUM(cnt) AS cnt_fy
  FROM tenant_quarter
  GROUP BY tenant_id
),
qualified AS (
  SELECT tenant_id FROM tenant_total WHERE cnt_fy >= 20
),
pivoted AS (
  SELECT
    tt.tenant_id AS tenant_id,
    tt.gross_eur_fy AS gross_eur_fy,
    tt.refunded_eur_fy AS refunded_eur_fy,
    MAX(CASE WHEN tq.q = 1 THEN tq.gross_eur END) AS q1_gross,
    MAX(CASE WHEN tq.q = 1 THEN tq.refunded_eur END) AS q1_ref,
    MAX(CASE WHEN tq.q = 2 THEN tq.gross_eur END) AS q2_gross,
    MAX(CASE WHEN tq.q = 2 THEN tq.refunded_eur END) AS q2_ref,
    MAX(CASE WHEN tq.q = 3 THEN tq.gross_eur END) AS q3_gross,
    MAX(CASE WHEN tq.q = 3 THEN tq.refunded_eur END) AS q3_ref,
    MAX(CASE WHEN tq.q = 4 THEN tq.gross_eur END) AS q4_gross,
    MAX(CASE WHEN tq.q = 4 THEN tq.refunded_eur END) AS q4_ref
  FROM tenant_total tt
  JOIN tenant_quarter tq ON tq.tenant_id = tt.tenant_id
  WHERE tt.tenant_id IN (SELECT tenant_id FROM qualified)
  GROUP BY tt.tenant_id, tt.gross_eur_fy, tt.refunded_eur_fy
)
SELECT
  t.name AS merchant_name,
  t.industry AS vertical,
  p.gross_eur_fy AS gross_captured_eur_fy2025,
  {{divide_decimal(100.0 * p.q1_ref, NULLIF(p.q1_gross, 0))}} AS refund_rate_q1_pct,
  {{divide_decimal(100.0 * p.q2_ref, NULLIF(p.q2_gross, 0))}} AS refund_rate_q2_pct,
  {{divide_decimal(100.0 * p.q3_ref, NULLIF(p.q3_gross, 0))}} AS refund_rate_q3_pct,
  {{divide_decimal(100.0 * p.q4_ref, NULLIF(p.q4_gross, 0))}} AS refund_rate_q4_pct,
  {{divide_decimal(100.0 * p.refunded_eur_fy, NULLIF(p.gross_eur_fy, 0))}} AS refund_rate_fy2025_pct
FROM pivoted p
JOIN tenants t ON t.id = p.tenant_id
ORDER BY refund_rate_q3_pct DESC NULLS LAST, merchant_name ASC NULLS LAST, t.id NULLS LAST
{{fetch_first(30)}}
