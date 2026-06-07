-- Defaults arm: stock PostgreSQL autovacuum settings. No per-table overrides.
-- Explicit advisory_only reset for hermetic arm isolation (ON CONFLICT DO NOTHING
-- in install.sql means reinstalling does not reset a prior pgfc-active run).
UPDATE pgfc_govern.policy SET advisory_only = true WHERE policy_name = 'default';

SELECT 'arm=defaults: no per-table overrides applied, advisory_only = true';
