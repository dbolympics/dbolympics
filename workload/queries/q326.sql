SELECT
  t0.public_id AS public_id,
  t1.name AS tenant_name,
  t0.request_type AS request_type,
  t0.status AS status,
  t0.received_at AS received_at,
  t0.completed_at AS completed_at,
  t0.created_at AS created_at,
  {{divide_decimal({{seconds_between(t0.received_at, t0.created_at)}}, 86400.0)}} AS days_received_to_created,
  LEFT(COALESCE(t0.notes, ''), 200) AS notes
FROM data_subject_requests t0
JOIN tenants t1 ON t1.id = t0.tenant_id
WHERE t0.received_at < DATE '2023-01-01'
ORDER BY t0.received_at ASC NULLS LAST, t0.public_id ASC NULLS LAST
