select
  currency_code,
  count(*) as payout_count,
  sum(gross_amount) as gross_native_total,
  sum(fee_amount) as fee_native_total,
  sum(net_amount) as net_native_total,
  sum(net_amount) - (sum(gross_amount) - sum(fee_amount)) as net_check_diff_native,
  {{divide_decimal((sum(net_amount) - (sum(gross_amount) - sum(fee_amount))), nullif(sum(gross_amount), 0))}} * 100 as net_check_diff_pct
from payouts
where created_at >= timestamp '2023-01-01'
  and created_at < timestamp '2026-01-01'
group by currency_code
order by payout_count desc NULLS FIRST, currency_code NULLS LAST
