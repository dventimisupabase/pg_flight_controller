-- S6 (govern half): the cross-schema storage surfaces. storage_budget() reports both
-- schemas; self_health compares the footprint to a configured budget; degrade() sheds
-- storage in a FIXED graceful-degrade order (raw → fine rollups → coarse rollups →
-- diagnostics → actions → policy-never) stopping once under budget. The contract under
-- test is the ORDER and that policy is sacrosanct — not the per-table delete counts
-- (those belong to retain()/rollup_retain(), tested elsewhere). Static autovacuum
-- reloptions on the govern audit/state tables are asserted too.
BEGIN;
SELECT plan(27);

-- ── schema surface ───────────────────────────────────────────────────────────
SELECT has_table('pgfc_govern', 'storage_config', 'storage_config table exists');
SELECT has_function('pgfc_govern', 'storage_budget', 'storage_budget() exists');
SELECT has_function('pgfc_govern', 'degrade', 'degrade() exists');
SELECT has_view('pgfc_govern', 'self_health', 'self_health view exists');

-- ── storage_config singleton ─────────────────────────────────────────────────
SELECT is((SELECT count(*) FROM pgfc_govern.storage_config), 1::bigint,
          'storage_config is seeded with exactly one (singleton) row');
SELECT is((SELECT budget_bytes FROM pgfc_govern.storage_config), NULL::bigint,
          'budget_bytes defaults NULL (no cap => degrade disabled)');

-- ── storage_budget() spans both schemas ──────────────────────────────────────
SELECT ok(EXISTS (SELECT 1 FROM pgfc_govern.storage_budget()
                  WHERE schema_name = 'pgfc_observe'),
          'storage_budget includes pgfc_observe relations');
SELECT ok(EXISTS (SELECT 1 FROM pgfc_govern.storage_budget()
                  WHERE schema_name = 'pgfc_govern' AND relation = 'decision_log'),
          'storage_budget includes pgfc_govern audit tables');

-- ── static reloptions on every govern audit/state table ──────────────────────
SELECT is((SELECT count(*) FROM (VALUES
              ('policy'),('policy_history'),('relation_class'),('relation_estimate'),
              ('actuator_state'),('decision_log'),('action_history'),('tick_log'),
              ('diagnostics'),('storage_config')) v(t)
           WHERE NOT EXISTS (
               SELECT 1 FROM pg_class c, unnest(c.reloptions) o
               WHERE c.relname = v.t
                 AND c.relnamespace = 'pgfc_govern'::regnamespace
                 AND o LIKE 'autovacuum_vacuum_threshold=%')),
          0::bigint, 'every govern audit/state table carries a static autovacuum threshold');

-- ── self_health (no budget configured) ───────────────────────────────────────
SELECT is((SELECT count(*) FROM pgfc_govern.self_health), 1::bigint,
          'self_health is exactly one row');
SELECT is((SELECT over_budget FROM pgfc_govern.self_health), false,
          'over_budget is false when no budget is configured');
SELECT ok((SELECT total_bytes FROM pgfc_govern.self_health) > 0,
          'self_health.total_bytes is positive');

-- ── degrade() no-op when no budget is configured ─────────────────────────────
SELECT is((SELECT count(*) FROM pgfc_govern.degrade(NULL)), 0::bigint,
          'degrade with no configured budget returns no rows (a clean no-op)');

-- ── degrade() with a budget that is never exceeded => all levels skipped ──────
SELECT ok((SELECT bool_and(action LIKE 'skipped%' OR level = 'policy')
           FROM pgfc_govern.degrade(9223372036854775807)),
          'a budget larger than the footprint skips every prune level');

-- ── degrade() under pressure (budget 0) prunes in the documented ORDER ────────
-- A new policy is recorded (and captured in policy_history) before we force degrade,
-- so we can prove policy survives the most aggressive prune.
INSERT INTO pgfc_govern.policy (policy_name, description)
VALUES ('s6_degrade_pol', 'must survive degrade');

SELECT is((SELECT level FROM pgfc_govern.degrade(0) ORDER BY step ASC LIMIT 1),
          'raw', 'the first (cheapest) level pruned is raw observations');
SELECT is((SELECT level FROM pgfc_govern.degrade(0) ORDER BY step DESC LIMIT 1),
          'policy', 'the last level in the order is policy');
SELECT is((SELECT action FROM pgfc_govern.degrade(0) WHERE level = 'policy'),
          'preserved', 'policy is preserved, never pruned');
SELECT is((SELECT action FROM pgfc_govern.degrade(0) WHERE level = 'raw'),
          'swept', 'raw is force-swept when over budget (the ring is bounded; FMEA-001)');

-- raw must come strictly before policy in the prune order.
SELECT ok((SELECT step FROM pgfc_govern.degrade(0) WHERE level = 'raw')
          < (SELECT step FROM pgfc_govern.degrade(0) WHERE level = 'policy'),
          'raw is sacrificed before policy');

-- The human-owned policy record survives even budget 0.
SELECT is((SELECT count(*) FROM pgfc_govern.policy WHERE policy_name = 's6_degrade_pol'),
          1::bigint, 'policy row survives an aggressive degrade');
SELECT ok(EXISTS (SELECT 1 FROM pgfc_govern.policy_history
                  WHERE policy_name = 's6_degrade_pol'),
          'policy_history is never pruned by degrade');

-- ── graceful short-circuit: shed an early level, re-measure, STOP (the S6 exit bar) ─
-- The two cases above are degenerate extremes (everything prunes / everything skips);
-- neither exercises the path that DEFINES graceful degradation — shed an early level,
-- find we are now under budget, and leave the rest untouched. Raw can no longer be the
-- lever (FMEA-001: the ring is bounded by construction — it is force-swept but holds no
-- in-window-sheddable bulk), so make the FINE ROLLUP tier the dominant chunk: a fat
-- 10-day-old rollup_1m partition that step 2 will DROP. Set a budget just below the
-- current footprint, satisfiable once that chunk is shed. degrade() is captured once into
-- a temp table so every level is read from the same single invocation.
SELECT pgfc_observe._ensure_part('rollup_1m', pgfc_observe._epoch_day(now() - interval '10 days'), 'day');
INSERT INTO pgfc_observe.rollup_1m
    (bucket_part, bucket_start, relid, schemaname, relname, sample_count)
SELECT pgfc_observe._epoch_day(now() - interval '10 days'),
       now() - interval '10 days', g, 'public', 'r' || g, 1
FROM generate_series(1, 5000) g;

CREATE TEMP TABLE s6_graceful AS
SELECT * FROM pgfc_govern.degrade(
    (SELECT sum(bytes)::bigint - 1 FROM pgfc_govern.storage_budget()));  -- just below current

SELECT is((SELECT action FROM s6_graceful WHERE level = 'raw'), 'swept',
          'graceful: raw is force-swept (bounded ring) and frees nothing on its own');
SELECT is((SELECT action FROM s6_graceful WHERE level = 'rollups_fine'), 'pruned',
          'graceful: the dominant fine-rollup level is pruned');
SELECT is((SELECT action FROM s6_graceful WHERE level = 'rollups_coarse'),
          'skipped:under_budget',
          'graceful: once fine rollups drop us under budget, later levels are skipped (the S6 exit bar)');

-- Budget report accuracy: a plain table's reported bytes equals pg_total_relation_size.
SELECT is((SELECT bytes FROM pgfc_govern.storage_budget()
           WHERE schema_name = 'pgfc_govern' AND relation = 'decision_log'),
          pg_total_relation_size('pgfc_govern.decision_log'),
          'storage_budget bytes match pg_total_relation_size for a plain table');

-- ── budget-driven path: configure a 0 cap, self_health flags it, degrade runs ─
UPDATE pgfc_govern.storage_config SET budget_bytes = 0;
SELECT is((SELECT over_budget FROM pgfc_govern.self_health), true,
          'self_health.over_budget flips true once the footprint exceeds the cap');
SELECT ok((SELECT count(*) FROM pgfc_govern.degrade()) > 0,
          'degrade() with no argument reads the configured budget and acts');

SELECT * FROM finish();
ROLLBACK;
