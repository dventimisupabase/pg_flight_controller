-- Fortification SEC-001 (#68): defense-in-depth on object resolution. No control-path
-- function is SECURITY DEFINER today (apply() is SECURITY INVOKER), so a mutable
-- search_path cannot hijack the dynamic ALTER TABLE as built — but the moment any function
-- is later wrapped SECURITY DEFINER, an unpinned search_path becomes an injection surface.
-- We pin an explicit search_path on every plpgsql function in both extensions (plpgsql is
-- never inlined, so this is perf-neutral; SQL functions are left unpinned to preserve
-- planner inlining of the hot helpers). The invariant is CI-enforced here.
BEGIN;
SELECT plan(4);

-- (1) the headline invariant: NO plpgsql function in either extension schema leaves
-- search_path mutable. This is the assertion that fails before the fix (none are pinned)
-- and passes after (all are).
SELECT is(
  (SELECT count(*)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname IN ('pgfc_govern', 'pgfc_observe')
      AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
      AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) c
                       WHERE c LIKE 'search_path=%')),
  0, 'every plpgsql function in pgfc_govern/pgfc_observe pins search_path (SEC-001 #68)');

-- (2) the pinned value is the explicit qualified list, govern flavor (own schema, observe
-- for cross-schema reads, then pg_catalog).
SELECT is(
  (SELECT count(*)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgfc_govern'
      AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
      AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) c
                       WHERE c LIKE 'search_path=%pgfc_govern%pgfc_observe%pg_catalog%')),
  0, 'every govern plpgsql function pins (pgfc_govern, pgfc_observe, pg_catalog)');

-- (3) observe flavor (own schema, pg_catalog — it never reads govern).
SELECT is(
  (SELECT count(*)::int FROM pg_proc p
     JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgfc_observe'
      AND p.prolang = (SELECT oid FROM pg_language WHERE lanname = 'plpgsql')
      AND NOT EXISTS (SELECT 1 FROM unnest(COALESCE(p.proconfig, '{}')) c
                       WHERE c LIKE 'search_path=%pgfc_observe%pg_catalog%')),
  0, 'every observe plpgsql function pins (pgfc_observe, pg_catalog)');

-- (4) behavioral regression guard: the whole control path actuates correctly even when the
-- CALLER hands it an empty search_path — the pinned functions resolve their own pgfc_*
-- objects (static refs and the dynamic partition DDL / ALTER TABLE) from their own path,
-- not the caller's. This exercises observe_tick()'s partition CREATE and apply()'s ALTER
-- TABLE under a hostile path. (Set the empty path only around the qualified governor calls;
-- pgTAP's own functions need a normal path, so RESET before asserting.)
CREATE TABLE public.sp_t (id int);
UPDATE pgfc_govern.policy SET advisory_only = false WHERE policy_name = 'default';
SET search_path TO '';
SELECT pgfc_govern.observe_tick();
UPDATE pgfc_govern.relation_class SET kind = 'queue' WHERE relid = 'public.sp_t'::regclass;
SELECT pgfc_govern.control_tick();
RESET search_path;
SELECT isnt(pgfc_observe.effective_reloption(
              (SELECT reloptions FROM pg_class WHERE oid = 'public.sp_t'::regclass),
              'autovacuum_vacuum_scale_factor'),
            NULL, 'the control path actuates sp_t even under an empty caller search_path');

SELECT * FROM finish();
ROLLBACK;
