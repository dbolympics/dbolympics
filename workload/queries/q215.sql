WITH t0 AS (
  SELECT t1.id AS tenant_id
  FROM tenants t1
  WHERE t1.name = 'Deskline Supplies'
),
t2 AS (
  SELECT
    s.carrier AS carrier,
    s.service_level AS service_level,
    s.shipping_cost AS shipping_cost,
    COALESCE(s.currency_code, tn.default_currency_code) AS ship_currency_code,
    s.shipped_at AS shipped_at
  FROM shipments s
  JOIN fulfillments f ON f.id = s.fulfillment_id
  JOIN orders o ON o.id = f.order_id
  JOIN t0 ON t0.tenant_id = s.tenant_id
  JOIN tenants tn ON tn.id = s.tenant_id
  WHERE s.shipped_at >= TIMESTAMP '2025-01-01'
    AND s.shipped_at < TIMESTAMP '2026-01-01'
),
t3 AS (
  SELECT
    t2.carrier AS carrier,
    t2.service_level AS service_level,
    t2.shipping_cost AS shipping_cost,
    CASE
      WHEN t2.ship_currency_code = 'EUR' THEN CAST(t2.shipping_cost AS NUMERIC(18,6))
      ELSE CAST({{divide_decimal(t2.shipping_cost, er.rate)}} AS NUMERIC(18,6))
    END AS shipping_cost_eur
  FROM t2
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
    AND er.quote_code = t2.ship_currency_code
    AND er.as_of = CAST(t2.shipped_at AS date)
)
SELECT
  t3.carrier AS carrier,
  t3.service_level AS service_level,
  COUNT(*) AS shipment_count_2025,
  SUM(t3.shipping_cost_eur) AS total_shipping_cost_eur,
  AVG(t3.shipping_cost_eur) AS avg_shipping_cost_eur,
  MIN(t3.shipping_cost_eur) AS min_shipping_cost_eur,
  MAX(t3.shipping_cost_eur) AS max_shipping_cost_eur
FROM t3
GROUP BY t3.carrier, t3.service_level
ORDER BY total_shipping_cost_eur DESC NULLS FIRST, t3.carrier ASC NULLS LAST, t3.service_level ASC NULLS LAST
