with tenant_rev as (
  select
    o.tenant_id AS tenant_id,
    sum(CAST({{divide_decimal(o.grand_total, er.rate)}} AS NUMERIC(18,6))) as revenue_eur
  from orders o
  join exchange_rates er
    on er.base_code = 'EUR'
   and er.quote_code = o.currency_code
   and er.as_of = CAST(o.placed_at AS date)
  where o.placed_at >= timestamp '2025-01-01'
    and o.placed_at < timestamp '2026-01-01'
    and o.status <> 'cancelled'
  group by o.tenant_id
),
ranked as (
  select
    t.id as tenant_id,
    coalesce(tr.revenue_eur, 0) as revenue_eur,
    row_number() over (order by coalesce(tr.revenue_eur,0) desc NULLS FIRST, t.id NULLS LAST) as rnk
  from tenants t
  left join tenant_rev tr on tr.tenant_id = t.id
  where t.deleted_at is null
),
tiered as (
  select
    tenant_id,
    revenue_eur,
    case
      when rnk <= 10 then 'Top 10'
      when rnk <= 30 then 'Next 20'
      else 'Rest'
    end as tier,
    case
      when rnk <= 10 then 1
      when rnk <= 30 then 2
      else 3
    end as tier_order
  from ranked
),
tier_agg as (
  select tier, tier_order,
    count(distinct tenant_id) as merchant_count,
    sum(revenue_eur) as tier_revenue
  from tiered
  group by tier, tier_order
),
active_products as (
  select p.id as product_id, p.tenant_id AS tenant_id
  from products p
  where p.status = 'active' and p.deleted_at is null
),
product_metrics as (
  select
    ap.product_id AS product_id,
    ap.tenant_id AS tenant_id,
    (select count(*) from product_variants pv
       where pv.product_id = ap.product_id and pv.is_active = true and pv.deleted_at is null) as variant_count,
    (select count(*) from product_categories pc
       where pc.product_id = ap.product_id) as category_count,
    exists (select 1 from product_media pm
       where pm.product_id = ap.product_id and pm.is_primary = true) as has_primary_image,
    (select count(*) from product_media pm2
       where pm2.product_id = ap.product_id) as media_count,
    exists (
       select 1 from collection_products cp
       join collections c on c.id = cp.collection_id and c.deleted_at is null
       where cp.product_id = ap.product_id
    ) as in_collection
  from active_products ap
),
product_agg as (
  select ti.tier AS tier,
    count(pm.product_id) as active_products,
    avg(cast(pm.variant_count as numeric(18,6))) as avg_variants,
    avg(cast(pm.category_count as numeric(18,6))) as avg_categories,
    avg(case when pm.has_primary_image then 1.0 else 0.0 end) as pct_primary_image,
    avg(cast(pm.media_count as numeric(18,6))) as avg_media,
    avg(case when pm.in_collection then 1.0 else 0.0 end) as pct_in_collection
  from tiered ti
  left join product_metrics pm on pm.tenant_id = ti.tenant_id
  group by ti.tier
)
select
  ta.tier AS tier,
  ta.merchant_count AS merchant_count,
  {{divide_decimal(CAST(pa.active_products AS numeric(18,6)), NULLIF(ta.merchant_count, 0))}} as avg_active_products_per_merchant,
  pa.avg_variants as avg_variants_per_product,
  pa.avg_categories as avg_categories_per_product,
  (100.0*pa.pct_primary_image) as pct_products_with_primary_image,
  pa.avg_media as avg_media_count_per_product,
  (100.0*pa.pct_in_collection) as pct_active_products_in_a_collection,
  ({{divide_decimal(100.0*ta.tier_revenue, NULLIF(sum(ta.tier_revenue) over (), 0))}}) as revenue_share_pct
from tier_agg ta
join product_agg pa on pa.tier = ta.tier
order by ta.tier_order NULLS LAST
