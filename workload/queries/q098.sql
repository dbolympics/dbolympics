WITH currencies_used AS (
  SELECT DISTINCT currency_code FROM orders
),
tenant_counts AS (
  SELECT default_currency_code AS currency_code, COUNT(DISTINCT id) AS tenant_count
  FROM tenants
  GROUP BY default_currency_code
),
orders_2025 AS (
  SELECT o.currency_code AS currency_code,
    SUM(
      CASE WHEN o.currency_code = 'EUR' THEN CAST(o.grand_total AS NUMERIC(18,6))
           ELSE CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6)) END
    ) AS orders_2025_total_eur
  FROM orders o
  LEFT JOIN exchange_rates er
    ON er.base_code = 'EUR'
   AND er.quote_code = o.currency_code
   AND er.as_of = CAST(o.placed_at AS date)
  WHERE o.status <> 'cancelled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
  GROUP BY o.currency_code
),
rate_2023 AS (
  SELECT cu.currency_code AS currency_code,
    COALESCE(
      (SELECT er.rate FROM exchange_rates er WHERE er.base_code='EUR' AND er.quote_code=cu.currency_code AND er.as_of = DATE '2023-01-02'),
      (SELECT er.rate FROM exchange_rates er WHERE er.base_code='EUR' AND er.quote_code=cu.currency_code AND er.as_of >= DATE '2023-01-01' AND er.as_of < DATE '2023-02-01' ORDER BY er.as_of ASC NULLS LAST {{fetch_first(1)}})
    ) AS rate_early
  FROM currencies_used cu
),
rate_2025 AS (
  SELECT cu.currency_code AS currency_code,
    (SELECT er.rate FROM exchange_rates er WHERE er.base_code='EUR' AND er.quote_code=cu.currency_code AND er.as_of = DATE '2025-12-31') AS rate_late
  FROM currencies_used cu
)
SELECT
  cu.currency_code AS currency_code,
  COALESCE(tc.tenant_count,0) AS tenant_count,
  COALESCE(o25.orders_2025_total_eur,0) AS orders_2025_total_eur,
  CASE WHEN cu.currency_code='EUR' THEN 1.0 ELSE r23.rate_early END AS rate_eur_to_currency_2023_01_02,
  CASE WHEN cu.currency_code='EUR' THEN 1.0 ELSE r25.rate_late END AS rate_eur_to_currency_2025_12_31,
  CASE WHEN cu.currency_code='EUR' THEN 0
  ELSE ( {{divide_decimal((r25.rate_late - r23.rate_early), NULLIF(r23.rate_early,0))}} ) * 100
  END AS pct_rate_change
FROM currencies_used cu
LEFT JOIN tenant_counts tc ON tc.currency_code = cu.currency_code
LEFT JOIN orders_2025 o25 ON o25.currency_code = cu.currency_code
LEFT JOIN rate_2023 r23 ON r23.currency_code = cu.currency_code
LEFT JOIN rate_2025 r25 ON r25.currency_code = cu.currency_code
ORDER BY orders_2025_total_eur DESC NULLS LAST, cu.currency_code NULLS LAST
