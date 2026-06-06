-- Smoke fixture: oltp (Phase 3 spec).
-- Idempotent: CREATE IF NOT EXISTS + TRUNCATE before preload.

CREATE TABLE IF NOT EXISTS fix_oltp (
    id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    balance numeric NOT NULL DEFAULT 0,
    updated timestamptz NOT NULL DEFAULT now()
);

TRUNCATE fix_oltp;

INSERT INTO fix_oltp (balance)
SELECT random() * 10000 FROM generate_series(1, :rows);

ANALYZE fix_oltp;
