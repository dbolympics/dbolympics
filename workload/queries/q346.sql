SELECT
  EXTRACT(HOUR FROM pa.attempted_at) AS hour,
  COUNT(*) AS total_payment_attempts,
  COUNT(*) FILTER (WHERE pa.status IN ('authorized', 'captured')) AS captured_or_authorized_count,
  COUNT(*) FILTER (WHERE pa.status = 'failed') AS failed_count,
  {{divide_decimal(CAST(COUNT(*) FILTER (WHERE pa.status = 'failed') AS decimal(18,6)), NULLIF(COUNT(*), 0))}} * 100 AS failure_rate_pct
FROM payment_attempts pa
WHERE pa.attempted_at >= DATE '2025-11-28'
  AND pa.attempted_at < DATE '2025-11-29'
GROUP BY EXTRACT(HOUR FROM pa.attempted_at)
ORDER BY hour ASC NULLS LAST
