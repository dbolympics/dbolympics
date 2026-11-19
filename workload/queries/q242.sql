WITH q_orders AS (
  SELECT o.id AS order_id, o.tenant_id AS tenant_id, o.placed_at AS placed_at
  FROM orders o
  WHERE o.status = 'fulfilled'
    AND o.placed_at >= DATE '2025-01-01'
    AND o.placed_at < DATE '2026-01-01'
),
fulfillment_counts AS (
  SELECT f.order_id AS order_id, f.tenant_id AS tenant_id, COUNT(*) AS fulfillment_count
  FROM fulfillments f
  JOIN q_orders qo ON qo.order_id = f.order_id AND qo.tenant_id = f.tenant_id
  GROUP BY f.order_id, f.tenant_id
),
single_fulfillment AS (
  SELECT fc.order_id AS order_id, fc.tenant_id AS tenant_id
  FROM fulfillment_counts fc
  WHERE fc.fulfillment_count = 1
),
fulfillment_shipment_counts AS (
  SELECT f.id AS fulfillment_id, f.order_id AS order_id, f.tenant_id AS tenant_id, COUNT(s.id) AS shipment_count
  FROM fulfillments f
  JOIN single_fulfillment sf ON sf.order_id = f.order_id AND sf.tenant_id = f.tenant_id
  LEFT JOIN shipments s ON s.fulfillment_id = f.id AND s.tenant_id = f.tenant_id
  GROUP BY f.id, f.order_id, f.tenant_id
),
qualifying_fulfillments AS (
  SELECT fsc.fulfillment_id AS fulfillment_id, fsc.order_id AS order_id, fsc.tenant_id AS tenant_id
  FROM fulfillment_shipment_counts fsc
  WHERE fsc.shipment_count = 1
),
order_shipment AS (
  SELECT qf.order_id AS order_id, qf.tenant_id AS tenant_id, s.carrier AS carrier, s.delivered_at AS delivered_at
  FROM qualifying_fulfillments qf
  JOIN shipments s ON s.fulfillment_id = qf.fulfillment_id AND s.tenant_id = qf.tenant_id
  WHERE s.delivered_at IS NOT NULL
),
order_detail AS (
  SELECT
    qo.order_id AS order_id,
    qo.tenant_id AS tenant_id,
    qo.placed_at AS placed_at,
    os.carrier AS carrier,
    os.delivered_at AS delivered_at,
    {{divide_decimal({{seconds_between(qo.placed_at, os.delivered_at)}}, 86400.0)}} AS delivery_days
  FROM q_orders qo
  JOIN order_shipment os ON os.order_id = qo.order_id AND os.tenant_id = qo.tenant_id
),
order_detail_grouped AS (
  SELECT
    od.order_id AS order_id,
    od.tenant_id AS tenant_id,
    od.placed_at AS placed_at,
    od.delivery_days AS delivery_days,
    CASE
      WHEN od.carrier IN ('Albion Parcel', 'Landfall Freight', 'Lowlands Express') THEN od.carrier
      ELSE 'All other carriers'
    END AS carrier_group
  FROM order_detail od
),
with_quarter AS (
  SELECT
    odg.order_id AS order_id,
    odg.delivery_days AS delivery_days,
    odg.carrier_group AS carrier_group,
    cd.year_num AS year_num,
    cd.quarter_num AS quarter_num
  FROM order_detail_grouped odg
  JOIN calendar_days cd ON cd.calendar_date = CAST(odg.placed_at AS DATE)
),
quarter_totals AS (
  SELECT year_num, quarter_num, COUNT(*) AS total_orders
  FROM with_quarter
  GROUP BY year_num, quarter_num
),
group_agg AS (
  SELECT
    year_num,
    quarter_num,
    carrier_group,
    COUNT(*) AS orders_fully_delivered,
    AVG(delivery_days) AS avg_delivery_days,
    AVG(CASE WHEN delivery_days <= 5 THEN 1.0 ELSE 0.0 END) * 100 AS pct_within_5_days
  FROM with_quarter
  GROUP BY year_num, quarter_num, carrier_group
)
SELECT
  ga.carrier_group AS carrier_group,
  CONCAT(CAST(ga.year_num AS VARCHAR), '-Q', CAST(ga.quarter_num AS VARCHAR)) AS quarter,
  ga.orders_fully_delivered AS orders_fully_delivered,
  ga.avg_delivery_days AS avg_delivery_days,
  ga.pct_within_5_days AS pct_within_5_days,
  {{divide_decimal(ga.orders_fully_delivered * 100.0, qt.total_orders)}} AS share_of_quarter_orders_pct
FROM group_agg ga
JOIN quarter_totals qt ON qt.year_num = ga.year_num AND qt.quarter_num = ga.quarter_num
ORDER BY
  ga.quarter_num ASC NULLS LAST,
  CASE ga.carrier_group
    WHEN 'Albion Parcel' THEN 1
    WHEN 'Landfall Freight' THEN 2
    WHEN 'Lowlands Express' THEN 3
    ELSE 4
  END ASC NULLS LAST,
  ga.year_num NULLS LAST
