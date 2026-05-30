-- pgfc_govern — Decide + Act (Phase 1: advisory)
--
-- The control loop of the pg_flight_controller autovacuum governor. It reads
-- pgfc_observe (cross-schema, read-only) and decides per-relation autovacuum
-- setpoints. In Phase 1 every policy is advisory_only by default: plan() writes a
-- full decision trail but apply() never fires.
--
-- Depends on pgfc_observe being installed first.
--
-- Re-running this file is safe and idempotent for the CURRENT schema
-- (CREATE ... IF NOT EXISTS / CREATE OR REPLACE; the harness applies it twice).
-- Schema evolution is additive-only (new NULLABLE columns; never drop/rename); a
-- new column must be added to its CREATE TABLE below AND to an
-- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` in the "Additive upgrades" section.

CREATE SCHEMA IF NOT EXISTS pgfc_govern;
COMMENT ON SCHEMA pgfc_govern IS
  'pg_flight_controller control loop: classify, estimate, plan, (apply), verify.';

-- Guard: pgfc_govern reads pgfc_observe cross-schema; fail early with a clear
-- message if the dependency is missing.
DO $$
BEGIN
    IF to_regnamespace('pgfc_observe') IS NULL THEN
        RAISE EXCEPTION 'pgfc_govern requires pgfc_observe to be installed first';
    END IF;
END $$;

-- Relation workload classes (choose the desired-state template). CREATE TYPE has no
-- IF NOT EXISTS, so guard it for re-runnable install.
DO $$
BEGIN
    CREATE TYPE pgfc_govern.relation_kind AS ENUM
        ('append_only','oltp','queue','delete_heavy','archive','mixed');
EXCEPTION WHEN duplicate_object THEN
    NULL;
END $$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Tables
-- ─────────────────────────────────────────────────────────────────────────────

-- Policy: operator intent expressed as outcomes, not parameters. advisory_only=true
-- (default) means the loop plans but apply() never fires (Phase 1).
CREATE TABLE IF NOT EXISTS pgfc_govern.policy (
    policy_name        text PRIMARY KEY,
    description        text,
    aggressiveness     double precision NOT NULL DEFAULT 1.0,   -- >1 = cleaner
    io_budget_fraction double precision,                        -- reserved (Phase 3)
    freeze_posture     text NOT NULL DEFAULT 'standard'
                       CHECK (freeze_posture IN ('standard','conservative')),
    -- actuator-economy / catalog-mutation knobs (Appendices A & B)
    min_interval       interval NOT NULL DEFAULT '1 hour',      -- per-relation rate limit
    global_max_changes_per_cycle integer NOT NULL DEFAULT 50,   -- cluster cap / cycle
    daily_mutation_budget integer NOT NULL DEFAULT 500,         -- cluster cap / day
    n_sustain          integer NOT NULL DEFAULT 3,              -- sustained-deviation cycles
    manage_user_owned  boolean NOT NULL DEFAULT false,          -- overwrite user reloptions?
    enabled            boolean NOT NULL DEFAULT true,
    advisory_only      boolean NOT NULL DEFAULT true            -- dry-run gate
);
COMMENT ON TABLE pgfc_govern.policy IS
  'Operator-expressed outcomes. advisory_only=true means plan but never apply.';
COMMENT ON COLUMN pgfc_govern.policy.manage_user_owned IS
  'false: never overwrite a reloption set by a user/other system first; true: take ownership.';

-- A single default advisory policy so the loop is operable out of the box.
INSERT INTO pgfc_govern.policy (policy_name, description)
VALUES ('default', 'Default advisory policy (plans, never applies)')
ON CONFLICT (policy_name) DO NOTHING;

-- Classification: which desired-state template a relation gets (hysteresis fields).
CREATE TABLE IF NOT EXISTS pgfc_govern.relation_class (
    relid            oid PRIMARY KEY,
    schemaname       name NOT NULL,
    relname          name NOT NULL,
    kind             pgfc_govern.relation_kind NOT NULL,
    source           text NOT NULL DEFAULT 'auto' CHECK (source IN ('auto','manual')),
    candidate        pgfc_govern.relation_kind,        -- pending class (hysteresis)
    candidate_streak integer NOT NULL DEFAULT 0,
    classified_at    timestamptz NOT NULL DEFAULT now()
);

-- Derived hidden state (output of estimate()), one row per relation (latest).
CREATE TABLE IF NOT EXISTS pgfc_govern.relation_estimate (
    relid               oid PRIMARY KEY,
    snapshot_id         bigint NOT NULL,
    -- realized-behavior diagnostics (logged, NOT control inputs)
    f_trigger_ewma      double precision,
    mod_trigger_ewma    double precision,
    f_peak_current      double precision,
    -- indicators (drive saturation diagnosis, not the keeping-up move)
    vacuum_debt_ratio   double precision,
    analyze_debt_ratio  double precision,
    freeze_debt         double precision,
    mxid_freeze_debt    double precision,
    -- rates / dynamics
    churn_rate          double precision,
    dead_accum_rate     double precision,
    growth_rate         double precision,
    cleanup_per_run     bigint,
    maintenance_lag     interval,
    burstiness          double precision,
    -- effectiveness & saturation (Appendix C)
    effectiveness       double precision,
    freeze_progressing  boolean,
    saturation_cause    text,             -- NULL | 'config' | 'io_limited' | 'inhibited'
    saturation_candidate text,            -- pending cause (streak/hysteresis state)
    saturation_streak   integer NOT NULL DEFAULT 0,
    estimated_at        timestamptz NOT NULL DEFAULT now()
);

-- Actuator state: current governor-set value + rollback baseline, per (relation, actuator).
CREATE TABLE IF NOT EXISTS pgfc_govern.actuator_state (
    relid              oid  NOT NULL,
    actuator           text NOT NULL,
    current_value      text,             -- value we last SET (NULL = never set)
    baseline_explicit  boolean NOT NULL, -- did the table have this reloption BEFORE us?
    baseline_value     text,             -- its value if baseline_explicit
    set_at_snapshot    bigint,
    av_count_at_apply  bigint,           -- autovacuum_count when applied (cycle counting)
    PRIMARY KEY (relid, actuator)
);
COMMENT ON COLUMN pgfc_govern.actuator_state.baseline_explicit IS
  'Rollback semantics: true => revert with SET to baseline_value; false => RESET.';

-- Audit: every decision, applied or not.
CREATE TABLE IF NOT EXISTS pgfc_govern.decision_log (
    decision_id    bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tick_id        bigint NOT NULL,
    relid          oid NOT NULL,
    actuator       text NOT NULL,
    observation    jsonb NOT NULL,   -- relevant observed values
    prev_state     jsonb NOT NULL,   -- relevant derived state
    desired_state  jsonb NOT NULL,   -- target setpoint(s)
    decision       text NOT NULL,    -- hold|adjust|suppressed:<reason>|escalate:<...>
    proposed_value text,             -- quantized grid value
    policy_rule    text,             -- which class/template/rule triggered this
    applied        boolean NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- Audit: attempted catalog mutations (applied AND failed); revert source of truth.
CREATE TABLE IF NOT EXISTS pgfc_govern.action_history (
    action_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id       bigint NOT NULL,  -- actuators changed together in one ALTER TABLE
    decision_id    bigint REFERENCES pgfc_govern.decision_log(decision_id),
    relid          oid NOT NULL,
    relname        text,
    actuator       text NOT NULL,
    old_value      text,
    new_value      text NOT NULL,
    prev_reloptions text[],
    revert_kind    text CHECK (revert_kind IN ('SET','RESET')),  -- NULL when failed
    revert_value   text,
    status         text NOT NULL DEFAULT 'applied' CHECK (status IN ('applied','failed')),
    failure_reason text,
    lock_wait_outcome text,
    budget_consumed boolean NOT NULL DEFAULT false,   -- only true for applied non-emergency
    emergency_override boolean NOT NULL DEFAULT false,
    applied_at     timestamptz NOT NULL DEFAULT now(),
    reverted_at    timestamptz
);
COMMENT ON TABLE pgfc_govern.action_history IS
  'Every actuator attempt (applied or failed). revert() replays only status=applied.';

-- Per control-cycle orchestration log.
CREATE TABLE IF NOT EXISTS pgfc_govern.tick_log (
    tick_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    snapshot_id    bigint,
    started_at     timestamptz NOT NULL DEFAULT now(),
    finished_at    timestamptz,
    n_relations    integer,
    n_decisions    integer,
    n_applied      integer,
    error          text
);

-- Diagnostic findings: saturation root-cause + actionable recommendation (Appendix C).
CREATE TABLE IF NOT EXISTS pgfc_govern.diagnostics (
    diagnostic_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    relid           oid,             -- NULL = cluster-level finding
    detected_at     timestamptz NOT NULL DEFAULT now(),
    severity        text NOT NULL DEFAULT 'warning'
                    CHECK (severity IN ('info','warning','critical')),
    inhibitor_class text,
    evidence        jsonb NOT NULL,
    recommendation  text,
    resolved_at     timestamptz
);
COMMENT ON TABLE pgfc_govern.diagnostics IS
  'When control saturates, the cause + a recommendation, not more DDL.';

-- ─────────────────────────────────────────────────────────────────────────────
-- estimate(): derive hidden state from observe snapshots into relation_estimate
-- ─────────────────────────────────────────────────────────────────────────────

-- EWMA that handles boot (no prior -> seed with sample) and gaps (no sample ->
-- keep prior). alpha NULL is treated as boot.
CREATE OR REPLACE FUNCTION pgfc_govern.ewma(prior double precision,
                                            sample double precision,
                                            alpha double precision)
RETURNS double precision IMMUTABLE LANGUAGE sql AS $$
    SELECT CASE
        WHEN sample IS NULL                  THEN prior
        WHEN prior IS NULL OR alpha IS NULL   THEN sample
        ELSE alpha * sample + (1 - alpha) * prior
    END
$$;

-- Update relation_estimate for every relation in snapshot p_snapshot_id. Reads
-- indicators from pgfc_observe.maintenance_debt (no re-derivation of thresholds) and
-- raw samples only for cross-snapshot deltas. Returns rows written.
CREATE OR REPLACE FUNCTION pgfc_govern.estimate(p_snapshot_id bigint)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE
    v_tau  double precision := 3600;   -- EWMA time constant (s) for rates
    v_effa double precision := 0.5;    -- effectiveness/peak EWMA weight
    v_k    integer := 3;               -- observations a saturation cause must persist
    n      integer;
BEGIN
    INSERT INTO pgfc_govern.relation_estimate AS re (
        relid, snapshot_id,
        f_trigger_ewma, f_peak_current,
        vacuum_debt_ratio, analyze_debt_ratio, freeze_debt, mxid_freeze_debt,
        churn_rate, dead_accum_rate, growth_rate, cleanup_per_run,
        effectiveness, freeze_progressing,
        saturation_cause, saturation_candidate, saturation_streak, estimated_at)
    WITH
    cur AS (   -- the relations in this snapshot, with header context
        SELECT rs.*, sn.collected_at, sn.def_mxid_freeze_max_age,
               sn.oldest_xmin_owner, sn.oldest_xmin_age
        FROM pgfc_observe.relation_samples rs
        JOIN pgfc_observe.snapshots sn USING (snapshot_id)
        WHERE rs.snapshot_id = p_snapshot_id
    ),
    prev AS (  -- each relation's most recent EARLIER sample (not snapshot_id-1!)
        SELECT DISTINCT ON (rs.relid)
               rs.relid, rs.n_tup_ins, rs.n_tup_upd, rs.n_tup_del, rs.n_dead_tup,
               rs.autovacuum_count, rs.reltuples, rs.relfrozenxid_age, sn.collected_at
        FROM pgfc_observe.relation_samples rs
        JOIN pgfc_observe.snapshots sn USING (snapshot_id)
        WHERE rs.snapshot_id < p_snapshot_id
          AND rs.relid IN (SELECT relid FROM cur)
        ORDER BY rs.relid, rs.snapshot_id DESC
    ),
    pe AS (    -- prior estimate state, staged BEFORE the upsert overwrites it
        SELECT * FROM pgfc_govern.relation_estimate
        WHERE relid IN (SELECT relid FROM cur)
    ),
    md AS (    -- current indicators from the observe view (single source of truth)
        SELECT relid, dead_tuple_fraction, vacuum_debt_ratio, analyze_debt_ratio, freeze_debt
        FROM pgfc_observe.maintenance_debt
        WHERE relid IN (SELECT relid FROM cur)
    ),
    calc AS (
        SELECT
            c.relid, c.collected_at, c.last_autovacuum, c.autovacuum_count,
            c.n_dead_tup, c.reltuples, c.relfrozenxid_age, c.relminmxid_age,
            c.def_mxid_freeze_max_age, c.oldest_xmin_owner, c.oldest_xmin_age,
            md.dead_tuple_fraction, md.vacuum_debt_ratio,
            md.analyze_debt_ratio, md.freeze_debt,
            (p.relid IS NULL)                                   AS boot,
            EXTRACT(epoch FROM (c.collected_at - p.collected_at))::float8 AS dt,
            c.n_tup_ins - p.n_tup_ins                           AS d_ins,
            c.n_tup_upd - p.n_tup_upd                           AS d_upd,
            c.n_tup_del - p.n_tup_del                           AS d_del,
            c.n_dead_tup - p.n_dead_tup                         AS d_dead,
            c.reltuples - p.reltuples                           AS d_reltup,
            p.n_dead_tup        AS prev_dead,
            p.autovacuum_count  AS prev_avc,
            p.relfrozenxid_age  AS prev_frzage,
            pe.churn_rate AS pe_churn, pe.dead_accum_rate AS pe_dead_rate,
            pe.growth_rate AS pe_growth, pe.f_peak_current AS pe_fpeak,
            pe.f_trigger_ewma AS pe_ftrig, pe.effectiveness AS pe_eff,
            pe.freeze_progressing AS pe_frzprog,
            pe.saturation_candidate AS pe_cand, pe.saturation_streak AS pe_streak
        FROM cur c
        LEFT JOIN prev p ON p.relid = c.relid
        LEFT JOIN pe   ON pe.relid = c.relid
        LEFT JOIN md   ON md.relid = c.relid
    ),
    derive AS (
        SELECT *,
            CASE WHEN dt > 0 THEN 1 - exp(-dt / v_tau) END           AS alpha,
            (NOT boot AND (d_ins < 0 OR d_upd < 0 OR d_del < 0))     AS reset,
            (NOT boot AND autovacuum_count > prev_avc)              AS cycle_boundary
        FROM calc
    ),
    ds AS (   -- second pass: rates, peak/effectiveness, mxid; needs derive's flags
        SELECT *,
            pgfc_govern.ewma(pe_churn,
                CASE WHEN boot OR reset OR dt <= 0 THEN NULL
                     ELSE (d_ins + d_upd + d_del) / dt END, alpha)     AS churn_rate,
            pgfc_govern.ewma(pe_dead_rate,
                CASE WHEN boot OR reset OR dt <= 0 THEN NULL
                     ELSE d_dead / dt END, alpha)                      AS dead_accum_rate,
            pgfc_govern.ewma(pe_growth,
                CASE WHEN boot OR dt <= 0 OR reltuples < 0 OR d_reltup < 0 THEN NULL
                     ELSE d_reltup / dt END, alpha)                    AS growth_rate,
            CASE WHEN cycle_boundary THEN GREATEST(prev_dead - n_dead_tup, 0) END AS cleanup_per_run,
            -- f_peak: reset to current dead fraction after a vacuum, else running max
            CASE WHEN cycle_boundary OR pe_fpeak IS NULL THEN dead_tuple_fraction
                 ELSE GREATEST(pe_fpeak, dead_tuple_fraction) END      AS f_peak_current,
            -- f_trigger: capture the peak just before the drop, at the cycle boundary
            CASE WHEN cycle_boundary THEN pgfc_govern.ewma(pe_ftrig, pe_fpeak, v_effa)
                 ELSE pe_ftrig END                                     AS f_trigger_ewma,
            -- effectiveness: did the vacuum clean? EWMA over cycles
            CASE WHEN cycle_boundary
                 THEN pgfc_govern.ewma(pe_eff,
                          CASE WHEN GREATEST(prev_dead - n_dead_tup, 0) > 0 THEN 1.0 ELSE 0.0 END,
                          v_effa)
                 ELSE pe_eff END                                       AS effectiveness,
            CASE WHEN cycle_boundary THEN (relfrozenxid_age < prev_frzage)
                 ELSE pe_frzprog END                                   AS freeze_progressing,
            relminmxid_age::float8 / NULLIF(def_mxid_freeze_max_age, 0) AS mxid_freeze_debt
        FROM derive
    ),
    sat AS (   -- third pass: saturation discriminator + streak (needs effectiveness)
        SELECT *,
            (last_autovacuum IS NOT NULL
             AND last_autovacuum > collected_at - interval '1 hour')   AS av_running,
            (COALESCE(vacuum_debt_ratio, 0) > 1)                       AS debt_high,
            (COALESCE(effectiveness, 1) < 0.5)                         AS eff_low,
            (oldest_xmin_owner IS NOT NULL AND oldest_xmin_owner <> 'none') AS horizon_pinned
        FROM ds
    ),
    final AS (
        SELECT *,
            CASE
                WHEN debt_high AND NOT av_running                       THEN 'config'
                WHEN debt_high AND av_running AND eff_low AND horizon_pinned THEN 'inhibited'
                WHEN debt_high AND av_running                           THEN 'io_limited'
                ELSE NULL
            END AS candidate
        FROM sat
    )
    SELECT
        relid, p_snapshot_id,
        f_trigger_ewma, f_peak_current,
        vacuum_debt_ratio, analyze_debt_ratio, freeze_debt, mxid_freeze_debt,
        churn_rate, dead_accum_rate, growth_rate, cleanup_per_run,
        effectiveness, freeze_progressing,
        -- cause is declared only after the candidate persists v_k observations
        CASE WHEN (CASE WHEN candidate IS NULL THEN 0
                        WHEN candidate IS NOT DISTINCT FROM pe_cand THEN pe_streak + 1
                        ELSE 1 END) >= v_k
             THEN candidate END                                        AS saturation_cause,
        candidate                                                      AS saturation_candidate,
        CASE WHEN candidate IS NULL THEN 0
             WHEN candidate IS NOT DISTINCT FROM pe_cand THEN pe_streak + 1
             ELSE 1 END                                                AS saturation_streak,
        now()
    FROM final
    ON CONFLICT (relid) DO UPDATE SET
        snapshot_id        = EXCLUDED.snapshot_id,
        f_trigger_ewma     = EXCLUDED.f_trigger_ewma,
        f_peak_current     = EXCLUDED.f_peak_current,
        vacuum_debt_ratio  = EXCLUDED.vacuum_debt_ratio,
        analyze_debt_ratio = EXCLUDED.analyze_debt_ratio,
        freeze_debt        = EXCLUDED.freeze_debt,
        mxid_freeze_debt   = EXCLUDED.mxid_freeze_debt,
        churn_rate         = EXCLUDED.churn_rate,
        dead_accum_rate    = EXCLUDED.dead_accum_rate,
        growth_rate        = EXCLUDED.growth_rate,
        cleanup_per_run    = EXCLUDED.cleanup_per_run,
        effectiveness      = EXCLUDED.effectiveness,
        freeze_progressing = EXCLUDED.freeze_progressing,
        saturation_cause   = EXCLUDED.saturation_cause,
        saturation_candidate = EXCLUDED.saturation_candidate,
        saturation_streak  = EXCLUDED.saturation_streak,
        estimated_at       = EXCLUDED.estimated_at;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.estimate(bigint) IS
  'Derive hidden state (rates, effectiveness, saturation) into relation_estimate.';

-- ─────────────────────────────────────────────────────────────────────────────
-- classify(): assign each relation a workload class (with a signal floor + hysteresis)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgfc_govern.classify(p_snapshot_id bigint)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE
    v_floor bigint  := 50;       -- min recent writes before classifying on fractions
    v_large real    := 100000;   -- reltuples above which an idle relation is 'archive'
    v_nsus  integer;
    n integer;
BEGIN
    SELECT n_sustain INTO v_nsus FROM pgfc_govern.policy
      WHERE enabled ORDER BY policy_name LIMIT 1;
    v_nsus := COALESCE(v_nsus, 3);

    INSERT INTO pgfc_govern.relation_class AS rc
        (relid, schemaname, relname, kind, source, candidate, candidate_streak, classified_at)
    WITH
    cur AS (
        SELECT relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del, reltuples
        FROM pgfc_observe.relation_samples WHERE snapshot_id = p_snapshot_id
    ),
    prev AS (
        SELECT DISTINCT ON (relid) relid, n_tup_ins, n_tup_upd, n_tup_del
        FROM pgfc_observe.relation_samples
        WHERE snapshot_id < p_snapshot_id AND relid IN (SELECT relid FROM cur)
        ORDER BY relid, snapshot_id DESC
    ),
    rcp AS (SELECT * FROM pgfc_govern.relation_class WHERE relid IN (SELECT relid FROM cur)),
    calc AS (
        SELECT c.relid, c.schemaname, c.relname, c.reltuples,
            GREATEST(c.n_tup_ins - p.n_tup_ins, 0) AS din,
            GREATEST(c.n_tup_upd - p.n_tup_upd, 0) AS dupd,
            GREATEST(c.n_tup_del - p.n_tup_del, 0) AS ddel,
            r.kind AS cur_kind, r.source AS cur_source,
            r.candidate AS cur_cand, r.candidate_streak AS cur_streak
        FROM cur c
        LEFT JOIN prev p ON p.relid = c.relid
        LEFT JOIN rcp  r ON r.relid = c.relid
    ),
    cls AS (
        SELECT *, (din + dupd + ddel) AS total,
            CASE WHEN (din + dupd + ddel) >= v_floor THEN
                CASE
                    WHEN din::float8 /(din+dupd+ddel) > 0.95
                         AND ddel::float8/(din+dupd+ddel) < 0.01 THEN 'append_only'
                    WHEN ddel::float8/(din+dupd+ddel) > 0.30
                         AND abs(ddel::float8/(din+dupd+ddel)
                                 - din::float8/(din+dupd+ddel)) < 0.10 THEN 'queue'
                    WHEN ddel::float8/(din+dupd+ddel) > 0.30 THEN 'delete_heavy'
                    WHEN dupd::float8/(din+dupd+ddel) > 0.30 THEN 'oltp'
                    ELSE 'mixed'
                END
            END AS rule_kind     -- NULL when below the signal floor
        FROM calc
    ),
    decided AS (
        SELECT *,
            COALESCE(
                rule_kind,                       -- enough signal: the computed class
                cur_kind::text,                  -- low signal: hold the existing class
                CASE WHEN reltuples > v_large THEN 'archive' ELSE 'mixed' END  -- new + idle
            )::pgfc_govern.relation_kind AS target_kind
        FROM cls
    )
    SELECT relid, schemaname, relname,
        CASE
            WHEN cur_kind IS NULL                       THEN target_kind   -- new: adopt
            WHEN cur_source = 'manual'                  THEN cur_kind      -- never auto-change
            WHEN target_kind = cur_kind                 THEN cur_kind      -- agrees: keep
            WHEN target_kind IS NOT DISTINCT FROM cur_cand
                 AND cur_streak + 1 >= v_nsus           THEN target_kind   -- sustained: commit
            ELSE cur_kind                                                  -- pending: hold
        END,
        COALESCE(cur_source, 'auto'),
        CASE
            WHEN cur_kind IS NULL                       THEN NULL
            WHEN cur_source = 'manual'                  THEN cur_cand
            WHEN target_kind = cur_kind                 THEN NULL
            WHEN target_kind IS NOT DISTINCT FROM cur_cand
                 AND cur_streak + 1 >= v_nsus           THEN NULL
            ELSE target_kind
        END,
        CASE
            WHEN cur_kind IS NULL                       THEN 0
            WHEN cur_source = 'manual'                  THEN cur_streak
            WHEN target_kind = cur_kind                 THEN 0
            WHEN target_kind IS NOT DISTINCT FROM cur_cand
                 AND cur_streak + 1 >= v_nsus           THEN 0
            WHEN target_kind IS NOT DISTINCT FROM cur_cand THEN cur_streak + 1
            ELSE 1
        END,
        now()
    FROM decided
    ON CONFLICT (relid) DO UPDATE SET
        schemaname       = EXCLUDED.schemaname,
        relname          = EXCLUDED.relname,
        kind             = EXCLUDED.kind,
        candidate        = EXCLUDED.candidate,
        candidate_streak = EXCLUDED.candidate_streak,
        classified_at    = CASE WHEN rc.kind <> EXCLUDED.kind THEN now()
                                ELSE rc.classified_at END;
    GET DIAGNOSTICS n = ROW_COUNT;
    RETURN n;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.classify(bigint) IS
  'Assign each relation a workload class with a signal floor and N-cycle hysteresis.';
