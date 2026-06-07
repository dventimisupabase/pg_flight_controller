-- Oracle-probe arm: set a single constant autovacuum_vacuum_scale_factor on the
-- fixture table.  Called once per grid value during the oracle sweep (oracle.sh).
-- Requires psql variables :fixture and :sf (set by oracle.sh via run.sh).
-- Explicit advisory_only reset for hermetic arm isolation.
UPDATE pgfc_govern.policy SET advisory_only = true WHERE policy_name = 'default';
--
-- Uses set_config to pass psql variables into the DO block (psql does not
-- interpolate :variable inside dollar-quoted strings).

SELECT set_config('pgfc._arm_fixture', :'fixture', false);
SELECT set_config('pgfc._arm_sf', :'sf'::text, false);

DO $$
DECLARE
    v_fixture text := current_setting('pgfc._arm_fixture');
    v_sf double precision := current_setting('pgfc._arm_sf')::double precision;
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
