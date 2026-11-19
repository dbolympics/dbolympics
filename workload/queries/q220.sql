WITH base_payments AS (
  SELECT
    p.id AS payment_id,
    p.tenant_id AS tenant_id,
    p.order_id AS order_id,
    p.currency_code AS currency_code,
    p.amount AS payment_amount,
    p.amount_refunded AS amount_refunded,
    p.captured_at AS captured_at
  FROM payments p
  WHERE p.status IN ('captured','refunded','partially_refunded')
    AND p.captured_at >= DATE '2025-01-01'
    AND p.captured_at < DATE '2026-01-01'
    AND p.order_id IS NOT NULL
),
fx_rates AS (
  SELECT quote_code, as_of, rate
  FROM exchange_rates
  WHERE base_code = 'EUR'
),
payments_with_eur AS (
  SELECT
    bp.*,
    CASE WHEN bp.currency_code = 'EUR' THEN CAST(bp.payment_amount AS NUMERIC(18,6))
         ELSE CAST({{divide_decimal(bp.payment_amount, fx.rate)}} AS NUMERIC(18,6)) END AS payment_amount_eur
  FROM base_payments bp
  LEFT JOIN fx_rates fx
    ON fx.quote_code = bp.currency_code
   AND fx.as_of = CAST(bp.captured_at AS date)
),
payout_agg AS (
  SELECT payment_id, amount AS payout_item_amount, fee_amount AS payout_item_fee_amount
  FROM payout_items
),
ledger_agg AS (
  SELECT
    payment_id,
    SUM(CASE WHEN direction = 'debit' THEN amount ELSE 0 END) AS ledger_debit_total,
    SUM(CASE WHEN direction = 'credit' THEN amount ELSE 0 END) AS ledger_credit_total
  FROM ledger_entries
  WHERE payment_id IS NOT NULL
  GROUP BY payment_id
),
enriched AS (
  SELECT
    pwe.payment_id AS payment_id,
    pwe.tenant_id AS tenant_id,
    pwe.order_id AS order_id,
    pwe.currency_code AS currency_code,
    pwe.payment_amount AS payment_amount,
    pwe.amount_refunded AS amount_refunded,
    pwe.payment_amount_eur AS payment_amount_eur,
    pa.payout_item_amount AS payout_item_amount,
    pa.payout_item_fee_amount AS payout_item_fee_amount,
    la.ledger_debit_total AS ledger_debit_total,
    la.ledger_credit_total AS ledger_credit_total
  FROM payments_with_eur pwe
  LEFT JOIN payout_agg pa ON pa.payment_id = pwe.payment_id
  LEFT JOIN ledger_agg la ON la.payment_id = pwe.payment_id
),
tenant_top_payment AS (
  SELECT e.*, ROW_NUMBER() OVER (PARTITION BY e.tenant_id ORDER BY e.payment_amount_eur DESC NULLS FIRST, e.payment_id NULLS LAST) AS tenant_rn
  FROM enriched e
),
largest_sample AS (
  SELECT
    payment_id, tenant_id, order_id, currency_code, payment_amount, amount_refunded,
    payment_amount_eur, payout_item_amount, payout_item_fee_amount,
    ledger_debit_total, ledger_credit_total, 'A_LARGEST' AS sample_category
  FROM tenant_top_payment
  WHERE tenant_rn = 1
  ORDER BY payment_amount_eur DESC NULLS FIRST, payment_id NULLS LAST
  {{fetch_first(8)}}
),
refund_candidates AS (
  SELECT
    e.*,
    CASE WHEN e.amount_refunded = e.payment_amount THEN 'FULL' ELSE 'PARTIAL' END AS refund_kind
  FROM enriched e
  WHERE e.amount_refunded > 0
),
refund_ranked AS (
  SELECT
    rc.*,
    ROW_NUMBER() OVER (PARTITION BY rc.tenant_id, rc.refund_kind ORDER BY rc.amount_refunded DESC NULLS FIRST, rc.payment_id NULLS LAST) AS tenant_refund_rn
  FROM refund_candidates rc
),
refund_sample AS (
  (SELECT payment_id, tenant_id, order_id, currency_code, payment_amount, amount_refunded,
          payment_amount_eur, payout_item_amount, payout_item_fee_amount,
          ledger_debit_total, ledger_credit_total, 'B_REFUND' AS sample_category
   FROM refund_ranked WHERE refund_kind = 'FULL' AND tenant_refund_rn = 1
   ORDER BY amount_refunded DESC NULLS FIRST, payment_id NULLS LAST {{fetch_first(4)}})
  UNION ALL
  (SELECT payment_id, tenant_id, order_id, currency_code, payment_amount, amount_refunded,
          payment_amount_eur, payout_item_amount, payout_item_fee_amount,
          ledger_debit_total, ledger_credit_total, 'B_REFUND' AS sample_category
   FROM refund_ranked WHERE refund_kind = 'PARTIAL' AND tenant_refund_rn = 1
   ORDER BY amount_refunded DESC NULLS FIRST, payment_id NULLS LAST {{fetch_first(4)}})
),
tiled AS (
  SELECT e.*, NTILE(9) OVER (ORDER BY e.payment_id NULLS LAST) AS tile
  FROM enriched e
),
tiled_ranked AS (
  SELECT
    t.*,
    ROW_NUMBER() OVER (PARTITION BY t.tile ORDER BY (t.payout_item_amount IS NULL) DESC NULLS FIRST, t.payment_id NULLS LAST) AS tile_rn
  FROM tiled t
),
typical_sample AS (
  SELECT
    payment_id, tenant_id, order_id, currency_code, payment_amount, amount_refunded,
    payment_amount_eur, payout_item_amount, payout_item_fee_amount,
    ledger_debit_total, ledger_credit_total, 'C_TYPICAL' AS sample_category
  FROM tiled_ranked
  WHERE tile_rn = 1
),
all_samples AS (
  SELECT * FROM largest_sample
  UNION ALL
  SELECT * FROM refund_sample
  UNION ALL
  SELECT * FROM typical_sample
),
final AS (
  SELECT
    s.payment_id AS payment_id,
    o.order_number AS order_number,
    t.name AS merchant_name,
    s.currency_code AS currency_code,
    s.payment_amount AS payment_amount,
    s.amount_refunded AS amount_refunded,
    (s.payment_amount - s.amount_refunded) AS net_amount,
    s.payout_item_amount AS payout_item_amount,
    s.payout_item_fee_amount AS payout_item_fee_amount,
    (s.payout_item_amount - s.payout_item_fee_amount) AS payout_net_amount,
    (COALESCE(s.ledger_debit_total,0) - COALESCE(s.ledger_credit_total,0)) AS ledger_debit_credit_diff,
    s.ledger_credit_total AS ledger_credit_total,
    CASE
      WHEN s.payout_item_amount IS NULL THEN 'PENDING PAYOUT'
      WHEN (s.payment_amount - s.amount_refunded) = s.payout_item_amount
           AND (COALESCE(s.ledger_debit_total,0) - COALESCE(s.ledger_credit_total,0)) = 0
        THEN 'OK'
      ELSE 'CHECK'
    END AS reconciliation_flag,
    s.sample_category AS sample_category
  FROM all_samples s
  JOIN orders o ON o.id = s.order_id
  JOIN tenants t ON t.id = s.tenant_id
)
SELECT
  order_number,
  merchant_name,
  currency_code,
  payment_amount,
  amount_refunded,
  net_amount,
  payout_item_amount,
  payout_item_fee_amount,
  payout_net_amount,
  ledger_debit_credit_diff,
  ledger_credit_total,
  reconciliation_flag
FROM final
ORDER BY
  CASE sample_category WHEN 'A_LARGEST' THEN 1 WHEN 'B_REFUND' THEN 2 ELSE 3 END NULLS LAST,
  payment_amount DESC NULLS FIRST,
  payment_id NULLS LAST
