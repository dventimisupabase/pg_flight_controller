-- Views exist and the debt math matches hand-computed values, including the
-- effective-threshold = reloption ?? global-default rule.
BEGIN;
SELECT plan(13);

SELECT has_view('pgfc_observe', 'relation_health', 'relation_health view exists');
SELECT has_view('pgfc_observe', 'maintenance_debt', 'maintenance_debt view exists');

-- Synthetic snapshot with known global defaults.
INSERT INTO pgfc_observe.snapshots
  (server_version_num, def_vac_threshold, def_vac_scale_factor,
   def_ana_threshold, def_ana_scale_factor, def_freeze_max_age)
VALUES (170000, 50, 0.2, 50, 0.1, 200000000);

-- Two relations in that snapshot: one inheriting defaults, one with an override.
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname,
   n_dead_tup, n_mod_since_analyze, reltuples, relfrozenxid_age, reloptions)
VALUES
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
   99999, 'public', 't_synth', 30, 10, 1000, 100000000, NULL),
  ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
   99998, 'public', 't_synth_opt', 30, 10, 1000, 100000000,
   ARRAY['autovacuum_vacuum_scale_factor=0.05']);

-- Inheriting defaults (relid 99999):
--   vacuum_threshold  = 50 + 0.2*1000 = 250
--   analyze_threshold = 50 + 0.1*1000 = 150
--   dead_tuple_fraction = 30/1000 = 0.03
--   vacuum_debt_ratio   = 30/250   = 0.12
--   analyze_debt_ratio  = 10/150   = 0.066667
--   freeze_debt         = 1e8/2e8  = 0.5
SELECT is((SELECT vacuum_threshold FROM pgfc_observe.maintenance_debt WHERE relid = 99999),
          250::float8, 'vacuum_threshold = 50 + 0.2*1000');
SELECT is((SELECT analyze_threshold FROM pgfc_observe.maintenance_debt WHERE relid = 99999),
          150::float8, 'analyze_threshold = 50 + 0.1*1000');
SELECT is(round((SELECT dead_tuple_fraction FROM pgfc_observe.maintenance_debt WHERE relid = 99999)::numeric, 6),
          0.03, 'dead_tuple_fraction = 30/1000');
SELECT is(round((SELECT vacuum_debt_ratio FROM pgfc_observe.maintenance_debt WHERE relid = 99999)::numeric, 6),
          0.12, 'vacuum_debt_ratio = 30/250');
SELECT is(round((SELECT analyze_debt_ratio FROM pgfc_observe.maintenance_debt WHERE relid = 99999)::numeric, 6),
          0.066667, 'analyze_debt_ratio = 10/150');
SELECT is(round((SELECT freeze_debt FROM pgfc_observe.maintenance_debt WHERE relid = 99999)::numeric, 6),
          0.5, 'freeze_debt = 1e8/2e8');

-- Override (relid 99998): explicit scale_factor 0.05 wins over the 0.2 default
--   vacuum_threshold = 50 + 0.05*1000 = 100 ;  vacuum_debt_ratio = 30/100 = 0.3
SELECT is((SELECT vacuum_threshold FROM pgfc_observe.maintenance_debt WHERE relid = 99998),
          100::float8, 'reloption override: vacuum_threshold = 50 + 0.05*1000');
SELECT is(round((SELECT vacuum_debt_ratio FROM pgfc_observe.maintenance_debt WHERE relid = 99998)::numeric, 6),
          0.3, 'reloption override: vacuum_debt_ratio = 30/100');

-- relation_health surfaces the latest sample
SELECT is((SELECT n_dead_tup FROM pgfc_observe.relation_health WHERE relid = 99999),
          30::bigint, 'relation_health shows the latest sample');

-- Never-analyzed table: reltuples = -1 must not yield a negative fraction.
INSERT INTO pgfc_observe.relation_samples
  (snapshot_id, relid, schemaname, relname, n_dead_tup, n_mod_since_analyze, reltuples)
VALUES ((SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
        99997, 'public', 't_never_analyzed', 5, 5, -1);
SELECT is((SELECT dead_tuple_fraction FROM pgfc_observe.maintenance_debt WHERE relid = 99997),
          NULL, 'reltuples = -1 yields NULL dead_tuple_fraction, not a negative');
SELECT is((SELECT vacuum_threshold FROM pgfc_observe.maintenance_debt WHERE relid = 99997),
          50::float8, 'reltuples = -1 clamps to 0: vacuum_threshold = base (50)');

SELECT * FROM finish();
ROLLBACK;
