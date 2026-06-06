-- Fixture: mixed (Phase 3 spec).
-- General-purpose table — no single operation dominates.

CREATE TABLE IF NOT EXISTS fix_mixed (
    id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    category text,
    value    numeric,
    note     text
);

TRUNCATE fix_mixed;

INSERT INTO fix_mixed (category, value, note)
SELECT
    'cat-' || (random() * 10)::int,
    random() * 1000,
    repeat('n', 50)
FROM generate_series(1, :rows);

ANALYZE fix_mixed;
