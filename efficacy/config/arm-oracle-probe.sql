-- Oracle-probe arm: set a single constant autovacuum_vacuum_scale_factor on the
-- fixture table.  Called once per grid value during the oracle sweep (oracle.sh).
-- Requires psql variables :fixture and :sf (set by oracle.sh via run.sh).

DO $$
DECLARE
    v_fixture text := :'fixture';
    v_sf double precision := :'sf';
    v_table text;
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
        RAISE EXCEPTION 'arm=oracle-probe: unknown fixture: %', v_fixture;
    END IF;

    EXECUTE format(
        'ALTER TABLE %I SET (autovacuum_vacuum_scale_factor = %s)',
        v_table, v_sf
    );
    RAISE NOTICE 'arm=oracle-probe: set autovacuum_vacuum_scale_factor = % on % (probe sf)', v_sf, v_table;
END $$;
