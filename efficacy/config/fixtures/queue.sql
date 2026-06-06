-- Fixture: queue (Phase 3 spec).
-- Balanced insert + delete churn — the job/message queue pattern.

CREATE TABLE IF NOT EXISTS fix_queue (
    id       bigint GENERATED ALWAYS AS IDENTITY,
    status   text NOT NULL DEFAULT 'pending',
    payload  jsonb
);

TRUNCATE fix_queue;

-- No preload for queue (starts empty, grows via inserts).
ANALYZE fix_queue;
