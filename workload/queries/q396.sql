SELECT
  w.name AS warehouse_name,
  t.name AS tenant_name,
  (SELECT COALESCE(SUM(si.quantity), 0)
     FROM stock_items si
     JOIN stock_locations sl ON sl.id = si.stock_location_id
    WHERE sl.warehouse_id = w.id) AS total_stock_on_hand,
  (SELECT COUNT(DISTINCT si.variant_id)
     FROM stock_items si
     JOIN stock_locations sl ON sl.id = si.stock_location_id
    WHERE sl.warehouse_id = w.id
      AND si.quantity > 0) AS distinct_variants_stocked,
  (
 {{divide_decimal(CAST((SELECT COALESCE(SUM(si.quantity), 0)
    FROM stock_items si
    JOIN stock_locations sl ON sl.id = si.stock_location_id
   WHERE sl.warehouse_id = w.id) AS numeric(18,6)), NULLIF(
   (SELECT COALESCE(SUM(si2.quantity), 0)
      FROM stock_items si2
      JOIN stock_locations sl2 ON sl2.id = si2.stock_location_id
      JOIN warehouses w2 ON w2.id = sl2.warehouse_id
     WHERE w2.tenant_id = w.tenant_id), 0
 ))}} * 100
) AS pct_of_tenant_total_stock_units
FROM warehouses w
JOIN tenants t ON t.id = w.tenant_id
WHERE (t.name, w.name) IN (
  VALUES
    ('Oakhurst Tailoring', 'Aarhus Warehouse'),
    ('Cragsley Outfitters', 'Boston Warehouse'),
    ('Studio Vrij', 'Brussels Warehouse'),
    ('Cragsley Outfitters', 'Calgary Warehouse'),
    ('Thistlecombe', 'Glasgow Warehouse'),
    ('Studio Vrij', 'Groningen Warehouse'),
    ('Marrowby & Vane', 'Limerick Warehouse'),
    ('Marrowby & Vane', 'Preston Warehouse'),
    ('Rue Lafayette Studio', 'Toulouse Warehouse'),
    ('Velvet Ash', 'Uppsala Warehouse')
)
ORDER BY total_stock_on_hand DESC NULLS FIRST, warehouse_name NULLS LAST, w.id NULLS LAST
