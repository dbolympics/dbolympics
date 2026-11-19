SELECT 
  device_type,
  channel,
  COUNT(*) AS carts_started,
  SUM(CASE WHEN subtotal > 0 THEN 1 ELSE 0 END) AS carts_with_items,
  SUM(CASE WHEN order_id IS NOT NULL THEN 1 ELSE 0 END) AS orders_placed,
  SUM(CASE WHEN order_status IS NOT NULL AND order_status NOT IN ('pending','cancelled') THEN 1 ELSE 0 END) AS orders_paid,
  {{divide_decimal(100.0 * SUM(CASE WHEN subtotal > 0 THEN 1 ELSE 0 END), NULLIF(COUNT(*),0))}} AS cart_to_item_pct,
  {{divide_decimal(100.0 * SUM(CASE WHEN order_id IS NOT NULL THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN subtotal > 0 THEN 1 ELSE 0 END),0))}} AS item_to_order_pct,
  {{divide_decimal(100.0 * SUM(CASE WHEN order_status IS NOT NULL AND order_status NOT IN ('pending','cancelled') THEN 1 ELSE 0 END), NULLIF(SUM(CASE WHEN order_id IS NOT NULL THEN 1 ELSE 0 END),0))}} AS order_to_paid_pct,
  {{divide_decimal(100.0 * SUM(CASE WHEN order_status IS NOT NULL AND order_status NOT IN ('pending','cancelled') THEN 1 ELSE 0 END), NULLIF(COUNT(*),0))}} AS overall_cart_to_paid_pct
FROM (
  SELECT
    cb.cart_id AS cart_id,
    cb.subtotal AS subtotal,
    cb.device_type AS device_type,
    CASE
      WHEN cb.raw_channel = 'direct' THEN 'direct'
      WHEN cb.raw_channel = 'unknown' THEN 'unknown'
      WHEN cb.raw_channel IN (
        SELECT all_channels.raw_channel
        FROM (
          SELECT
            COALESCE(
              (SELECT CASE WHEN ws2.utm_source IS NULL OR TRIM(ws2.utm_source) = '' THEN 'direct' ELSE ws2.utm_source END
               FROM web_sessions ws2
               WHERE ws2.tenant_id = c2.tenant_id AND ws2.user_id = c2.user_id
                 AND ws2.started_at <= c2.created_at
                 AND CAST(ws2.started_at AS date) = CAST(c2.created_at AS date)
               ORDER BY ws2.started_at DESC NULLS FIRST, ws2.id DESC NULLS FIRST {{fetch_first(1)}}),
              'unknown'
            ) AS raw_channel
          FROM carts c2
          WHERE c2.created_at >= DATE '2025-10-01' AND c2.created_at < DATE '2026-01-01'
        ) all_channels
        WHERE all_channels.raw_channel NOT IN ('direct','unknown')
        GROUP BY all_channels.raw_channel
        ORDER BY COUNT(*) DESC NULLS FIRST, all_channels.raw_channel NULLS LAST
        {{fetch_first(6)}}
      ) THEN cb.raw_channel
      ELSE 'other'
    END AS channel,
    (SELECT o.id FROM orders o WHERE o.cart_id = cb.cart_id AND o.tenant_id = cb.tenant_id ORDER BY o.created_at DESC NULLS FIRST, o.id DESC NULLS FIRST {{fetch_first(1)}}) AS order_id,
    (SELECT o.status FROM orders o WHERE o.cart_id = cb.cart_id AND o.tenant_id = cb.tenant_id ORDER BY o.created_at DESC NULLS FIRST, o.id DESC NULLS FIRST {{fetch_first(1)}}) AS order_status
  FROM (
    SELECT
      c.id AS cart_id,
      c.tenant_id AS tenant_id,
      c.user_id AS user_id,
      c.created_at AS created_at,
      c.subtotal AS subtotal,
      COALESCE(
        (SELECT CASE
                  WHEN ws.user_agent ILIKE '%tablet%' OR ws.user_agent ILIKE '%ipad%' THEN 'tablet'
                  WHEN ws.user_agent ILIKE '%mobile%' OR ws.user_agent ILIKE '%android%' OR ws.user_agent ILIKE '%iphone%' THEN 'mobile'
                  WHEN ws.user_agent IS NOT NULL THEN 'desktop'
                  ELSE 'unknown'
                END
         FROM web_sessions ws
         WHERE ws.tenant_id = c.tenant_id AND ws.user_id = c.user_id
           AND ws.started_at <= c.created_at
           AND CAST(ws.started_at AS date) = CAST(c.created_at AS date)
         ORDER BY ws.started_at DESC NULLS FIRST, ws.id DESC NULLS FIRST {{fetch_first(1)}}),
        'unknown'
      ) AS device_type,
      COALESCE(
        (SELECT CASE WHEN ws.utm_source IS NULL OR TRIM(ws.utm_source) = '' THEN 'direct' ELSE ws.utm_source END
         FROM web_sessions ws
         WHERE ws.tenant_id = c.tenant_id AND ws.user_id = c.user_id
           AND ws.started_at <= c.created_at
           AND CAST(ws.started_at AS date) = CAST(c.created_at AS date)
         ORDER BY ws.started_at DESC NULLS FIRST, ws.id DESC NULLS FIRST {{fetch_first(1)}}),
        'unknown'
      ) AS raw_channel
    FROM carts c
    WHERE c.created_at >= DATE '2025-10-01' AND c.created_at < DATE '2026-01-01'
  ) cb
) cart_rows
GROUP BY device_type, channel
ORDER BY carts_started DESC NULLS FIRST, device_type NULLS LAST, channel NULLS LAST
