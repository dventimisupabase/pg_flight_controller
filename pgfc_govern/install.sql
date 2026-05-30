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

-- Policy history: human-owned desired-state changes over time (Appendix D, class 5).
-- Retained indefinitely (pruned last, explicitly) so past governor behavior can be
-- explained. The trigger below is created AFTER the seed INSERT, so the auto-seeded
-- 'default' policy is intentionally not logged — only real human changes are.
CREATE TABLE IF NOT EXISTS pgfc_govern.policy_history (
    history_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    policy_name  text NOT NULL,
    operation    text NOT NULL CHECK (operation IN ('insert','update','delete')),
    old_row      jsonb,            -- prior row (NULL on insert)
    new_row      jsonb,            -- new row  (NULL on delete)
    changed_by   text NOT NULL DEFAULT current_user,
    changed_at   timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE pgfc_govern.policy_history IS
  'Append-only audit of policy changes (insert/update/delete); retained indefinitely.';

CREATE OR REPLACE FUNCTION pgfc_govern._log_policy_change()
RETURNS trigger LANGUAGE plpgsql AS $fn$
BEGIN
    INSERT INTO pgfc_govern.policy_history (policy_name, operation, old_row, new_row)
    VALUES (coalesce(NEW.policy_name, OLD.policy_name),
            lower(TG_OP),
            CASE WHEN TG_OP <> 'INSERT' THEN to_jsonb(OLD) END,
            CASE WHEN TG_OP <> 'DELETE' THEN to_jsonb(NEW) END);
    RETURN NULL;   -- AFTER trigger: return value ignored
END;
$fn$;
COMMENT ON FUNCTION pgfc_govern._log_policy_change() IS
  'AFTER row trigger: records every policy insert/update/delete into policy_history.';

CREATE OR REPLACE TRIGGER policy_history_trg
    AFTER INSERT OR UPDATE OR DELETE ON pgfc_govern.policy
    FOR EACH ROW EXECUTE FUNCTION pgfc_govern._log_policy_change();

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
    cur AS (   -- current state of EVERY relation as of this snapshot, with header context.
        -- current_relation_state() reconciles sparse storage (S3): it carries quiet
        -- relations forward and stamps snapshot_id = p_snapshot_id, so the header join
        -- resolves the latest cluster context and `prev` (below) still finds the true
        -- prior sample. Freeze ages are live, so a quiet table's freeze debt stays fresh.
        SELECT rs.*, sn.collected_at, sn.def_mxid_freeze_max_age,
               sn.oldest_xmin_owner, sn.oldest_xmin_age
        FROM pgfc_observe.current_relation_state(p_snapshot_id) rs
        JOIN pgfc_observe.snapshots sn USING (snapshot_id)
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
    cur AS (   -- every relation as of this snapshot (sparse-reconciled, S3)
        SELECT relid, schemaname, relname, n_tup_ins, n_tup_upd, n_tup_del, reltuples
        FROM pgfc_observe.current_relation_state(p_snapshot_id)
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

-- ─────────────────────────────────────────────────────────────────────────────
-- plan(): decide per-relation setpoints (advisory) + reconcile diagnostics
-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 1 scope: the VACUUM objective via the scale-factor lever. The threshold
-- lever (small tables) and the ANALYZE objective are deferred follow-ups. The
-- actuation-economy gates (rate limits, sustained-deviation) are deferred to Phase 2
-- since apply() is gated off here; plan() only writes the decision/diagnosis trail.

-- Snap a scale factor to the bounded grid (SF_GRID).
CREATE OR REPLACE FUNCTION pgfc_govern.snap_sf(x double precision)
RETURNS double precision IMMUTABLE LANGUAGE sql AS $$
    SELECT g FROM (VALUES (0.01),(0.02),(0.05),(0.10),(0.20),(0.30),(0.50)) AS grid(g)
    ORDER BY abs(g - x) LIMIT 1
$$;

CREATE OR REPLACE FUNCTION pgfc_govern.plan(p_tick_id bigint, p_snapshot_id bigint)
RETURNS integer LANGUAGE plpgsql AS $fn$
DECLARE
    v_sf_min     double precision := 0.01;
    v_sf_max     double precision := 0.50;
    v_freeze_thr double precision := 0.6;
    v_aggr       double precision;
    v_manage     boolean;
    n integer;
BEGIN
    SELECT aggressiveness, manage_user_owned INTO v_aggr, v_manage
      FROM pgfc_govern.policy WHERE enabled ORDER BY policy_name LIMIT 1;
    v_aggr   := COALESCE(v_aggr, 1.0);
    v_manage := COALESCE(v_manage, false);

    INSERT INTO pgfc_govern.decision_log
      (tick_id, relid, actuator, observation, prev_state, desired_state,
       decision, proposed_value, policy_rule)
    WITH
    base AS (
        SELECT rc.relid, rc.kind, rs.reltuples, rs.reloptions,
               sn.def_vac_scale_factor, sn.def_vac_threshold,
               sn.oldest_xmin_owner, sn.oldest_xmin_owner_detail,
               re.saturation_cause, re.freeze_debt, re.mxid_freeze_debt,
               re.vacuum_debt_ratio, re.effectiveness
        FROM pgfc_govern.relation_class rc
        JOIN pgfc_govern.relation_estimate re ON re.relid = rc.relid
        JOIN pgfc_observe.current_relation_state(p_snapshot_id) rs ON rs.relid = rc.relid
        JOIN pgfc_observe.snapshots sn ON sn.snapshot_id = p_snapshot_id
    ),
    tgt AS (
        SELECT *,
            CASE kind
                WHEN 'queue' THEN 0.05 WHEN 'delete_heavy' THEN 0.10
                WHEN 'oltp' THEN 0.20  WHEN 'mixed' THEN 0.20
                WHEN 'append_only' THEN 0.40 WHEN 'archive' THEN 0.50
            END AS f_template,
            COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor')::float8,
                     def_vac_scale_factor) AS cur_sf,
            COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_threshold')::bigint,
                     def_vac_threshold)    AS cur_base,
            (pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor') IS NOT NULL)
                                           AS sf_user_set,
            (freeze_debt > v_freeze_thr OR COALESCE(mxid_freeze_debt,0) > v_freeze_thr)
                                           AS freeze_stress,
            (oldest_xmin_owner IS NOT NULL AND oldest_xmin_owner <> 'none')
                                           AS horizon_pinned
        FROM base
    ),
    decided AS (
        SELECT *,
            -- freeze floor = cleanest; else policy-scaled class target, clamped
            CASE WHEN freeze_stress THEN v_sf_min
                 ELSE LEAST(GREATEST(f_template / v_aggr, v_sf_min), v_sf_max) END AS eff_f
        FROM tgt
    ),
    q AS (
        SELECT *,
            -- GREATEST(reltuples,1) guards empty/never-analyzed tables: there the base
            -- term dominates, sf_cont clamps to sf_min, and the sf lever (rightly) has
            -- little authority -- the threshold lever (Phase 1 follow-up) is the tool.
            pgfc_govern.snap_sf(
                LEAST(GREATEST(eff_f - cur_base::float8 / GREATEST(reltuples, 1), v_sf_min), v_sf_max)
            ) AS sf_target
        FROM decided
    )
    SELECT
        p_tick_id, relid, 'autovacuum_vacuum_scale_factor',
        jsonb_build_object('vacuum_debt_ratio', vacuum_debt_ratio,
                           'effectiveness', effectiveness,
                           'reltuples', reltuples, 'cur_sf', cur_sf),
        jsonb_build_object('saturation_cause', saturation_cause,
                           'freeze_debt', freeze_debt,
                           'horizon_owner', oldest_xmin_owner),
        jsonb_build_object('f_template', f_template, 'eff_f', eff_f, 'sf_target', sf_target),
        -- precedence: freeze floor dominates saturation suppression (§11.5/§13)
        CASE
            WHEN freeze_stress AND horizon_pinned
                 THEN 'escalate:inhibited:' || COALESCE(oldest_xmin_owner,'unknown')
            WHEN freeze_stress AND sf_target = cur_sf THEN 'hold'
            WHEN freeze_stress                          THEN 'adjust'
            WHEN saturation_cause = 'inhibited'
                 THEN 'escalate:inhibited:' || COALESCE(oldest_xmin_owner,'unknown')
            WHEN saturation_cause = 'io_limited'        THEN 'escalate:io_limited'
            WHEN saturation_cause = 'config'            THEN 'suppressed:not_firing'
            WHEN NOT v_manage AND sf_user_set           THEN 'suppressed:user_owned'
            WHEN sf_target = cur_sf                      THEN 'hold'
            ELSE 'adjust'
        END,
        sf_target::text,
        'class=' || kind::text || ' f*=' || f_template
    FROM q;
    GET DIAGNOSTICS n = ROW_COUNT;

    PERFORM pgfc_govern._reconcile_diagnostics(p_snapshot_id);
    RETURN n;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.plan(bigint, bigint) IS
  'Advisory: write decision_log per relation (vacuum objective) + reconcile diagnostics.';

-- Findings worthy of a diagnostic for the relations in a snapshot: (relid, class,
-- severity, recommendation, evidence). Set-returning so it composes into the
-- reconcile statements without a per-call temp table.
CREATE OR REPLACE FUNCTION pgfc_govern._findings(p_snapshot_id bigint)
RETURNS TABLE (relid oid, inhibitor_class text, severity text,
               recommendation text, evidence jsonb)
LANGUAGE sql STABLE AS $fn$
    SELECT re.relid,
        CASE
            WHEN re.saturation_cause = 'io_limited' THEN 'io_limited'
            WHEN re.saturation_cause = 'config'     THEN 'autovacuum_not_running'
            ELSE sn.oldest_xmin_owner               -- inhibited / freeze-pinned: the owner
        END,
        CASE
            WHEN (re.freeze_debt > 0.6 OR COALESCE(re.mxid_freeze_debt,0) > 0.6)
                 AND sn.oldest_xmin_owner <> 'none'        THEN 'critical'
            WHEN re.saturation_cause = 'inhibited'         THEN 'critical'
            ELSE 'warning'
        END,
        CASE
            WHEN re.saturation_cause = 'io_limited'
                 THEN 'Vacuum runs but cannot keep up (I/O-bound). More aggressive '
                      || 'settings will not help; consider cost limits / more workers (Phase 3).'
            WHEN re.saturation_cause = 'config'
                 THEN 'Debt is high but autovacuum has not run. Check that autovacuum is '
                      || 'enabled and keeping up; lowering thresholds will not help an '
                      || 'already-overdue table.'
            ELSE 'Cleanup blocked by ' || sn.oldest_xmin_owner || ' ('
                 || COALESCE(sn.oldest_xmin_owner_detail,'?')
                 || '); clear it -- more vacuuming cannot advance past a pinned xmin horizon.'
        END,
        jsonb_build_object('saturation_cause', re.saturation_cause,
                           'vacuum_debt_ratio', re.vacuum_debt_ratio,
                           'effectiveness', re.effectiveness,
                           'freeze_debt', re.freeze_debt,
                           'horizon_owner', sn.oldest_xmin_owner,
                           'horizon_age', sn.oldest_xmin_age)
    FROM pgfc_govern.relation_estimate re
    JOIN pgfc_observe.snapshots sn ON sn.snapshot_id = p_snapshot_id
    WHERE re.relid IN (SELECT relid FROM pgfc_observe.current_relation_state(p_snapshot_id))
      AND (re.saturation_cause IN ('inhibited','io_limited','config')
           OR ((re.freeze_debt > 0.6 OR COALESCE(re.mxid_freeze_debt,0) > 0.6)
               AND sn.oldest_xmin_owner <> 'none'));
$fn$;

-- Open a diagnostic per (relid, class) that lacks an unresolved one this cycle, and
-- resolve open findings whose condition has cleared. Keeps active_diagnostics from
-- filling with one duplicate row per control cycle.
CREATE OR REPLACE FUNCTION pgfc_govern._reconcile_diagnostics(p_snapshot_id bigint)
RETURNS void LANGUAGE plpgsql AS $fn$
BEGIN
    -- open new findings (dedup against unresolved ones)
    INSERT INTO pgfc_govern.diagnostics (relid, severity, inhibitor_class, evidence, recommendation)
    SELECT f.relid, f.severity, f.inhibitor_class, f.evidence, f.recommendation
    FROM pgfc_govern._findings(p_snapshot_id) f
    WHERE NOT EXISTS (
        SELECT 1 FROM pgfc_govern.diagnostics d
        WHERE d.resolved_at IS NULL AND d.relid = f.relid
          AND d.inhibitor_class IS NOT DISTINCT FROM f.inhibitor_class);

    -- resolve open findings whose condition cleared this cycle
    UPDATE pgfc_govern.diagnostics d SET resolved_at = now()
    WHERE d.resolved_at IS NULL
      AND d.relid IN (SELECT relid FROM pgfc_observe.current_relation_state(p_snapshot_id))
      AND NOT EXISTS (
        SELECT 1 FROM pgfc_govern._findings(p_snapshot_id) f
        WHERE f.relid = d.relid AND f.inhibitor_class IS NOT DISTINCT FROM d.inhibitor_class);
END
$fn$;

-- ─────────────────────────────────────────────────────────────────────────────
-- apply(): actuate one relation's approved change (Phase 1: present but only ever
-- called when policy.advisory_only = false, which is not the default).
-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 1 implements the scale-factor lever with the real safety mechanics
-- (live-catalog no-op, ownership, baseline capture, 100ms non-blocking lock,
-- failure recording). Batching across objectives and the actuation-economy gates
-- (rate limits) are Phase 2.
CREATE SEQUENCE IF NOT EXISTS pgfc_govern.batch_seq;

CREATE OR REPLACE FUNCTION pgfc_govern.apply(p_tick_id bigint, p_relid oid)
RETURNS boolean LANGUAGE plpgsql AS $fn$
DECLARE
    v_act   text := 'autovacuum_vacuum_scale_factor';
    v_dec   text;
    v_prop  text;
    v_live  text[];
    v_cur   text;
    v_relname text;
    v_batch bigint;
    v_base_explicit boolean;
    v_base_value    text;
    v_decid bigint;
BEGIN
    SELECT decision_id, decision, proposed_value INTO v_decid, v_dec, v_prop
    FROM pgfc_govern.decision_log
    WHERE tick_id = p_tick_id AND relid = p_relid AND actuator = v_act
    ORDER BY decision_id DESC LIMIT 1;
    IF v_dec IS DISTINCT FROM 'adjust' THEN RETURN false; END IF;

    SELECT relname, reloptions INTO v_relname, v_live FROM pg_class WHERE oid = p_relid;
    IF v_relname IS NULL THEN RETURN false; END IF;                 -- relation vanished

    -- complementary to lock_timeout: don't even attempt against a busy table
    IF EXISTS (SELECT 1 FROM pg_stat_progress_vacuum WHERE relid = p_relid) THEN
        RETURN false;                                               -- retried next cycle
    END IF;

    v_cur := pgfc_observe.effective_reloption(v_live, v_act);       -- live ground truth
    IF v_cur IS NOT DISTINCT FROM v_prop THEN RETURN false; END IF; -- no-op vs live

    -- baseline: capture pre-governor state on first touch, never overwrite
    SELECT baseline_explicit, baseline_value INTO v_base_explicit, v_base_value
    FROM pgfc_govern.actuator_state WHERE relid = p_relid AND actuator = v_act;
    IF NOT FOUND THEN
        v_base_explicit := (v_cur IS NOT NULL);
        v_base_value    := v_cur;
    END IF;

    v_batch := nextval('pgfc_govern.batch_seq');

    BEGIN
        SET LOCAL lock_timeout = '100ms';                           -- never wait
        EXECUTE format('ALTER TABLE %s SET (%I = %s)', p_relid::regclass, v_act, v_prop);
    EXCEPTION
        WHEN lock_not_available THEN
            INSERT INTO pgfc_govern.action_history
              (batch_id, decision_id, relid, relname, actuator, old_value, new_value,
               prev_reloptions, status, failure_reason, lock_wait_outcome, budget_consumed)
            VALUES (v_batch, v_decid, p_relid, v_relname, v_act, v_cur, v_prop,
                    v_live, 'failed', 'lock_timeout', 'timeout', false);
            RETURN false;
        WHEN insufficient_privilege THEN
            INSERT INTO pgfc_govern.action_history
              (batch_id, decision_id, relid, relname, actuator, old_value, new_value,
               prev_reloptions, status, failure_reason, budget_consumed)
            VALUES (v_batch, v_decid, p_relid, v_relname, v_act, v_cur, v_prop,
                    v_live, 'failed', 'insufficient_privilege', false);
            RETURN false;
    END;

    -- success: record baseline (first time), the action, and update actuator state
    INSERT INTO pgfc_govern.actuator_state
        (relid, actuator, current_value, baseline_explicit, baseline_value,
         set_at_snapshot, av_count_at_apply)
    VALUES (p_relid, v_act, v_prop, v_base_explicit, v_base_value,
            (SELECT max(snapshot_id) FROM pgfc_observe.snapshots),
            (SELECT autovacuum_count FROM pg_stat_all_tables WHERE relid = p_relid))
    ON CONFLICT (relid, actuator) DO UPDATE SET
        current_value     = EXCLUDED.current_value,
        set_at_snapshot   = EXCLUDED.set_at_snapshot,
        av_count_at_apply = EXCLUDED.av_count_at_apply;

    INSERT INTO pgfc_govern.action_history
      (batch_id, decision_id, relid, relname, actuator, old_value, new_value,
       prev_reloptions, revert_kind, revert_value, status, lock_wait_outcome, budget_consumed)
    VALUES (v_batch, v_decid, p_relid, v_relname, v_act, v_cur, v_prop, v_live,
            CASE WHEN v_base_explicit THEN 'SET' ELSE 'RESET' END, v_base_value,
            'applied', 'acquired', true);

    UPDATE pgfc_govern.decision_log SET applied = true WHERE decision_id = v_decid;
    RETURN true;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.apply(bigint, oid) IS
  'Actuate one relation''s approved scale-factor change (gated by advisory_only).';

-- ─────────────────────────────────────────────────────────────────────────────
-- verify(): close the loop on past actions. Phase 1 has nothing applied to verify;
-- expanded in Phase 2 to attribute realized outcomes against predictions.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgfc_govern.verify(p_tick_id bigint)
RETURNS integer LANGUAGE sql AS $fn$
    SELECT 0;   -- Phase 2: attribute outcomes of earlier applied actions
$fn$;
COMMENT ON FUNCTION pgfc_govern.verify(bigint) IS
  'Close the control loop on past actions (Phase 1: no-op; expanded in Phase 2).';

-- ─────────────────────────────────────────────────────────────────────────────
-- Orchestrators (driven by pg_cron in production; see README)
-- ─────────────────────────────────────────────────────────────────────────────

-- Fast loop (~1 min): observe + classify + estimate. Never actuates.
CREATE OR REPLACE FUNCTION pgfc_govern.observe_tick()
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE v_snap bigint;
BEGIN
    v_snap := pgfc_observe.observe();
    PERFORM pgfc_govern.classify(v_snap);
    PERFORM pgfc_govern.estimate(v_snap);
    RETURN v_snap;
END
$fn$;

-- Control loop (~5 min): plan + (apply, only if not advisory_only) + verify.
CREATE OR REPLACE FUNCTION pgfc_govern.control_tick()
RETURNS bigint LANGUAGE plpgsql AS $fn$
DECLARE
    v_tick bigint; v_snap bigint; v_adv boolean; v_applied integer := 0; r record;
BEGIN
    PERFORM pg_advisory_xact_lock(hashtext('pgfc_govern.control_tick'));  -- no overlap
    SELECT advisory_only INTO v_adv FROM pgfc_govern.policy
      WHERE enabled ORDER BY policy_name LIMIT 1;
    v_adv := COALESCE(v_adv, true);

    SELECT max(snapshot_id) INTO v_snap FROM pgfc_observe.snapshots;
    INSERT INTO pgfc_govern.tick_log (snapshot_id) VALUES (v_snap) RETURNING tick_id INTO v_tick;

    PERFORM pgfc_govern.plan(v_tick, v_snap);

    IF NOT v_adv THEN
        FOR r IN SELECT relid FROM pgfc_govern.decision_log
                 WHERE tick_id = v_tick AND decision = 'adjust'
        LOOP
            IF pgfc_govern.apply(v_tick, r.relid) THEN v_applied := v_applied + 1; END IF;
        END LOOP;
    END IF;

    PERFORM pgfc_govern.verify(v_tick);

    UPDATE pgfc_govern.tick_log SET
        finished_at = now(), n_applied = v_applied,
        n_decisions = (SELECT count(*) FROM pgfc_govern.decision_log WHERE tick_id = v_tick),
        n_relations = (SELECT count(DISTINCT relid) FROM pgfc_govern.decision_log WHERE tick_id = v_tick)
    WHERE tick_id = v_tick;
    RETURN v_tick;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.control_tick() IS
  'One control cycle: plan, apply (only if not advisory_only), verify.';

-- ─────────────────────────────────────────────────────────────────────────────
-- Views
-- ─────────────────────────────────────────────────────────────────────────────

-- Per-relation operator view: class, target, observed state, last decision.
CREATE OR REPLACE VIEW pgfc_govern.governor_status AS
WITH pol AS (SELECT aggressiveness FROM pgfc_govern.policy
             WHERE enabled ORDER BY policy_name LIMIT 1)
SELECT rc.relid, rc.schemaname, rc.relname, rc.kind,
       re.f_trigger_ewma AS observed_dead_fraction,          -- diagnostic (biased)
       LEAST(GREATEST(
           (CASE rc.kind WHEN 'queue' THEN 0.05 WHEN 'delete_heavy' THEN 0.10
                         WHEN 'oltp' THEN 0.20 WHEN 'mixed' THEN 0.20
                         WHEN 'append_only' THEN 0.40 WHEN 'archive' THEN 0.50 END)
           / COALESCE(p.aggressiveness, 1.0), 0.01), 0.50)    AS target_dead_fraction,
       re.vacuum_debt_ratio, re.freeze_debt, re.saturation_cause,
       d.decision, d.proposed_value, d.applied, d.created_at AS last_decision_at,
       a.current_value AS current_scale_factor
FROM pgfc_govern.relation_class rc
CROSS JOIN pol p
LEFT JOIN pgfc_govern.relation_estimate re USING (relid)
LEFT JOIN LATERAL (
    SELECT * FROM pgfc_govern.decision_log dl
    WHERE dl.relid = rc.relid ORDER BY dl.decision_id DESC LIMIT 1
) d ON true
LEFT JOIN pgfc_govern.actuator_state a
       ON a.relid = rc.relid AND a.actuator = 'autovacuum_vacuum_scale_factor';

-- Catalog-mutation health: the governor's own DDL footprint + live pg_class state.
CREATE OR REPLACE VIEW pgfc_govern.catalog_health AS
SELECT
    (SELECT count(*) FROM pgfc_govern.action_history
      WHERE status='applied' AND applied_at > now() - interval '1 hour')  AS mutations_last_hour,
    (SELECT count(*) FROM pgfc_govern.action_history
      WHERE status='applied' AND applied_at > now() - interval '1 day')   AS mutations_last_day,
    (SELECT count(*) FROM pgfc_govern.action_history
      WHERE status='failed'  AND applied_at > now() - interval '1 day')   AS failed_last_day,
    (SELECT count(DISTINCT relid) FROM pgfc_govern.action_history
      WHERE status='applied' AND applied_at > now() - interval '1 day')   AS relations_changed_last_day,
    sn.pg_class_size_bytes, sn.pg_class_n_dead_tup, sn.pg_class_n_live_tup,
    sn.pg_class_last_autovacuum, sn.collected_at
FROM pgfc_observe.snapshots sn ORDER BY sn.snapshot_id DESC LIMIT 1;

-- Unresolved maintenance-inhibitor / saturation findings, critical first.
CREATE OR REPLACE VIEW pgfc_govern.active_diagnostics AS
SELECT diagnostic_id, detected_at, severity, relid, inhibitor_class, recommendation, evidence
FROM pgfc_govern.diagnostics
WHERE resolved_at IS NULL
ORDER BY (severity = 'critical') DESC, detected_at DESC;

-- ─────────────────────────────────────────────────────────────────────────────
-- Retention  (Appendix D; design "Observation storage and self-maintenance", S1)
-- ─────────────────────────────────────────────────────────────────────────────

-- Prune the append-only audit tables by time cutoff. These tables are low-volume
-- (≤ ~1 action/relation/hour, one tick/cycle), so a simple DELETE cutoff is adequate
-- here; the high-volume observe tables use partition rotation instead (later S2+).
-- policy_history is NOT pruned — it is retained indefinitely (Appendix D, pruned last).
--
-- Ordering respects the action_history -> decision_log FK: actions prune first, and a
-- decision is kept while any retained action still references it (so a retained action
-- never loses its decision). Diagnostics prune only when resolved — an old UNRESOLVED
-- finding is a live alert (surfaced by active_diagnostics) and must not age out.
--
-- Schedule daily with pg_cron, e.g.:
--   SELECT cron.schedule('pgfc_govern_retain', '17 3 * * *',
--                        $$ SELECT pgfc_govern.retain() $$);
CREATE OR REPLACE FUNCTION pgfc_govern.retain(
    keep_decisions   interval DEFAULT '180 days',
    keep_actions     interval DEFAULT '180 days',
    keep_ticks       interval DEFAULT '180 days',
    keep_diagnostics interval DEFAULT '365 days')
RETURNS TABLE(relation text, deleted bigint)
LANGUAGE plpgsql AS $fn$
BEGIN
    -- 1. Actions first (child of decision_log).
    RETURN QUERY
    WITH d AS (DELETE FROM pgfc_govern.action_history
               WHERE applied_at < now() - keep_actions RETURNING 1)
    SELECT 'action_history'::text, count(*) FROM d;

    -- 2. Decisions, but keep any still referenced by a (retained) action.
    RETURN QUERY
    WITH d AS (DELETE FROM pgfc_govern.decision_log dl
               WHERE dl.created_at < now() - keep_decisions
                 AND NOT EXISTS (SELECT 1 FROM pgfc_govern.action_history ah
                                 WHERE ah.decision_id = dl.decision_id)
               RETURNING 1)
    SELECT 'decision_log'::text, count(*) FROM d;

    -- 3. Tick orchestration log.
    RETURN QUERY
    WITH d AS (DELETE FROM pgfc_govern.tick_log
               WHERE started_at < now() - keep_ticks RETURNING 1)
    SELECT 'tick_log'::text, count(*) FROM d;

    -- 4. Diagnostics — resolved only; unresolved findings are live and never aged out.
    RETURN QUERY
    WITH d AS (DELETE FROM pgfc_govern.diagnostics
               WHERE resolved_at IS NOT NULL
                 AND detected_at < now() - keep_diagnostics RETURNING 1)
    SELECT 'diagnostics'::text, count(*) FROM d;
END;
$fn$;
COMMENT ON FUNCTION pgfc_govern.retain(interval, interval, interval, interval) IS
  'Prune audit tables by time cutoff (decisions/actions 180d, ticks 180d, resolved diagnostics 365d); policy_history is never pruned. Returns per-table delete counts.';
