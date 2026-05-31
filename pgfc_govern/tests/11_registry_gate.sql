-- Phase 1.6 P3: the drift gate. _audit_control_literals() scans the decision/actuation
-- bodies for numeric/interval literals that are not structural constants — i.e. control
-- values that escaped the registry. This test IS the gate: it asserts the audit is empty,
-- so any future inline magic number in the control path fails the build on every PG
-- version. (Operator-policy signature defaults, table-column defaults, and reporting
-- windows are deliberately out of scope — see the function's header comment.)
BEGIN;
SELECT plan(3);

SELECT has_function('pgfc_govern', '_audit_control_literals', 'the drift-gate function exists');

-- The gate: nothing in the decision/actuation path uses an unregistered literal.
SELECT is((SELECT count(*) FROM pgfc_govern._audit_control_literals()),
          0::bigint,
          'no unregistered numeric/interval literal in the control path (every value via the registry)');

-- Self-check that the scanner is not a no-op: its allowlisted structural constants (0/1)
-- really do occur in the scanned bodies, so the regex is matching real tokens (it just
-- filters them out). If this returned 0, the scanner would be silently matching nothing.
SELECT ok((SELECT count(*) FROM (
              SELECT regexp_matches(p.prosrc, '\y[0-9]+\y', 'g')
              FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
              WHERE n.nspname = 'pgfc_govern' AND p.proname = 'estimate') s) > 0,
          'scanner regex matches real numeric tokens (not a silent no-op)');

SELECT * FROM finish();
ROLLBACK;
