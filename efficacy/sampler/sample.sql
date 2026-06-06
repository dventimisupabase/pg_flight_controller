-- One-shot metric sample. Reads pg_stat_user_tables and pg_class directly (not
-- through pgfc_observe) so the measurement is independent of the system under test.
-- Parameterized by psql variables :arm, :scenario, :seed.

INSERT INTO efficacy_metrics (arm, scenario, seed, relname,
    dead_frac, rel_size, xid_age, mxid_age, av_count, av_last, pgfc_applied)
SELECT
    :'arm', :'scenario', :seed, c.relname,
    s.n_dead_tup::double precision / NULLIF(s.n_live_tup + s.n_dead_tup, 0),
    pg_total_relation_size(c.oid),
    age(c.relfrozenxid),
    mxid_age(c.relminmxid),
    s.autovacuum_count,
    s.last_autovacuum,
    (SELECT count(*) FROM pgfc_govern.action_history
     WHERE relid = c.oid AND status = 'applied')
FROM pg_stat_user_tables s
JOIN pg_class c ON c.oid = s.relid
WHERE s.relname LIKE 'fix_%';
