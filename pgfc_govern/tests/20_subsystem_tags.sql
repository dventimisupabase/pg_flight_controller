-- Subsystem-tag exhaustiveness gate (RFC §6/§8 bottom-up navigation). Every in-scope
-- object — table (relkind r/p, excluding child partitions), view (v/m), function, and
-- enum type — must carry exactly one valid [subsystem:<ID>] marker at the end of its
-- COMMENT ON. The in-scope predicates here MUST match what scripts/gen_reference.sql
-- renders; if they ever drift, an object can be tagged-but-unrendered (or rendered with
-- no Subsystem field). Sequences are out of scope (the reference has no Sequences
-- section), so batch_seq is intentionally not enumerated here. Valid IDs for
-- pgfc_govern are G1–G7.
BEGIN;
SELECT plan(4);

-- The in-scope object set + its parsed subsystem markers, mirrored by the observe gate.
CREATE TEMP VIEW _inscope AS
WITH objs AS (
    SELECT 'table'::text AS kind, c.relname::text AS name,
           obj_description(c.oid, 'pg_class') AS cmt
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgfc_govern' AND c.relkind IN ('r','p') AND NOT c.relispartition
    UNION ALL
    SELECT 'view', c.relname::text, obj_description(c.oid, 'pg_class')
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgfc_govern' AND c.relkind IN ('v','m')
    UNION ALL
    SELECT 'function', p.proname::text, obj_description(p.oid, 'pg_proc')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgfc_govern'
    UNION ALL
    SELECT 'enum', t.typname::text, obj_description(t.oid, 'pg_type')
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'pgfc_govern' AND t.typtype = 'e'
)
SELECT kind, name, cmt,
       (SELECT array_agg(x[1])
        FROM regexp_matches(COALESCE(cmt,''), '\[subsystem:([OG][0-9])\]', 'g') x) AS ids
FROM objs;

-- Sanity: the gate is actually looking at objects (catches an empty/misnamed schema).
SELECT cmp_ok((SELECT count(*) FROM _inscope), '>=', 45::bigint,
              'in-scope object set is non-trivial');

-- Every in-scope object has a comment carrying at least one marker.
SELECT is((SELECT count(*) FROM _inscope WHERE ids IS NULL), 0::bigint,
          'every in-scope object carries a [subsystem:<ID>] marker');

-- Exactly one marker per object (no double-tagging).
SELECT is((SELECT count(*) FROM _inscope WHERE array_length(ids, 1) > 1), 0::bigint,
          'no object carries more than one subsystem marker');

-- The marker ID is in the valid pgfc_govern set (G1–G7).
SELECT is((SELECT count(*) FROM _inscope
           WHERE ids IS NOT NULL AND ids[1] NOT IN ('G1','G2','G3','G4','G5','G6','G7')),
          0::bigint, 'every marker ID is a valid pgfc_govern subsystem (G1–G7)');

SELECT * FROM finish();
ROLLBACK;
