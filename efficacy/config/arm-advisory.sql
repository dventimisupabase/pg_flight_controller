-- Advisory arm: loops run, telemetry collected, but apply() never fires (Phase 4 spec).
-- advisory_only = true is the install default; this script is explicit for auditability.

UPDATE pgfc_govern.policy
   SET advisory_only = true
 WHERE policy_name = 'default';

SELECT 'arm=advisory: advisory_only = true, instrumentation-only control';
