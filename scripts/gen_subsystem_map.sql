-- Emit docs/reference/subsystem-map.md: the bottom-up navigation index. For every
-- in-scope object it reads the `[subsystem:<ID>]` marker from its COMMENT ON, groups the
-- objects by subsystem (the siblings), links each member DOWN to its reference entry, and
-- links each subsystem heading UP to its RFC §5 anchor. Driven by
-- scripts/gen-subsystem-map.sh. NOT part of the extension (defined in pg_temp). Output is
-- deterministic: every loop is ORDER BY-ed.
--
-- In-scope object kinds match scripts/gen_reference.sql exactly (so the deep-link anchors
-- match the reference headings): tables (relkind r/p, excluding child partitions), views
-- (v/m), functions, and enum types. Sequences are out of scope (no Sequences section in
-- the reference). Consumer / cross-edges are NOT generated — they live, hand-authored, in
-- RFC §5; this map's up-link points there.
\pset tuples_only on
\pset format unaligned
\pset footer off

-- check-links.py's GitHub-style slug, reproduced exactly so generated deep links match the
-- reference headings byte-for-byte: lowercase, drop backticks, strip inline HTML, remove
-- everything except [a-z0-9], space, underscore, hyphen, then space -> hyphen. (Use an
-- explicit class, NOT \w/\s — Postgres bracket-class semantics differ from Python's.)
CREATE OR REPLACE FUNCTION pg_temp.gh_slug(t text)
RETURNS text LANGUAGE sql IMMUTABLE AS $$
    SELECT replace(
             regexp_replace(
               regexp_replace(lower(replace(t, '`', '')), '<[^>]+>', '', 'g'),
               '[^a-z0-9 _-]', '', 'g'),
             ' ', '-');
$$;

CREATE OR REPLACE FUNCTION pg_temp.gen_subsystem_map()
RETURNS SETOF text LANGUAGE plpgsql AS $gen$
DECLARE
    sub record;
    obj record;
BEGIN
    RETURN NEXT '# Subsystem map';
    RETURN NEXT '';
    RETURN NEXT 'Bottom-up navigation, generated from each object''s `[subsystem:<ID>]` '
             || '`COMMENT ON` marker by `scripts/gen-subsystem-map.sh`. Do not edit by '
             || 'hand; CI fails on staleness.';
    RETURN NEXT '';
    RETURN NEXT 'From any object: its **home subsystem** is the heading it sits under, and '
             || 'its **siblings** are the other members of that group. Each member links '
             || 'down to its [reference](pgfc_observe.md) entry; each subsystem heading '
             || 'links up to its RFC [§5](../rfc/README.md#5-subsystems) section, where the '
             || 'subsystem''s purpose and its consumer / cross-edges are described.';
    RETURN NEXT '';

    -- Subsystem catalogue: ID -> (display title, RFC §5 anchor, schema). Ordering is the
    -- RFC §5 ordering. The anchors are RFC §5's stable heading slugs (see the build plan's
    -- invariants); check-links.py validates each one resolves in ../rfc/README.md.
    FOR sub IN
        WITH subsystems(id, ord, schema, title, rfc_anchor) AS (
            VALUES
                ('O1', 1, 'pgfc_observe', 'O1. Collection',                       'o1-collection'),
                ('O2', 2, 'pgfc_observe', 'O2. Storage and retention',            'o2-storage-and-retention'),
                ('O3', 3, 'pgfc_observe', 'O3. Derived state and readers',        'o3-derived-state-and-readers'),
                ('O4', 4, 'pgfc_observe', 'O4. Self-monitoring and budget',       'o4-self-monitoring-and-budget'),
                ('O5', 5, 'pgfc_observe', 'O5. Parameter registry',               'o5-parameter-registry'),
                ('G1', 6, 'pgfc_govern',  'G1. Control loop (OODA)',              'g1-control-loop-ooda'),
                ('G2', 7, 'pgfc_govern',  'G2. Policy and intent',                'g2-policy-and-intent'),
                ('G3', 8, 'pgfc_govern',  'G3. Parameter governance',             'g3-parameter-governance'),
                ('G4', 9, 'pgfc_govern',  'G4. Self-protection (F1-F7)',          'g4-self-protection-f1-f7'),
                ('G5', 10, 'pgfc_govern', 'G5. Diagnostics',                      'g5-diagnostics'),
                ('G6', 11, 'pgfc_govern', 'G6. Storage, retention, and self-maintenance', 'g6-storage-retention-and-self-maintenance'),
                ('G7', 12, 'pgfc_govern', 'G7. Status and reporting',             'g7-status-and-reporting')
        )
        SELECT id, schema, title, rfc_anchor FROM subsystems ORDER BY ord
    LOOP
        RETURN NEXT '## [' || sub.title || '](../rfc/README.md#' || sub.rfc_anchor || ')';
        RETURN NEXT '';

        -- Every in-scope object carrying this subsystem's marker, ordered (kind, name).
        -- ref_heading reconstructs the EXACT heading scripts/gen_reference.sql emits, so
        -- gh_slug() of it equals the reference anchor.
        FOR obj IN
            -- Tables (relkind r/p, excluding child partitions); heading has no backticks.
            SELECT 1 AS kind_rank, 'table' AS kind, n.nspname || '.' || c.relname AS qname,
                   n.nspname || '.' || c.relname AS ref_heading,
                   substring(obj_description(c.oid, 'pg_class') FROM '\[subsystem:([OG][0-9])\]') AS sid
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = sub.schema AND c.relkind IN ('r', 'p') AND NOT c.relispartition
            UNION ALL
            -- Views and materialized views; heading has no backticks.
            SELECT 2, 'view', n.nspname || '.' || c.relname,
                   n.nspname || '.' || c.relname,
                   substring(obj_description(c.oid, 'pg_class') FROM '\[subsystem:([OG][0-9])\]')
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = sub.schema AND c.relkind IN ('v', 'm')
            UNION ALL
            -- Functions; reference heading is backtick-wrapped with the full signature.
            SELECT 3, 'function', n.nspname || '.' || p.proname,
                   '`' || n.nspname || '.' || p.proname || '('
                       || pg_get_function_identity_arguments(p.oid) || ') → '
                       || pg_get_function_result(p.oid) || '`',
                   substring(obj_description(p.oid, 'pg_proc') FROM '\[subsystem:([OG][0-9])\]')
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = sub.schema
            UNION ALL
            -- Enum types; reference heading is backtick-wrapped.
            SELECT 4, 'type', n.nspname || '.' || t.typname,
                   '`' || n.nspname || '.' || t.typname || '`',
                   substring(obj_description(t.oid, 'pg_type') FROM '\[subsystem:([OG][0-9])\]')
            FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
            WHERE n.nspname = sub.schema AND t.typtype = 'e'
            -- ref_heading is the tiebreaker so overloaded functions (same qname, distinct
            -- signatures) stay deterministically ordered, mirroring gen_reference.sql's
            -- ORDER BY (proname, args). No overloads exist today, so output is unchanged.
            ORDER BY kind_rank, qname, ref_heading
        LOOP
            CONTINUE WHEN obj.sid IS DISTINCT FROM sub.id;
            RETURN NEXT '- [`' || obj.qname || '`](' || sub.schema || '.md#'
                     || pg_temp.gh_slug(obj.ref_heading) || ') — ' || obj.kind;
        END LOOP;
        RETURN NEXT '';
    END LOOP;
END
$gen$;

SELECT pg_temp.gen_subsystem_map();
