-- Subsystem-tag exhaustiveness gate (RFC §6/§8 bottom-up navigation). Every in-scope
-- object — table (relkind r/p, excluding child partitions), view (v/m), function, and
-- enum type — must carry exactly one valid [subsystem:<ID>] marker at the end of its
-- COMMENT ON. The in-scope predicates here MUST match what scripts/gen_reference.sql
-- renders; if they ever drift, an object can be tagged-but-unrendered (or rendered with
-- no Subsystem field). Valid IDs for pgfc_observe are O1–O5.
BEGIN;
SELECT plan(4);

-- The in-scope object set + its parsed subsystem markers, mirrored by the govern gate.
CREATE TEMP VIEW _inscope AS
WITH objs AS (
    SELECT 'table'::text AS kind, c.relname::text AS name,
           obj_description(c.oid, 'pg_class') AS cmt
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgfc_observe' AND c.relkind IN ('r','p') AND NOT c.relispartition
    UNION ALL
    SELECT 'view', c.relname::text, obj_description(c.oid, 'pg_class')
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'pgfc_observe' AND c.relkind IN ('v','m')
    UNION ALL
    SELECT 'function', p.proname::text, obj_description(p.oid, 'pg_proc')
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgfc_observe'
    UNION ALL
    SELECT 'enum', t.typname::text, obj_description(t.oid, 'pg_type')
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'pgfc_observe' AND t.typtype = 'e'
)
SELECT kind, name, cmt,
       (SELECT array_agg(x[1])
        FROM regexp_matches(COALESCE(cmt,''), '\[subsystem:([OG][0-9])\]', 'g') x) AS ids
FROM objs;

-- Sanity: the gate is actually looking at objects (catches an empty/misnamed schema).
SELECT cmp_ok((SELECT count(*) FROM _inscope), '>=', 25::bigint,
              'in-scope object set is non-trivial');

-- Every in-scope object has a comment carrying at least one marker.
SELECT is((SELECT count(*) FROM _inscope WHERE ids IS NULL), 0::bigint,
          'every in-scope object carries a [subsystem:<ID>] marker');

-- Exactly one marker per object (no double-tagging).
SELECT is((SELECT count(*) FROM _inscope WHERE array_length(ids, 1) > 1), 0::bigint,
          'no object carries more than one subsystem marker');

-- The marker ID is in the valid pgfc_observe set (O1–O5).
SELECT is((SELECT count(*) FROM _inscope
           WHERE ids IS NOT NULL AND ids[1] NOT IN ('O1','O2','O3','O4','O5')),
          0::bigint, 'every marker ID is a valid pgfc_observe subsystem (O1–O5)');

SELECT * FROM finish();
ROLLBACK;
