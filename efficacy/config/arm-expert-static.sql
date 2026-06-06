-- Expert-static arm: per-table autovacuum tuning frozen at t0 (Phase 4 spec).
-- Reads class targets from the pgfc registry, applies via ALTER TABLE SET.
-- Requires psql variable :fixture (set by run.sh).

DO $$
DECLARE
    v_fixture text := :'fixture';
    v_table text;
    v_sf double precision;
    v_reltuples real;
    v_threshold_cap int := 100000;
    v_large_threshold real := 100000000;
BEGIN
    v_table := CASE v_fixture
        WHEN 'append_only'  THEN 'fix_append'
        WHEN 'queue'        THEN 'fix_queue'
        WHEN 'delete_heavy' THEN 'fix_delheavy'
        WHEN 'oltp'         THEN 'fix_oltp'
        WHEN 'mixed'        THEN 'fix_mixed'
        WHEN 'archive'      THEN 'fix_archive'
        ELSE NULL
    END;
    IF v_table IS NULL THEN
        RAISE EXCEPTION 'arm=expert-static: unknown fixture: %', v_fixture;
    END IF;

    v_sf := pgfc_govern._class_target(v_fixture);

    EXECUTE format(
        'ALTER TABLE %I SET (autovacuum_vacuum_scale_factor = %s)',
        v_table, v_sf
    );
    RAISE NOTICE 'arm=expert-static: set autovacuum_vacuum_scale_factor = % on %', v_sf, v_table;

    SELECT reltuples INTO v_reltuples
      FROM pg_class
     WHERE relname = v_table AND relnamespace = 'public'::regnamespace;

    IF v_reltuples >= v_large_threshold THEN
        EXECUTE format(
            'ALTER TABLE %I SET (autovacuum_vacuum_threshold = %s)',
            v_table, v_threshold_cap
        );
        RAISE NOTICE 'arm=expert-static: set autovacuum_vacuum_threshold = % on % (% rows)',
                     v_threshold_cap, v_table, v_reltuples;
    END IF;
END $$;
