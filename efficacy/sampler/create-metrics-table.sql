CREATE TABLE IF NOT EXISTS efficacy_metrics (
    sample_id    bigint GENERATED ALWAYS AS IDENTITY,
    sampled_at   timestamptz NOT NULL DEFAULT now(),
    arm          text NOT NULL,
    scenario     text NOT NULL,
    seed         int NOT NULL,
    relname      text NOT NULL,
    dead_frac    double precision,
    rel_size     bigint,
    xid_age      bigint,
    mxid_age     bigint,
    av_count     bigint,
    av_last      timestamptz,
    pgfc_applied bigint
);
