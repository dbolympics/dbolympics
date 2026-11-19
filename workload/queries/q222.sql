with redemptions as (
  select
    cr.coupon_id AS coupon_id,
    c.code as coupon_code,
    d.kind as discount_kind,
    cr.user_id AS user_id,
    cr.redeemed_at AS redeemed_at,
    CAST({{divide_decimal(cr.discount_amount, er.rate)}} AS NUMERIC(18,6)) as discount_amount_eur,
    row_number() over (partition by cr.coupon_id, cr.user_id order by cr.redeemed_at asc NULLS LAST, cr.id asc NULLS LAST) as rn
  from coupon_redemptions cr
  join coupons c on c.id = cr.coupon_id
  join discounts d on d.id = c.discount_id
  join exchange_rates er
    on er.base_code = 'EUR'
   and er.quote_code = cr.currency_code
   and er.as_of = cast(cr.redeemed_at as date)
  where cr.redeemed_at >= timestamp '2025-01-01'
    and cr.redeemed_at < timestamp '2026-01-01'
)
select
  coupon_code,
  discount_kind,
  count(*) as total_redemptions_2025,
  count(distinct user_id) as distinct_customers_2025,
  count(*) - count(distinct user_id) as redemptions_beyond_first_use,
  sum(discount_amount_eur) as total_discount_amount_eur,
  sum(discount_amount_eur) filter (where rn > 1) as discount_amount_beyond_first_use_eur,
  {{divide_decimal(100.0 * sum(discount_amount_eur) filter (where rn > 1), nullif(sum(discount_amount_eur), 0))}} as pct_of_discount_from_repeat_use
from redemptions
group by coupon_id, coupon_code, discount_kind
order by discount_amount_beyond_first_use_eur desc nulls last, coupon_code asc NULLS LAST, coupon_id asc NULLS LAST
{{fetch_first(20)}}
