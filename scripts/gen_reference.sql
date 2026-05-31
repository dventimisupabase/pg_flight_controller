-- Emit a markdown reference for one schema (psql var :sch) from the live catalog +
-- COMMENT ON metadata. Driven by scripts/gen-reference.sh. NOT part of the extension
-- (defined in pg_temp). Output is deterministic: every loop is ORDER BY-ed.
\pset tuples_only on
\pset format unaligned
\pset footer off

CREATE OR REPLACE FUNCTION pg_temp.gen_reference(sch text)
RETURNS SETOF text LANGUAGE plpgsql AS $gen$
DECLARE
    rel record;
    col record;
    fn  record;
    en  record;
    schemacmt text;
    sub text;     -- parsed [subsystem:<ID>] marker, rendered as its own field
    encmt text;   -- enum comment (captured once so the marker is stripped + parsed)
BEGIN
    RETURN NEXT '# `' || sch || '` reference';
    RETURN NEXT '';
    RETURN NEXT 'Generated from the installed extension''s catalog and `COMMENT ON` '
             || 'metadata by `scripts/gen-reference.sh`. Do not edit by hand.';
    RETURN NEXT '';
    schemacmt := obj_description(sch::regnamespace, 'pg_namespace');
    IF schemacmt IS NOT NULL THEN
        RETURN NEXT schemacmt;
        RETURN NEXT '';
    END IF;

    -- Tables ------------------------------------------------------------------
    -- relkind 'r' ordinary + 'p' partitioned parent; exclude child partitions
    -- (relispartition) so a daily-partitioned table lists once, not once per day.
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = sch AND c.relkind IN ('r','p')
                 AND NOT c.relispartition) THEN
        RETURN NEXT '## Tables';
        RETURN NEXT '';
        FOR rel IN
            SELECT c.oid, c.relname, obj_description(c.oid, 'pg_class') AS cmt
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = sch AND c.relkind IN ('r','p')
              AND NOT c.relispartition
            ORDER BY c.relname
        LOOP
            RETURN NEXT '### ' || sch || '.' || rel.relname;
            RETURN NEXT '';
            IF rel.cmt IS NOT NULL THEN
                RETURN NEXT regexp_replace(rel.cmt, '\s*\[subsystem:[OG][0-9]\]\s*$', '');
                RETURN NEXT '';
            END IF;
            sub := substring(rel.cmt FROM '\[subsystem:([OG][0-9])\]');
            IF sub IS NOT NULL THEN RETURN NEXT '**Subsystem:** ' || sub; RETURN NEXT ''; END IF;
            RETURN NEXT '| Column | Type | Description |';
            RETURN NEXT '| --- | --- | --- |';
            FOR col IN
                SELECT a.attname,
                       format_type(a.atttypid, a.atttypmod) AS typ,
                       col_description(rel.oid, a.attnum) AS ccmt
                FROM pg_attribute a
                WHERE a.attrelid = rel.oid AND a.attnum > 0 AND NOT a.attisdropped
                ORDER BY a.attnum
            LOOP
                RETURN NEXT '| `' || col.attname || '` | `' || col.typ || '` | '
                         || COALESCE(replace(col.ccmt, '|', '\|'), '') || ' |';
            END LOOP;
            RETURN NEXT '';
        END LOOP;
    END IF;

    -- Views (and materialized views) ------------------------------------------
    IF EXISTS (SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
               WHERE n.nspname = sch AND c.relkind IN ('v', 'm')) THEN
        RETURN NEXT '## Views';
        RETURN NEXT '';
        FOR rel IN
            SELECT c.oid, c.relname, obj_description(c.oid, 'pg_class') AS cmt
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = sch AND c.relkind IN ('v', 'm')
            ORDER BY c.relname
        LOOP
            RETURN NEXT '### ' || sch || '.' || rel.relname;
            RETURN NEXT '';
            IF rel.cmt IS NOT NULL THEN
                RETURN NEXT regexp_replace(rel.cmt, '\s*\[subsystem:[OG][0-9]\]\s*$', '');
                RETURN NEXT '';
            END IF;
            sub := substring(rel.cmt FROM '\[subsystem:([OG][0-9])\]');
            IF sub IS NOT NULL THEN RETURN NEXT '**Subsystem:** ' || sub; RETURN NEXT ''; END IF;
            RETURN NEXT '| Column | Type |';
            RETURN NEXT '| --- | --- |';
            FOR col IN
                SELECT a.attname, format_type(a.atttypid, a.atttypmod) AS typ
                FROM pg_attribute a
                WHERE a.attrelid = rel.oid AND a.attnum > 0 AND NOT a.attisdropped
                ORDER BY a.attnum
            LOOP
                RETURN NEXT '| `' || col.attname || '` | `' || col.typ || '` |';
            END LOOP;
            RETURN NEXT '';
        END LOOP;
    END IF;

    -- Functions ---------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
               WHERE n.nspname = sch) THEN
        RETURN NEXT '## Functions';
        RETURN NEXT '';
        FOR fn IN
            SELECT p.proname,
                   pg_get_function_identity_arguments(p.oid) AS args,
                   pg_get_function_result(p.oid) AS res,
                   obj_description(p.oid, 'pg_proc') AS cmt
            FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname = sch
            ORDER BY p.proname, pg_get_function_identity_arguments(p.oid)
        LOOP
            RETURN NEXT '### `' || sch || '.' || fn.proname
                     || '(' || fn.args || ') → ' || fn.res || '`';
            RETURN NEXT '';
            IF fn.cmt IS NOT NULL THEN
                RETURN NEXT regexp_replace(fn.cmt, '\s*\[subsystem:[OG][0-9]\]\s*$', '');
                RETURN NEXT '';
            END IF;
            sub := substring(fn.cmt FROM '\[subsystem:([OG][0-9])\]');
            IF sub IS NOT NULL THEN RETURN NEXT '**Subsystem:** ' || sub; RETURN NEXT ''; END IF;
        END LOOP;
    END IF;

    -- Enum types --------------------------------------------------------------
    IF EXISTS (SELECT 1 FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
               WHERE n.nspname = sch AND t.typtype = 'e') THEN
        RETURN NEXT '## Types';
        RETURN NEXT '';
        FOR en IN
            SELECT t.typname, t.oid,
                   string_agg(quote_literal(e.enumlabel), ', ' ORDER BY e.enumsortorder) AS labels
            FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
            JOIN pg_enum e ON e.enumtypid = t.oid
            WHERE n.nspname = sch AND t.typtype = 'e'
            GROUP BY t.typname, t.oid
            ORDER BY t.typname
        LOOP
            RETURN NEXT '### `' || sch || '.' || en.typname || '`';
            RETURN NEXT '';
            encmt := obj_description(en.oid, 'pg_type');
            IF encmt IS NOT NULL THEN
                RETURN NEXT regexp_replace(encmt, '\s*\[subsystem:[OG][0-9]\]\s*$', '');
                RETURN NEXT '';
            END IF;
            sub := substring(encmt FROM '\[subsystem:([OG][0-9])\]');
            IF sub IS NOT NULL THEN RETURN NEXT '**Subsystem:** ' || sub; RETURN NEXT ''; END IF;
            RETURN NEXT 'Enum values: ' || en.labels;
            RETURN NEXT '';
        END LOOP;
    END IF;
END
$gen$;

SELECT pg_temp.gen_reference(:'sch');
