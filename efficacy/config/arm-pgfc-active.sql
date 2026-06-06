-- pgfc-active arm: enable full active control (Phase 4 spec).
-- advisory_only = false so plan() decisions are applied by apply().

UPDATE pgfc_govern.policy
   SET advisory_only = false
 WHERE policy_name = 'default';

SELECT 'arm=pgfc-active: advisory_only = false, active control enabled';
