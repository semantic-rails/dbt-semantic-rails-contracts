select
  cast('00000000-0000-0000-0000-000000000001' as uuid) as event_id,
  cast('2026-01-01 00:00:00+00' as timestamptz) as occurred_at,
  cast('2026-01-01 00:00:00+00' as timestamp with time zone) as updated_at,
  cast('2026-01-01 00:00:00' as timestamp) as recorded_at
