-- Remove pgfc_govern entirely (tables, views, functions, types). Leaves
-- pgfc_observe untouched.
DROP SCHEMA IF EXISTS pgfc_govern CASCADE;
