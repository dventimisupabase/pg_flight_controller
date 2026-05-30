-- S5 cardinality filters: observe() samples only the relations that pass the
-- collection_policy filters, so the governor stays cheap in databases with thousands
-- of relations. Four filters, all evaluated set-based inside observe()'s collection
-- query: exclude temporary tables, exclude extension-owned relations, exclude
-- operator-listed schemas, and exclude child partitions below a size floor. System
-- schemas (pg_catalog/information_schema/pgfc_*) are ALWAYS excluded and config can
-- never re-include them. Tests drive observe() and assert presence/absence in
-- relation_samples (same approach as 07_sparse.sql).
BEGIN;
SELECT plan(16);

-- ── schema surface + singleton config ────────────────────────────────────────
SELECT has_table('pgfc_observe', 'collection_policy',
                  'collection_policy config table exists');
SELECT has_column('pgfc_observe', 'collection_policy', 'exclude_temp', 'has exclude_temp');
SELECT has_column('pgfc_observe', 'collection_policy', 'include_extension_owned',
                  'has include_extension_owned');
SELECT has_column('pgfc_observe', 'collection_policy', 'min_partition_size_bytes',
                  'has min_partition_size_bytes');
SELECT has_column('pgfc_observe', 'collection_policy', 'excluded_schemas', 'has excluded_schemas');

SELECT is((SELECT count(*) FROM pgfc_observe.collection_policy), 1::bigint,
          'collection_policy is seeded with exactly one (singleton) row');
SELECT is((SELECT exclude_temp FROM pgfc_observe.collection_policy), true,
          'exclude_temp defaults true');
SELECT is((SELECT include_extension_owned FROM pgfc_observe.collection_policy), false,
          'include_extension_owned defaults false');

-- the PK is an enforced-singleton flag: a second row can never be inserted.
SELECT throws_ok($$ INSERT INTO pgfc_observe.collection_policy (singleton) VALUES (true) $$,
                 '23505', NULL, 'collection_policy enforces a single row (PK conflict)');

-- ── filter: temporary tables (default-excluded) ──────────────────────────────
-- A temp table lives in pg_temp_N, NOT in the hard-excluded system list, so only the
-- relpersistence='t' filter keeps it out — this proves the filter, not the schema list.
CREATE TEMP TABLE s5_temp (id int);
SELECT pgfc_observe.observe();
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 's5_temp'),
          0::bigint, 'temporary table is excluded by default (exclude_temp)');

-- ── filter: by-schema (additive to the system list) ──────────────────────────
CREATE SCHEMA s5_excluded;
CREATE TABLE s5_excluded.t (id int);
UPDATE pgfc_observe.collection_policy SET excluded_schemas = ARRAY['s5_excluded']::name[];
SELECT pgfc_observe.observe();
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples
            WHERE schemaname = 's5_excluded'),
          0::bigint, 'relations in an excluded schema are not sampled');

-- ── filter: extension-owned (default-excluded, includable) ───────────────────
-- ALTER EXTENSION ... ADD TABLE creates a deptype='e' pg_depend edge to the extension.
-- plpgsql is guaranteed present on every PG version, so it is a safe owner to borrow.
CREATE TABLE public.s5_ext_owned (id int);
ALTER EXTENSION plpgsql ADD TABLE public.s5_ext_owned;
SELECT pgfc_observe.observe();
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 's5_ext_owned'),
          0::bigint, 'extension-owned relation is excluded by default');

UPDATE pgfc_observe.collection_policy SET include_extension_owned = true;
SELECT pgfc_observe.observe();   -- still new (never entered last_state) => sampled once
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 's5_ext_owned'),
          1::bigint, 'extension-owned relation is sampled once include_extension_owned is true');

-- ── filter: sub-threshold child partitions (parent always kept) ──────────────
CREATE TABLE public.s5_parent (id int) PARTITION BY RANGE (id);
CREATE TABLE public.s5_child PARTITION OF public.s5_parent FOR VALUES FROM (1) TO (1000);
UPDATE pgfc_observe.collection_policy SET min_partition_size_bytes = 1000000000;  -- 1 GB
SELECT pgfc_observe.observe();
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 's5_child'),
          0::bigint, 'a child partition below the size floor is excluded');
SELECT is((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 's5_parent'),
          1::bigint, 'the partitioned parent is never size-filtered (sampled)');

-- The other direction: a child AT/ABOVE the floor is kept. This pins the size
-- COMPARISON itself — a predicate that excluded every child regardless of size would
-- pass the assertion above but fail here.
INSERT INTO public.s5_child SELECT generate_series(1, 100);
UPDATE pgfc_observe.collection_policy SET min_partition_size_bytes = 1;
SELECT pgfc_observe.observe();
SELECT isnt((SELECT count(*) FROM pgfc_observe.relation_samples WHERE relname = 's5_child'),
            0::bigint, 'a child partition at/above the size floor is sampled');

SELECT * FROM finish();
ROLLBACK;
