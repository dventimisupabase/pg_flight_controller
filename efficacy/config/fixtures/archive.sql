-- Fixture: archive (Phase 3 spec).
-- Large reference/lookup table — rarely written.
-- ANALYZE is mandatory: the classifier reads reltuples from the snapshot,
-- and pre-ANALYZE it reads -1, breaking the reltuples > 100000 predicate.

CREATE TABLE IF NOT EXISTS fix_archive (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    code     text NOT NULL,
    label    text
);

TRUNCATE fix_archive;

INSERT INTO fix_archive (code, label)
SELECT 'CODE-' || g, 'Label ' || g
FROM generate_series(1, :rows) g;

ANALYZE fix_archive;
