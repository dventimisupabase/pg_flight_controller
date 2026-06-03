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
COMMENT ON TYPE pgfc_govern.relation_kind IS
  'Workload-class template a relation is assigned to by classify(); selects its desired dead-tuple target. [subsystem:G1]';

-- Governor health states (Phase 1.7 F2 — self-protection). Declared in order of
-- INCREASING caution, so the enum's native ordering means "worst state wins": the
-- evaluator takes the most cautious state any signal demands, and an operator can only
-- force MORE caution, never less (F3). Capabilities per state (enforced by the apply()
-- authority gate in F4, not here): normal = full; degraded = observe/estimate/diagnose +
-- limited actuation; diagnostic = those, no actuation except permitted safety actions;
-- emergency = minimal observation + health reporting, no actuation; disabled = nothing
-- (history preserved). The automatic evaluator ranges normal→emergency; disabled is
-- operator-forced only (F3).
DO $$
BEGIN
    CREATE TYPE pgfc_govern.governor_health_state AS ENUM
        ('normal','degraded','diagnostic','emergency','disabled');
EXCEPTION WHEN duplicate_object THEN
    NULL;
END $$;
COMMENT ON TYPE pgfc_govern.governor_health_state IS
  'Governor self-protection states (Phase 1.7 F2) declared in increasing-caution order, so the enum''s native ordering makes the most cautious state win. [subsystem:G4]';

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
    -- actuator-economy / catalog-mutation knobs
    min_interval       interval NOT NULL DEFAULT '1 hour',      -- per-relation rate limit
    global_max_changes_per_cycle integer NOT NULL DEFAULT 50,   -- cluster cap / cycle
    daily_mutation_budget integer NOT NULL DEFAULT 500,         -- cluster cap / day
    n_sustain          integer NOT NULL DEFAULT 3,              -- sustained-deviation cycles
    manage_user_owned  boolean NOT NULL DEFAULT false,          -- overwrite user reloptions?
    enabled            boolean NOT NULL DEFAULT true,
    advisory_only      boolean NOT NULL DEFAULT true            -- dry-run gate
);
COMMENT ON TABLE pgfc_govern.policy IS
  'Operator-expressed outcomes. advisory_only=true means plan but never apply. [subsystem:G2]';
COMMENT ON COLUMN pgfc_govern.policy.manage_user_owned IS
  'false: never overwrite a reloption set by a user/other system first; true: take ownership.';

-- A single default advisory policy so the loop is operable out of the box.
INSERT INTO pgfc_govern.policy (policy_name, description)
VALUES ('default', 'Default advisory policy (plans, never applies)')
ON CONFLICT (policy_name) DO NOTHING;

-- Policy history: human-owned desired-state changes over time.
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
  'Append-only audit of policy changes (insert/update/delete); retained indefinitely. [subsystem:G2]';

CREATE OR REPLACE FUNCTION pgfc_govern._log_policy_change()
RETURNS trigger LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
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
  'AFTER row trigger: records every policy insert/update/delete into policy_history. [subsystem:G2]';

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
COMMENT ON TABLE pgfc_govern.relation_class IS
  'Per-relation workload classification with hysteresis (candidate/streak): the desired-state template feeding plan(). [subsystem:G1]';

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
    -- effectiveness & saturation
    effectiveness       double precision,
    freeze_progressing  boolean,
    saturation_cause    text,             -- NULL | 'config' | 'io_limited' | 'inhibited'
    saturation_candidate text,            -- pending cause (streak/hysteresis state)
    saturation_streak   integer NOT NULL DEFAULT 0,
    estimated_at        timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE pgfc_govern.relation_estimate IS
  'Latest derived hidden state per relation from estimate(): rates, effectiveness, and saturation diagnosis (one row per relation). [subsystem:G1]';

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
COMMENT ON TABLE pgfc_govern.actuator_state IS
  'Current governor-set value and rollback baseline per (relation, actuator); baseline_explicit drives SET-vs-RESET on revert. [subsystem:G1]';
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
    -- Adaptive-value provenance (Appendix E): the estimated benefit of an adjust — the
    -- change in the allowed dead fraction (current scale factor − proposed). Sign is
    -- direction: positive = tightening (kept cleaner), negative = loosening. NULL when the
    -- decision changes nothing (hold / suppressed / escalate).
    estimated_benefit double precision,
    applied        boolean NOT NULL DEFAULT false,
    created_at     timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE pgfc_govern.decision_log IS
  'Audit of every control decision (applied or not): observation, prior/desired state, the decision, and proposed value. [subsystem:G1]';

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
    -- Failure taxonomy (Phase 1.7 F6): the appendix-F category this failure belongs to,
    -- derived from failure_reason by _failure_class(). NULL when status='applied'. The CHECK
    -- pins the five-category vocabulary at the schema level.
    failure_class  text CONSTRAINT action_history_failure_class_check
                    CHECK (failure_class IS NULL
                    OR failure_class IN ('observation','decision','actuation','resource','safety')),
    lock_wait_outcome text,
    budget_consumed boolean NOT NULL DEFAULT false,   -- only true for applied non-emergency
    emergency_override boolean NOT NULL DEFAULT false,
    applied_at     timestamptz NOT NULL DEFAULT now(),
    reverted_at    timestamptz
);
COMMENT ON TABLE pgfc_govern.action_history IS
  'Every actuator attempt (applied or failed). revert() replays only status=applied. failed rows carry failure_reason + the F6 failure_class (taxonomy category). [subsystem:G1]';

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
COMMENT ON TABLE pgfc_govern.tick_log IS
  'Per control-cycle orchestration log: snapshot, timing, relation/decision/applied counts, and any error. [subsystem:G1]';

-- Diagnostic findings: saturation root-cause + actionable recommendation.
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
  'Per-relation findings + a recommendation, not more DDL: maintenance-inhibitor / saturation causes, and governor-scope findings such as control oscillation (Phase 1.7 F5). [subsystem:G5]';

-- Governor health state (Phase 1.7 F2). The current self-protection state, computed by
-- evaluate_health() from the governor_metrics substrate. Enforced singleton (constant-true
-- PK), mirroring storage_config. The operator-forced override (Phase 1.7 F3) lives in the
-- operator_forced/forced_* columns (NULL operator_forced = fully automatic); it is a
-- caution FLOOR honored by evaluate_health() — a human can force MORE caution, never less.
-- Seeded once at install; never reset on re-install.
CREATE TABLE IF NOT EXISTS pgfc_govern.governor_state (
    singleton       boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    state           pgfc_govern.governor_health_state NOT NULL DEFAULT 'normal',
    since           timestamptz NOT NULL DEFAULT now(),   -- when the current state was entered
    reason          text,                                 -- human-readable cause of the state
    evaluated_at    timestamptz,                          -- last evaluate_health() run (NULL = never)
    -- Operator-forced override (F3): a caution floor. NULL = automatic.
    operator_forced pgfc_govern.governor_health_state,    -- state a human forced (NULL = none)
    forced_reason   text,                                 -- why the operator placed the hold
    forced_by       text,                                 -- who placed it (current_user at force time)
    forced_at       timestamptz                           -- when it was placed
);
COMMENT ON TABLE pgfc_govern.governor_state IS
  'Single-row governor health state (Phase 1.7 F2): the current self-protection state computed by evaluate_health(). The operator_forced/forced_* columns hold the F3 human override — a caution floor (force more caution, never less). Advisory; the apply() authority gate consults it in F4. [subsystem:G4]';
COMMENT ON COLUMN pgfc_govern.governor_state.operator_forced IS
  'Operator-forced health state (Phase 1.7 F3); NULL = fully automatic. evaluate_health() takes the WORST of this and the auto-computed state, so the operator can force more caution but never less. Set via force_state()/disable()/suspend_actuation(); cleared via clear_forced_state().';

INSERT INTO pgfc_govern.governor_state (singleton, reason)
VALUES (true, 'initialized at install')
ON CONFLICT (singleton) DO NOTHING;

-- Append-only audit of every health-state change (Phase 1.7 F2). Pruned by retain() like
-- the other audit tables. triggering_condition captures the metrics snapshot that drove
-- the transition, so a past escalation can be explained without the metrics being retained.
CREATE TABLE IF NOT EXISTS pgfc_govern.state_transitions (
    transition_id        bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    from_state           pgfc_govern.governor_health_state,   -- NULL only if ever pre-seed
    to_state             pgfc_govern.governor_health_state NOT NULL,
    reason               text,
    triggering_condition jsonb,                               -- governor_metrics at transition
    transitioned_at      timestamptz NOT NULL DEFAULT now()
);
COMMENT ON TABLE pgfc_govern.state_transitions IS
  'Append-only audit of governor health-state transitions (Phase 1.7 F2): from/to state, reason, and the metrics snapshot that triggered it. Pruned by retain(). [subsystem:G4]';

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
COMMENT ON FUNCTION pgfc_govern.ewma(double precision, double precision, double precision) IS
  'Exponentially-weighted moving average (alpha*sample + (1-alpha)*prior); NULL-safe, seeds on the first sample. [subsystem:G1]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Parameter accessors  (Phase 1.6 — parameter governance, P2)
-- ─────────────────────────────────────────────────────────────────────────────
-- The control logic reads its governed constants THROUGH these accessors, so the
-- registry (_parameter_registry(), defined later in this file) is the one value both the
-- code and the operator-facing view read — no parallel literal. plpgsql so the body
-- resolves _parameter_registry() at runtime (it is defined below); IMMUTABLE because the
-- registry is a constant VALUES list, so constant-argument calls fold. Callers cast to
-- the column's native type. A CI "registry up to date" gate (P3) will then make it
-- impossible for a control literal to exist outside the registry.
CREATE OR REPLACE FUNCTION pgfc_govern._param(p_name text)
RETURNS text IMMUTABLE LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE v text;
BEGIN
    SELECT default_value INTO v FROM pgfc_govern._parameter_registry()
     WHERE parameter_name = p_name;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'pgfc_govern._param: unknown parameter %', p_name;
    END IF;
    RETURN v;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern._param(text) IS
  'Read a governed parameter''s value from the registry (Phase 1.6 P2); the control logic single-sources its constants through this. [subsystem:G3]';

CREATE OR REPLACE FUNCTION pgfc_govern._sf_grid()
RETURNS double precision[] IMMUTABLE LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
BEGIN
    RETURN pgfc_govern._param('sf_grid')::double precision[];
END
$fn$;
COMMENT ON FUNCTION pgfc_govern._sf_grid() IS
  'Scale-factor quantization grid, read from the registry (Phase 1.6 P2). [subsystem:G1]';

CREATE OR REPLACE FUNCTION pgfc_govern._class_target(p_kind text)
RETURNS double precision IMMUTABLE LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
BEGIN
    RETURN pgfc_govern._param('target_' || p_kind)::double precision;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern._class_target(text) IS
  'Base (pre-aggressiveness) target dead-tuple fraction for a workload class, read from the registry (Phase 1.6 P2). [subsystem:G1]';

-- Guard the aggressiveness divisor (FMEA-008, #96). policy.aggressiveness has no CHECK, so an
-- operator can set it <= 0 (or it is NULL with no enabled policy); the class target is
-- `template / aggressiveness`, so a non-positive value is a divide-by-zero / sign inversion that
-- would wedge plan() and throw the governor_status view. Single-source the guard here: the raw
-- value if > 0, else the registry default. Defense-in-depth, NOT enforcement — validate_parameters()
-- still grades <= 0 as CRITICAL, so the operator is loudly warned; the control loop and the status
-- view simply stay up at the default rather than failing. (A CHECK would enforce instead, but that
-- reverses the deliberate advisory-validation design; left to the maintainer per FMEA-008.)
CREATE OR REPLACE FUNCTION pgfc_govern._effective_aggressiveness(p_raw double precision)
RETURNS double precision IMMUTABLE LANGUAGE sql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
    SELECT CASE WHEN p_raw > 0 THEN p_raw
                ELSE pgfc_govern._param('aggressiveness')::double precision END
$fn$;
COMMENT ON FUNCTION pgfc_govern._effective_aggressiveness(double precision) IS
  'Guard the aggressiveness divisor (FMEA-008): the raw value if > 0, else the registry default — so a non-positive policy.aggressiveness (flagged CRITICAL by validate_parameters) cannot divide-by-zero in plan() or governor_status. [subsystem:G1]';

-- Update relation_estimate for every relation in snapshot p_snapshot_id. Reads
-- indicators from pgfc_observe.maintenance_debt (no re-derivation of thresholds) and
-- raw samples only for cross-snapshot deltas. Returns rows written.
CREATE OR REPLACE FUNCTION pgfc_govern.estimate(p_snapshot_id bigint)
RETURNS integer LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE
    v_tau     double precision := pgfc_govern._param('ewma_tau')::double precision;   -- rate EWMA time constant (s)
    v_effa    double precision := pgfc_govern._param('ewma_effa')::double precision;  -- effectiveness/peak EWMA weight
    v_k       integer          := pgfc_govern._param('saturation_persistence_k')::integer;  -- cycles a cause must persist
    v_eff_low double precision := pgfc_govern._param('eff_low')::double precision;    -- effectiveness below = ineffective
    v_av_window interval        := pgfc_govern._param('av_running_window')::interval;  -- "autovacuum recently ran" window
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
             AND last_autovacuum > collected_at - v_av_window)         AS av_running,
            (COALESCE(vacuum_debt_ratio, 0) > 1)                       AS debt_high,
            (COALESCE(effectiveness, 1) < v_eff_low)                   AS eff_low,
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
  'Derive hidden state (rates, effectiveness, saturation) into relation_estimate. [subsystem:G1]';

-- ─────────────────────────────────────────────────────────────────────────────
-- classify(): assign each relation a workload class (with a signal floor + hysteresis)
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgfc_govern.classify(p_snapshot_id bigint)
RETURNS integer LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE
    v_floor bigint  := GREATEST(pgfc_govern._param('classify_floor')::bigint, 1);  -- min recent writes before classifying on fractions; >= 1 so a 0 floor can't 0/0 the write-fraction on a no-write relation (FMEA-009)
    v_large real    := pgfc_govern._param('classify_large')::real;    -- reltuples above which an idle relation is 'archive'
    v_ins_frac  double precision := pgfc_govern._param('classify_append_only_ins_frac')::double precision;
    v_del_frac  double precision := pgfc_govern._param('classify_delete_frac')::double precision;
    v_bal_frac  double precision := pgfc_govern._param('classify_queue_balance_frac')::double precision;
    v_aodel_frac double precision := pgfc_govern._param('classify_append_only_del_frac')::double precision;
    v_nsus  integer;
    n integer;
BEGIN
    SELECT n_sustain INTO v_nsus FROM pgfc_govern.policy
      WHERE enabled ORDER BY policy_name LIMIT 1;
    v_nsus := COALESCE(v_nsus, pgfc_govern._param('class_persistence_n_sustain')::integer);

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
                    WHEN din::float8 /(din+dupd+ddel) > v_ins_frac
                         AND ddel::float8/(din+dupd+ddel) < v_aodel_frac THEN 'append_only'
                    WHEN ddel::float8/(din+dupd+ddel) > v_del_frac
                         AND abs(ddel::float8/(din+dupd+ddel)
                                 - din::float8/(din+dupd+ddel)) < v_bal_frac THEN 'queue'
                    WHEN ddel::float8/(din+dupd+ddel) > v_del_frac THEN 'delete_heavy'
                    WHEN dupd::float8/(din+dupd+ddel) > v_del_frac THEN 'oltp'
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
  'Assign each relation a workload class with a signal floor and N-cycle hysteresis. [subsystem:G1]';

-- ─────────────────────────────────────────────────────────────────────────────
-- plan(): decide per-relation setpoints (advisory) + reconcile diagnostics
-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 1 scope: the VACUUM objective via the scale-factor lever. The threshold
-- lever (small tables) and the ANALYZE objective are deferred follow-ups. The
-- actuation-economy gates (rate limits, sustained-deviation) are deferred to Phase 2
-- since apply() is gated off here; plan() only writes the decision/diagnosis trail.

-- Snap a scale factor to the bounded grid (SF_GRID, single-sourced from the registry).
CREATE OR REPLACE FUNCTION pgfc_govern.snap_sf(x double precision)
RETURNS double precision IMMUTABLE LANGUAGE sql AS $$
    SELECT g FROM unnest(pgfc_govern._sf_grid()) AS grid(g)
    ORDER BY abs(g - x) LIMIT 1
$$;
COMMENT ON FUNCTION pgfc_govern.snap_sf(double precision) IS
  'Snap a scale factor to the nearest value on the bounded quantization grid (_sf_grid). [subsystem:G1]';

CREATE OR REPLACE FUNCTION pgfc_govern.plan(p_tick_id bigint, p_snapshot_id bigint)
RETURNS integer LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE
    v_sf_min     double precision := pgfc_govern._param('sf_min')::double precision;
    v_sf_max     double precision := pgfc_govern._param('sf_max')::double precision;
    v_freeze_thr double precision := pgfc_govern._param('freeze_thr')::double precision;
    v_aggr       double precision;
    v_manage     boolean;
    n integer;
BEGIN
    SELECT aggressiveness, manage_user_owned INTO v_aggr, v_manage
      FROM pgfc_govern.policy WHERE enabled ORDER BY policy_name LIMIT 1;
    -- FMEA-008 (#96): guard the divisor — a non-positive or NULL aggressiveness falls back to the
    -- registry default rather than dividing by zero below (which would wedge this control loop).
    v_aggr   := pgfc_govern._effective_aggressiveness(v_aggr);
    v_manage := COALESCE(v_manage, pgfc_govern._param('manage_user_owned')::boolean);

    INSERT INTO pgfc_govern.decision_log
      (tick_id, relid, actuator, observation, prev_state, desired_state,
       decision, proposed_value, policy_rule, estimated_benefit)
    WITH
    base AS (
        SELECT rc.relid, rc.kind, rs.reltuples, rs.reloptions,
               sn.def_vac_scale_factor, sn.def_vac_threshold,
               sn.oldest_xmin_owner, sn.oldest_xmin_owner_detail,
               re.saturation_cause, re.freeze_debt, re.mxid_freeze_debt,
               re.vacuum_debt_ratio, re.effectiveness,
               -- COR-001 (#66): the governor's own actuation history for this relation, so
               -- the ownership guard below can tell its own prior change from a human's.
               -- baseline_explicit IS NULL means "no governor row" (never touched).
               ast.baseline_explicit AS ast_baseline_explicit,
               ast.current_value     AS ast_current_value
        FROM pgfc_govern.relation_class rc
        JOIN pgfc_govern.relation_estimate re ON re.relid = rc.relid
        JOIN pgfc_observe.current_relation_state(p_snapshot_id) rs ON rs.relid = rc.relid
        JOIN pgfc_observe.snapshots sn ON sn.snapshot_id = p_snapshot_id
        LEFT JOIN pgfc_govern.actuator_state ast
               ON ast.relid = rc.relid
              AND ast.actuator = 'autovacuum_vacuum_scale_factor'
    ),
    tgt AS (
        SELECT *,
            pgfc_govern._class_target(kind::text) AS f_template,
            COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor')::float8,
                     def_vac_scale_factor) AS cur_sf,
            COALESCE(pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_threshold')::bigint,
                     def_vac_threshold)    AS cur_base,
            -- COR-001 (#66): "user-owned" means an explicit setting the GOVERNOR is not
            -- responsible for -- the column comment's "set by a user/other system first".
            -- A bare "an explicit value exists now" test conflates the governor's own prior
            -- actuation with a human's, freezing active control to one touch per relation.
            -- The governor owns the live value only when it has a baseline row, it
            -- INTRODUCED the option (baseline_explicit = false, not user-set-first), and the
            -- live value still equals what it last set (no human ALTER since). Comparison is
            -- text IS NOT DISTINCT FROM, matching apply()'s no-op arbiter.
            (
                pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor') IS NOT NULL
                AND NOT (
                    ast_baseline_explicit IS NOT NULL          -- governor has touched it
                    AND NOT ast_baseline_explicit              -- and introduced the option (not user-first)
                    AND pgfc_observe.effective_reloption(reloptions,'autovacuum_vacuum_scale_factor')
                        IS NOT DISTINCT FROM ast_current_value -- and no human changed it since
                )
            )                              AS sf_user_set,
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
    ),
    dec AS (
        SELECT *,
            -- precedence: freeze floor dominates saturation suppression
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
            END AS decision
        FROM q
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
        decision,
        sf_target::text,
        'class=' || kind::text || ' f*=' || f_template,
        -- estimated benefit: the tightening this adjust applies (NULL when nothing changes)
        CASE WHEN decision = 'adjust' THEN cur_sf - sf_target END
    FROM dec;
    GET DIAGNOSTICS n = ROW_COUNT;

    PERFORM pgfc_govern._reconcile_diagnostics(p_snapshot_id);
    PERFORM pgfc_govern._reconcile_oscillation();   -- Phase 1.7 F5: governor-scope finding
    RETURN n;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.plan(bigint, bigint) IS
  'Advisory: write decision_log per relation (vacuum objective) + reconcile diagnostics (saturation + Phase 1.7 F5 control oscillation). [subsystem:G1]';

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
            WHEN (re.freeze_debt > pgfc_govern._param('freeze_thr')::double precision OR COALESCE(re.mxid_freeze_debt,0) > pgfc_govern._param('freeze_thr')::double precision)
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
           OR ((re.freeze_debt > pgfc_govern._param('freeze_thr')::double precision OR COALESCE(re.mxid_freeze_debt,0) > pgfc_govern._param('freeze_thr')::double precision)
               AND sn.oldest_xmin_owner <> 'none'));
$fn$;
COMMENT ON FUNCTION pgfc_govern._findings(bigint) IS
  'Set-returning: candidate diagnostic findings for a snapshot''s relations (saturation cause / freeze-pinned horizon) with severity, recommendation, and evidence. [subsystem:G5]';

-- Open a diagnostic per (relid, class) that lacks an unresolved one this cycle, and
-- resolve open findings whose condition has cleared. Keeps active_diagnostics from
-- filling with one duplicate row per control cycle.
CREATE OR REPLACE FUNCTION pgfc_govern._reconcile_diagnostics(p_snapshot_id bigint)
RETURNS void LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
BEGIN
    -- open new findings (dedup against unresolved ones)
    INSERT INTO pgfc_govern.diagnostics (relid, severity, inhibitor_class, evidence, recommendation)
    SELECT f.relid, f.severity, f.inhibitor_class, f.evidence, f.recommendation
    FROM pgfc_govern._findings(p_snapshot_id) f
    WHERE NOT EXISTS (
        SELECT 1 FROM pgfc_govern.diagnostics d
        WHERE d.resolved_at IS NULL AND d.relid = f.relid
          AND d.inhibitor_class IS NOT DISTINCT FROM f.inhibitor_class);

    -- resolve open findings whose condition cleared this cycle. Scoped to the saturation
    -- classes this reconciler owns: control_oscillation diagnostics (Phase 1.7 F5) are owned
    -- by _reconcile_oscillation() — they attach to a LIVE relid that _findings never emits, so
    -- without this exclusion the NOT EXISTS below would resolve them every cycle, churning a
    -- fresh finding each tick instead of one stable, persisting alert.
    UPDATE pgfc_govern.diagnostics d SET resolved_at = now()
    WHERE d.resolved_at IS NULL
      AND d.inhibitor_class IS DISTINCT FROM 'control_oscillation'
      AND d.relid IN (SELECT relid FROM pgfc_observe.current_relation_state(p_snapshot_id))
      AND NOT EXISTS (
        SELECT 1 FROM pgfc_govern._findings(p_snapshot_id) f
        WHERE f.relid = d.relid AND f.inhibitor_class IS NOT DISTINCT FROM d.inhibitor_class);
END
$fn$;
COMMENT ON FUNCTION pgfc_govern._reconcile_diagnostics(bigint) IS
  'Open a diagnostic per (relid, class) lacking an unresolved one this cycle, and resolve findings whose condition cleared (control_oscillation diagnostics excluded — owned by the oscillation reconciler). [subsystem:G5]';

-- ─────────────────────────────────────────────────────────────────────────────
-- apply(): actuate one relation's approved change (Phase 1: present but only ever
-- called when policy.advisory_only = false, which is not the default).
-- ─────────────────────────────────────────────────────────────────────────────
-- Phase 1 implements the scale-factor lever with the real safety mechanics
-- (live-catalog no-op, ownership, baseline capture, 100ms non-blocking lock,
-- failure recording). Batching across objectives and the actuation-economy gates
-- (rate limits) are Phase 2.
CREATE SEQUENCE IF NOT EXISTS pgfc_govern.batch_seq;

-- ─────────────────────────────────────────────────────────────────────────────
-- Failure taxonomy  (Phase 1.7 F6 — governor self-protection)
-- ─────────────────────────────────────────────────────────────────────────────
-- Appendix F "Failure Classification": every governor failure belongs to one of five
-- categories — observation / decision / actuation / resource / safety. This function is the
-- single source of truth mapping a recorded failure_reason to its category; apply() stamps
-- action_history.failure_class through it, and the additive backfill below labels historical
-- rows. IMMUTABLE (a pure lookup) so it is safe in generated/indexed contexts. Today the
-- governor records only actuation failures (apply()'s lock_timeout / insufficient_privilege),
-- so the codomain enumerated here is wider than what is currently produced — that is
-- deliberate: it fixes the vocabulary for the failure sites later actuators will add (a
-- conflicting-DDL actuation failure, a sampling observation failure, …). The other categories'
-- *current* conditions are not action_history rows; they surface through their own channels and
-- are unified for operators by the failure_taxonomy view below. No numeric literals, so it
-- stays clean under the P3 drift gate (which scans this body).
CREATE OR REPLACE FUNCTION pgfc_govern._failure_class(p_failure_reason text)
RETURNS text LANGUAGE sql IMMUTABLE AS $fn$
    SELECT CASE p_failure_reason
        -- actuation failures: the governor tried to act and the action itself failed
        WHEN 'lock_timeout'           THEN 'actuation'   -- could not acquire the lock in time
        WHEN 'insufficient_privilege' THEN 'actuation'   -- not allowed to ALTER the relation
        WHEN 'conflicting_ddl'        THEN 'actuation'   -- (future) a concurrent DDL conflict
        ELSE NULL   -- unknown/unclassified reason: leave NULL rather than mislabel
    END;
$fn$;
COMMENT ON FUNCTION pgfc_govern._failure_class(text) IS
  'Failure taxonomy (Phase 1.7 F6): map a recorded failure_reason to its appendix-F category (observation/decision/actuation/resource/safety). Single source of the mapping; apply() stamps action_history.failure_class through it. IMMUTABLE pure lookup; NULL for an unknown reason. [subsystem:G4]';

CREATE OR REPLACE FUNCTION pgfc_govern.apply(p_tick_id bigint, p_relid oid)
RETURNS boolean LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE
    v_act   text := 'autovacuum_vacuum_scale_factor';
    v_dec   text;
    v_prop  text;
    -- SEC-002 (#69): range-check locals for the value spliced into the ALTER TABLE.
    v_prop_num double precision;
    v_sf_min   double precision := pgfc_govern._param('sf_min')::double precision;
    v_sf_max   double precision := pgfc_govern._param('sf_max')::double precision;
    v_live  text[];
    v_cur   text;
    v_relname text;
    v_batch bigint;
    v_base_explicit boolean;
    v_base_value    text;
    v_decid bigint;
    -- FMEA-006 (#83) — actuation-point ownership re-check.
    v_gov_value  text;       -- the value the governor last set (actuator_state.current_value)
    v_have_state boolean;    -- does an actuator_state row exist for this (relid, actuator)?
    v_manage     boolean;    -- policy.manage_user_owned (COALESCE registry default)
    -- Phase 1.7 F4 — authority gate + Invariant-4 mutation budget.
    v_state        pgfc_govern.governor_health_state;
    v_min_interval interval;
    v_max_cycle    integer;
    v_daily_budget integer;
BEGIN
    SELECT decision_id, decision, proposed_value INTO v_decid, v_dec, v_prop
    FROM pgfc_govern.decision_log
    WHERE tick_id = p_tick_id AND relid = p_relid AND actuator = v_act
    ORDER BY decision_id DESC LIMIT 1;
    IF v_dec IS DISTINCT FROM 'adjust' THEN RETURN false; END IF;

    -- Authority gate (Phase 1.7 F4): the governor governs itself before PostgreSQL. The
    -- health state computed by evaluate_health() bounds the authority to act. normal =
    -- full; degraded = limited (in this single-actuator MVP, "limited" collapses to
    -- "still permitted, but one circuit-breaker step from suspension" — appendix F allows
    -- degraded authority to "may be reduced", not "must"); diagnostic/emergency/disabled
    -- suspend ordinary actuation entirely. Refusing here NEVER violates Invariant 3
    -- (never reduce freeze safety): declining to TIGHTEN leaves the prior setting and
    -- PostgreSQL's own anti-wraparound autovacuum in place — the freeze floor in plan()
    -- is what guarantees we never propose a LOOSER setting under freeze stress, and that
    -- is banked. A refusal returns false silently (like the other early-outs below) — it
    -- is deliberately NOT recorded as status='failed', which would feed the failed-action
    -- breaker and create a self-amplifying suspension loop. The state is the audit trail.
    SELECT state INTO v_state FROM pgfc_govern.governor_state;
    IF v_state IN ('diagnostic', 'emergency', 'disabled') THEN
        RETURN false;
    END IF;

    SELECT relname, reloptions INTO v_relname, v_live FROM pg_class WHERE oid = p_relid;
    IF v_relname IS NULL THEN RETURN false; END IF;                 -- relation vanished

    -- complementary to lock_timeout: don't even attempt against a busy table
    IF EXISTS (SELECT 1 FROM pg_stat_progress_vacuum WHERE relid = p_relid) THEN
        RETURN false;                                               -- retried next cycle
    END IF;

    v_cur := pgfc_observe.effective_reloption(v_live, v_act);       -- live ground truth
    IF v_cur IS NOT DISTINCT FROM v_prop THEN RETURN false; END IF; -- no-op vs live

    -- SEC-002 (#69): defense-in-depth on the value spliced into the ALTER TABLE below.
    -- v_prop is governor-computed (snap_sf()'s bounded grid output, written as
    -- decision_log.proposed_value), but decision_log is writable -- a hand-inserted or
    -- corrupted 'adjust' row could carry non-numeric or out-of-range text that format('%s')
    -- would interpolate verbatim into the DDL (a reloption injection). Parse it in a scoped
    -- sub-block so a bad cast fails closed rather than aborting the whole control_tick
    -- (WHEN others because invalid syntax and out-of-range raise different SQLSTATEs, and
    -- pg_input_is_valid() is PG16+ while we support PG15), then range-check against
    -- [sf_min, sf_max]. A bad value is refused SILENTLY, exactly like the gates above -- the
    -- decision_log row is the audit trail, and recording it 'failed' would feed the
    -- failed-action breaker. NaN/+Inf fail the upper bound and -Inf the lower (PostgreSQL
    -- sorts NaN above every real), so non-finite values are refused too. A validated v_prop
    -- is a finite numeric in-range, so the original text below is injection-safe to splice
    -- and stays byte-identical to actuator_state.current_value (the COR-001 round-trip).
    BEGIN
        v_prop_num := v_prop::double precision;
    EXCEPTION WHEN others THEN
        v_prop_num := NULL;
    END;
    IF v_prop_num IS NULL OR NOT (v_prop_num BETWEEN v_sf_min AND v_sf_max) THEN
        RETURN false;
    END IF;

    -- Invariant 4 — never exceed mutation budgets (Phase 1.7 F4). The three-tier cap from
    -- appendix F "Authority Limiting", enforced at the single actuation chokepoint. Values
    -- are read live from the active policy and fall back to the registry default (the same
    -- policy-COALESCE-registry resolution control_tick() uses for advisory_only), so an
    -- operator who tightens the budget is honored immediately. Windows/counts carry no
    -- inline numeric literals (the per-day window is sourced from the governor_metrics
    -- view, the per-cycle scope from the tick id) so apply() stays clean under the P3
    -- drift gate. An over-budget attempt is refused silently, exactly like the gate above.
    -- Read the active policy once (the same enabled row plan() used, so the two agree on
    -- manage_user_owned): the Invariant-4 budgets AND the FMEA-006 ownership flag.
    SELECT min_interval, global_max_changes_per_cycle, daily_mutation_budget, manage_user_owned
      INTO v_min_interval, v_max_cycle, v_daily_budget, v_manage
      FROM pgfc_govern.policy WHERE enabled ORDER BY policy_name LIMIT 1;
    v_min_interval := COALESCE(v_min_interval, pgfc_govern._param('min_interval')::interval);
    v_max_cycle    := COALESCE(v_max_cycle, pgfc_govern._param('global_max_changes_per_cycle')::integer);
    v_daily_budget := COALESCE(v_daily_budget, pgfc_govern._param('daily_mutation_budget')::integer);
    v_manage       := COALESCE(v_manage, pgfc_govern._param('manage_user_owned')::boolean);

    -- FMEA-006 (#83): re-check ownership at the ACTUATION point, against the LIVE value.
    -- COR-001's guard runs in plan(), against a snapshot a cycle earlier; the no-op gate above
    -- only catches a human value that exactly equals the proposal. A human ALTER landing
    -- between plan() and here, to a value that DIFFERS from the proposal, would otherwise be
    -- overwritten this cycle. Mirror COR-001's sf_user_set predicate on the live reloption: the
    -- governor "owns" the live value only when it has a baseline row, INTRODUCED the option
    -- (baseline_explicit = false), and the live value still equals what it last set
    -- (current_value). Any other explicit live value is user-owned; unless manage_user_owned,
    -- refuse SILENTLY (the decision_log row and the live catalog are the audit trail —
    -- recording 'failed' would feed the breaker). This read also serves the baseline capture
    -- below (NEVER overwrite the baseline — preserved by the NOT v_have_state branch there).
    SELECT baseline_explicit, baseline_value, current_value
      INTO v_base_explicit, v_base_value, v_gov_value
      FROM pgfc_govern.actuator_state WHERE relid = p_relid AND actuator = v_act;
    v_have_state := FOUND;
    IF NOT v_manage
       AND v_cur IS NOT NULL
       AND NOT (v_have_state AND NOT v_base_explicit
                AND v_cur IS NOT DISTINCT FROM v_gov_value) THEN
        RETURN false;
    END IF;

    -- per-relation rate limit: one mutation per relation per min_interval
    IF EXISTS (SELECT 1 FROM pgfc_govern.action_history
                WHERE relid = p_relid AND status = 'applied'
                  AND applied_at > now() - v_min_interval) THEN
        RETURN false;
    END IF;
    -- per-cycle cluster cap: bound the blast radius of any one control cycle
    IF (SELECT count(*) FROM pgfc_govern.action_history ah
          JOIN pgfc_govern.decision_log dl ON dl.decision_id = ah.decision_id
         WHERE dl.tick_id = p_tick_id AND ah.status = 'applied') >= v_max_cycle THEN
        RETURN false;
    END IF;
    -- per-day cluster cap: bound sustained mutation pressure on the catalog
    IF (SELECT applied_actions_last_day FROM pgfc_govern.governor_metrics) >= v_daily_budget THEN
        RETURN false;
    END IF;

    -- baseline: capture pre-governor state on first touch, never overwrite. The
    -- actuator_state row was already read for the FMEA-006 ownership gate above (into
    -- v_base_explicit / v_base_value / v_have_state); first touch (no row) derives the
    -- baseline from the live value, exactly as before.
    IF NOT v_have_state THEN
        v_base_explicit := (v_cur IS NOT NULL);
        v_base_value    := v_cur;
    END IF;

    v_batch := nextval('pgfc_govern.batch_seq');

    BEGIN
        -- never wait; lock_timeout single-sourced from the registry (LOCAL = this txn).
        -- SET LOCAL takes only a literal, so set_config(..., true) is the dynamic form.
        PERFORM set_config('lock_timeout', pgfc_govern._param('lock_timeout') || 'ms', true);
        EXECUTE format('ALTER TABLE %s SET (%I = %s)', p_relid::regclass, v_act, v_prop);
    EXCEPTION
        WHEN lock_not_available THEN
            INSERT INTO pgfc_govern.action_history
              (batch_id, decision_id, relid, relname, actuator, old_value, new_value,
               prev_reloptions, status, failure_reason, failure_class, lock_wait_outcome, budget_consumed)
            VALUES (v_batch, v_decid, p_relid, v_relname, v_act, v_cur, v_prop,
                    v_live, 'failed', 'lock_timeout', pgfc_govern._failure_class('lock_timeout'),
                    'timeout', false);
            RETURN false;
        WHEN insufficient_privilege THEN
            INSERT INTO pgfc_govern.action_history
              (batch_id, decision_id, relid, relname, actuator, old_value, new_value,
               prev_reloptions, status, failure_reason, failure_class, budget_consumed)
            VALUES (v_batch, v_decid, p_relid, v_relname, v_act, v_cur, v_prop,
                    v_live, 'failed', 'insufficient_privilege',
                    pgfc_govern._failure_class('insufficient_privilege'), false);
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
  'Actuate one relation''s approved scale-factor change. Gated by advisory_only (the dry-run switch), then by the Phase 1.7 F4 self-protection layer: the governor health-state authority gate (refuses when diagnostic/emergency/disabled) and the three-tier Invariant-4 mutation budget (per-relation min_interval, per-cycle and per-day cluster caps). A refused attempt returns false silently — never recorded as a failed action. [subsystem:G1]';

-- ─────────────────────────────────────────────────────────────────────────────
-- verify(): close the loop on past actions. Phase 1 has nothing applied to verify;
-- expanded in Phase 2 to attribute realized outcomes against predictions.
-- ─────────────────────────────────────────────────────────────────────────────
CREATE OR REPLACE FUNCTION pgfc_govern.verify(p_tick_id bigint)
RETURNS integer LANGUAGE sql AS $fn$
    SELECT 0;   -- Phase 2: attribute outcomes of earlier applied actions
$fn$;
COMMENT ON FUNCTION pgfc_govern.verify(bigint) IS
  'Close the control loop on past actions (Phase 1: no-op; expanded in Phase 2). [subsystem:G1]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Orchestrators (driven by pg_cron in production; see README)
-- ─────────────────────────────────────────────────────────────────────────────

-- Fast loop (~1 min): observe + classify + estimate. Never actuates.
CREATE OR REPLACE FUNCTION pgfc_govern.observe_tick()
RETURNS bigint LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE v_snap bigint;
BEGIN
    -- FMEA-002: idle on a read-only standby (resumes on promotion). First statement, before any
    -- write. observe() guards too, but classify/estimate/evaluate_health write govern tables.
    IF pgfc_observe._is_standby() THEN RETURN NULL; END IF;

    v_snap := pgfc_observe.observe();
    PERFORM pgfc_govern.classify(v_snap);
    PERFORM pgfc_govern.estimate(v_snap);
    -- Mutual watchdog (FMEA-003): refresh the health state from the INDEPENDENT fast loop, so a
    -- wedged control_tick() — which cannot evaluate its own health, since evaluate_health() runs
    -- inside it — is still detected via control_loop_lag. Best-effort and isolated in a
    -- subtransaction: observation is the foundation and must never be lost to a health-eval
    -- hiccup (it simply re-evaluates next tick). The one wedge cause this cannot catch is a
    -- broken evaluate_health() itself — then both loops' evaluators throw and governor_state
    -- freezes; pg_cron's cron.job_run_details is the external backstop for that.
    BEGIN
        PERFORM pgfc_govern.evaluate_health();
    EXCEPTION WHEN others THEN
        NULL;   -- protect the snapshot; the next observe tick re-evaluates
    END;
    RETURN v_snap;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.observe_tick() IS
  'Fast loop (~1 min): observe + classify + estimate, then refresh the governor health state (the mutual-watchdog half of FMEA-003 — the independent loop catches a wedged control_tick() via control_loop_lag). Never actuates. Returns the new snapshot id. [subsystem:G1]';

-- Control loop (~5 min): plan + (apply, only if not advisory_only) + verify.
CREATE OR REPLACE FUNCTION pgfc_govern.control_tick()
RETURNS bigint LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE
    v_tick bigint; v_snap bigint; v_adv boolean; v_applied integer := 0; r record;
BEGIN
    -- FMEA-002: idle on a read-only standby (resumes on promotion). First statement, before even
    -- the advisory lock — a standby must not write tick_log / governor_state. After a failover the
    -- demoted primary idles here while the promoted node's loops take over.
    IF pgfc_observe._is_standby() THEN RETURN NULL; END IF;

    PERFORM pg_advisory_xact_lock(hashtext('pgfc_govern.control_tick'));  -- no overlap

    -- Govern itself before it governs PostgreSQL: refresh the health state from the
    -- self-monitoring substrate FIRST (Phase 1.7 F2), so the state apply() consults this
    -- cycle reflects the latest self-monitoring signals. As of F4 this is load-bearing,
    -- not advisory: the state computed here is what the apply() authority gate enforces.
    PERFORM pgfc_govern.evaluate_health();

    SELECT advisory_only INTO v_adv FROM pgfc_govern.policy
      WHERE enabled ORDER BY policy_name LIMIT 1;
    v_adv := COALESCE(v_adv, pgfc_govern._param('advisory_only')::boolean);

    -- Loop-ordering contract (Phase 1.7 F7). plan() joins the latest per-relation estimate
    -- against current_relation_state(v_snap); now that actuation depends on the result, the
    -- two must describe the SAME snapshot. The advisory lock serializes control_tick() against
    -- itself but not against observe_tick(), so planning against the newest *observed*
    -- snapshot could, on independent cron schedules, actuate fresh observations against the
    -- prior cycle's hidden state. Plan instead against the newest snapshot whose estimate
    -- phase has completed — estimate() stamps relation_estimate.snapshot_id, so max() here is
    -- exactly the latest fully-estimated snapshot. NULL (no estimate yet) plans nothing — safe.
    SELECT max(snapshot_id) INTO v_snap FROM pgfc_govern.relation_estimate;
    INSERT INTO pgfc_govern.tick_log (snapshot_id) VALUES (v_snap) RETURNING tick_id INTO v_tick;

    PERFORM pgfc_govern.plan(v_tick, v_snap);

    IF NOT v_adv THEN
        -- Per-relation error isolation (FMEA-005, #82). apply() catches only
        -- lock_not_available / insufficient_privilege; ANY other uncaught error (a corrupted
        -- lock_timeout making set_config throw, a future actuator's DDL error) would otherwise
        -- abort this whole single-transaction cycle — rolling back EVERY relation's change,
        -- deterministically every cycle and (FMEA-003) invisibly. Atomicity is the right
        -- default for a multi-actuator batch, but the per-relation loop must not let one poison
        -- relation deny actuation to all. Select the columns the failure record needs up front
        -- (apply()'s own computation is discarded on rollback), then wrap each apply() in its
        -- own subtransaction.
        FOR r IN SELECT relid, decision_id, actuator, proposed_value
                   FROM pgfc_govern.decision_log
                  WHERE tick_id = v_tick AND decision = 'adjust'
        LOOP
            BEGIN
                IF pgfc_govern.apply(v_tick, r.relid) THEN v_applied := v_applied + 1; END IF;
            EXCEPTION WHEN others THEN
                -- The BEGIN block's implicit savepoint has rolled back, undoing the entire
                -- apply() attempt for THIS relation — including a half-completed one whose inner
                -- ALTER block already released its own savepoint (so only a savepoint taken
                -- before the apply() call can unwind the ALTER). We are now back in control_tick's
                -- transaction with NO savepoint beneath us, so this recording INSERT must never
                -- itself throw — every value it references is non-throwing: batch_seq nextval,
                -- the loop row's own decision_log columns (decision_id satisfies the FK, written
                -- by plan() earlier in this txn and not rolled back), a relname lookup that yields
                -- NULL if the relation vanished, and a COALESCE-guarded NOT NULL new_value.
                -- failure_class is stamped 'actuation' DIRECTLY rather than via _failure_class:
                -- the category is structural — the error arose in the actuation loop — not
                -- derivable from open-ended error text (SQLSTATE/SQLERRM, recorded as the reason
                -- so the failure is visible, not the silent denial of FMEA-003). So it surfaces in
                -- failure_taxonomy's actuation row and feeds the failed-action breaker exactly
                -- like a lock_timeout: a genuine, repeating actuation failure SHOULD trip it —
                -- visibly, and self-limiting (the breaker's diagnostic state short-circuits
                -- apply()'s authority gate before this error path, so it cannot self-amplify).
                INSERT INTO pgfc_govern.action_history
                  (batch_id, decision_id, relid, relname, actuator, new_value,
                   status, failure_reason, failure_class, budget_consumed)
                VALUES (nextval('pgfc_govern.batch_seq'), r.decision_id, r.relid,
                        (SELECT relname FROM pg_class WHERE oid = r.relid),
                        r.actuator, COALESCE(r.proposed_value, '(unknown)'),
                        'failed', SQLSTATE || ': ' || SQLERRM, 'actuation', false);
            END;
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
  'One control cycle: plan, apply (only if not advisory_only), verify. [subsystem:G1]';

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
           pgfc_govern._class_target(rc.kind::text)
           / pgfc_govern._effective_aggressiveness(p.aggressiveness),   -- FMEA-008: never /0
           pgfc_govern._param('sf_min')::double precision),
           pgfc_govern._param('sf_max')::double precision)    AS target_dead_fraction,
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
COMMENT ON VIEW pgfc_govern.governor_status IS
  'Per-relation operator view: workload class, target vs observed dead fraction, debt/saturation, last decision, and current scale factor. [subsystem:G7]';

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
COMMENT ON VIEW pgfc_govern.catalog_health IS
  'Catalog-mutation health: the governor''s own DDL footprint (applied/failed counts over 1h/1d) plus the latest snapshot''s live pg_class state. [subsystem:G7]';

-- Unresolved maintenance-inhibitor / saturation findings, critical first.
CREATE OR REPLACE VIEW pgfc_govern.active_diagnostics AS
SELECT diagnostic_id, detected_at, severity, relid, inhibitor_class, recommendation, evidence
FROM pgfc_govern.diagnostics
WHERE resolved_at IS NULL
ORDER BY (severity = 'critical') DESC, detected_at DESC;
COMMENT ON VIEW pgfc_govern.active_diagnostics IS
  'Unresolved maintenance-inhibitor / saturation findings, critical first. [subsystem:G5]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Retention  (Phase 1.5 S1)
-- ─────────────────────────────────────────────────────────────────────────────

-- Prune the append-only audit tables by time cutoff. These tables are low-volume
-- (≤ ~1 action/relation/hour, one tick/cycle), so a simple DELETE cutoff is adequate
-- here; the high-volume observe tables use partition rotation instead (later S2+).
-- policy_history is NOT pruned — it is retained indefinitely (pruned last).
--
-- Ordering respects the action_history -> decision_log FK: actions prune first, and a
-- decision is kept while any retained action still references it (so a retained action
-- never loses its decision). Diagnostics prune only when resolved — an old UNRESOLVED
-- finding is a live alert (surfaced by active_diagnostics) and must not age out.
--
-- Schedule daily with pg_cron, e.g.:
--   SELECT cron.schedule('pgfc_govern_retain', '17 3 * * *',
--                        $$ SELECT pgfc_govern.retain() $$);
-- Drop the prior 4-arg signature so the added keep_transitions arg REPLACES rather than
-- overloads (two all-defaulted overloads would make retain() ambiguous). Idempotent.
DROP FUNCTION IF EXISTS pgfc_govern.retain(interval, interval, interval, interval);
CREATE OR REPLACE FUNCTION pgfc_govern.retain(
    keep_decisions   interval DEFAULT '180 days',
    keep_actions     interval DEFAULT '180 days',
    keep_ticks       interval DEFAULT '180 days',
    keep_diagnostics interval DEFAULT '365 days',
    keep_transitions interval DEFAULT '180 days')
RETURNS TABLE(relation text, deleted bigint)
LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
BEGIN
    -- FMEA-002 (daily-job follow-up): idle on a read-only standby — these are all DELETEs, so a
    -- nightly prune on a replica would error; no-op (return no rows) instead, resuming on promotion.
    IF pgfc_observe._is_standby() THEN RETURN; END IF;

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

    -- 5. Health-state transition audit (Phase 1.7 F2) — pure audit, prune by cutoff.
    RETURN QUERY
    WITH d AS (DELETE FROM pgfc_govern.state_transitions
               WHERE transitioned_at < now() - keep_transitions RETURNING 1)
    SELECT 'state_transitions'::text, count(*) FROM d;
END;
$fn$;
COMMENT ON FUNCTION pgfc_govern.retain(interval, interval, interval, interval, interval) IS
  'Prune audit tables by time cutoff (decisions/actions 180d, ticks 180d, resolved diagnostics 365d, state transitions 180d); policy_history is never pruned. Returns per-table delete counts. [subsystem:G6]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Storage budget + self-health + graceful degrade  (Phase 1.5 S6)
-- ─────────────────────────────────────────────────────────────────────────────
-- The full governor (observe + govern) must bound its own worst-case storage. These
-- surfaces are cross-schema and therefore live HERE, in the dependent layer: govern
-- already reads pgfc_observe (see catalog_health), but pgfc_observe must never depend
-- on pgfc_govern (it ships standalone as a monitoring tool). An observe-only install
-- uses pgfc_observe.storage_budget()/self_health and the pgfc_observe prune primitives
-- directly; this block adds the whole-system view on top.

-- Operator-set total-bytes cap over BOTH schemas. NULL (default) = no cap configured,
-- so degrade() is a no-op until an operator opts in — the governor never silently
-- destroys telemetry. Enforced singleton (constant-true PK), mirroring
-- pgfc_observe.collection_policy.
CREATE TABLE IF NOT EXISTS pgfc_govern.storage_config (
    singleton    boolean PRIMARY KEY DEFAULT true CHECK (singleton),
    budget_bytes bigint CHECK (budget_bytes IS NULL OR budget_bytes >= 0)
);
COMMENT ON TABLE pgfc_govern.storage_config IS
  'Single-row storage config (S6): budget_bytes is the total-bytes cap over both schemas that degrade() enforces. NULL = no cap (degrade is a no-op). [subsystem:G6]';
COMMENT ON COLUMN pgfc_govern.storage_config.budget_bytes IS
  'Total on-disk cap across pgfc_observe + pgfc_govern. NULL disables degrade().';

INSERT INTO pgfc_govern.storage_config (singleton) VALUES (true)
ON CONFLICT (singleton) DO NOTHING;

-- Whole-governor storage report: pgfc_observe's per-relation budget (child partitions
-- folded into parents) plus pgfc_govern's own tables, each tagged with its schema.
CREATE OR REPLACE FUNCTION pgfc_govern.storage_budget()
RETURNS TABLE(schema_name text, relation text, bytes bigint, dead_tuples bigint)
LANGUAGE sql STABLE AS $fn$
    SELECT 'pgfc_observe'::text, ob.relation, ob.bytes, ob.dead_tuples
    FROM pgfc_observe.storage_budget() ob
    UNION ALL
    SELECT 'pgfc_govern'::text, top.relname::text,
           COALESCE(sum(pg_total_relation_size(m.relid)), 0)::bigint,
           COALESCE(sum(st.n_dead_tup), 0)::bigint
    FROM pg_class top
    JOIN pg_namespace n ON n.oid = top.relnamespace
    CROSS JOIN LATERAL (
        SELECT top.oid AS relid
        UNION
        SELECT pt.relid FROM pg_partition_tree(top.oid) pt WHERE pt.relid <> top.oid
    ) m
    LEFT JOIN pg_stat_all_tables st ON st.relid = m.relid
    WHERE n.nspname = 'pgfc_govern'
      AND top.relkind IN ('r', 'p')
      AND NOT top.relispartition
    GROUP BY top.relname
    ORDER BY 1, 2;
$fn$;
COMMENT ON FUNCTION pgfc_govern.storage_budget() IS
  'Whole-governor storage report (S6): per-relation bytes + dead tuples across pgfc_observe and pgfc_govern, tagged by schema. [subsystem:G6]';

-- One-row whole-governor self-health: footprint vs configured budget. over_budget is
-- the signal an operator (or a scheduled job) acts on by calling degrade().
CREATE OR REPLACE VIEW pgfc_govern.self_health AS
WITH b AS (
    SELECT COALESCE(sum(bytes), 0)       AS total_bytes,
           COALESCE(sum(dead_tuples), 0) AS total_dead_tuples
    FROM pgfc_govern.storage_budget()
), c AS (
    SELECT budget_bytes FROM pgfc_govern.storage_config
)
SELECT b.total_bytes, b.total_dead_tuples, c.budget_bytes,
       (c.budget_bytes - b.total_bytes)                                   AS bytes_under_budget,
       (c.budget_bytes IS NOT NULL AND b.total_bytes > c.budget_bytes)    AS over_budget
FROM b CROSS JOIN c;
COMMENT ON VIEW pgfc_govern.self_health IS
  'One-row whole-governor self-health (S6): total bytes + dead tuples across both schemas vs the configured budget; over_budget flags when degrade() should run. [subsystem:G6]';

-- Graceful-degrade prune order. When the governor's own footprint exceeds the budget,
-- shed storage in a FIXED order from most to least disposable —
--   raw → fine rollups → coarse rollups → routine diagnostics → actions → policy(never)
-- — stopping as soon as the footprint is back under budget. The growable levels (rollups,
-- audit) reuse their prune primitive with a tighter-than-routine window (pressure relief,
-- not the daily job). RAW is special since FMEA-001: it is a FIXED TRUNCATE-rotated ring,
-- bounded by construction (2 × _ring_slots() partitions, (_ring_slots()-1) days), so it can
-- no longer be shed below that floor — this step just force-sweeps any out-of-window slot
-- observe() has not yet recycled (rotate_ring()). One consequence: a budget set BELOW the raw
-- ring floor is unsatisfiable (degrade sheds everything else and stays over) — set the budget
-- above the fixed raw footprint. Levels reached while already under budget are recorded as
-- skipped, so the order is always auditable; policy_history is NEVER pruned (it is the
-- human-owned record of intent) and is reported last as 'preserved'.
--
-- pgfc_observe has no separate "derived state" table to prune (S3's relation_last_state
-- is a reconstructable cache, not durable history), so that documented tier is absent
-- here; the order is otherwise exactly as specified.
--
-- Drop the prior 6-arg signature so removing keep_raw (the ring window is fixed, not a
-- per-call interval) REPLACES rather than overloads it (two all-defaulted overloads would
-- make degrade() ambiguous). Idempotent.
DROP FUNCTION IF EXISTS pgfc_govern.degrade(bigint, interval, interval, interval, interval, interval);
CREATE OR REPLACE FUNCTION pgfc_govern.degrade(
    p_budget_bytes     bigint   DEFAULT NULL,   -- NULL => read storage_config
    keep_rollup_fine   interval DEFAULT '2 days',
    keep_rollup_coarse interval DEFAULT '30 days',
    keep_diagnostics   interval DEFAULT '30 days',
    keep_actions       interval DEFAULT '30 days')
RETURNS TABLE(step integer, level text, action text, bytes_after bigint)
LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE
    v_budget bigint := COALESCE(p_budget_bytes,
                                (SELECT budget_bytes FROM pgfc_govern.storage_config));
    v_total  bigint;
    v_step   integer := 0;
    v_far    interval := '1000 years';   -- "do not touch this tier" sentinel window
BEGIN
    -- FMEA-002 (daily-job follow-up): idle on a read-only standby — degrade() prunes (writes), so
    -- on a replica it would error once over budget; no-op (return no rows), resume on promotion.
    IF pgfc_observe._is_standby() THEN RETURN; END IF;

    -- No cap configured: nothing to enforce. Return no rows (a clean no-op).
    IF v_budget IS NULL THEN
        RETURN;
    END IF;

    SELECT COALESCE(sum(bytes), 0) INTO v_total FROM pgfc_govern.storage_budget();

    -- 1. Raw observations. Bounded by the fixed ring (FMEA-001): force-sweep any out-of-window
    --    slot observe() has not yet recycled — there is no in-window raw to shed (the ring
    --    floor is (_ring_slots()-1) days), so 'swept' reports the sweep ran, not deep relief.
    v_step := v_step + 1;
    IF v_total > v_budget THEN
        PERFORM pgfc_observe.rotate_ring();
        SELECT COALESCE(sum(bytes), 0) INTO v_total FROM pgfc_govern.storage_budget();
        RETURN QUERY SELECT v_step, 'raw'::text, 'swept'::text, v_total;
    ELSE
        RETURN QUERY SELECT v_step, 'raw'::text, 'skipped:under_budget'::text, v_total;
    END IF;

    -- 2. Fine (1m) rollups.
    v_step := v_step + 1;
    IF v_total > v_budget THEN
        PERFORM pgfc_observe.rollup_retain(keep_rollup_fine, v_far, v_far);
        SELECT COALESCE(sum(bytes), 0) INTO v_total FROM pgfc_govern.storage_budget();
        RETURN QUERY SELECT v_step, 'rollups_fine'::text, 'pruned'::text, v_total;
    ELSE
        RETURN QUERY SELECT v_step, 'rollups_fine'::text, 'skipped:under_budget'::text, v_total;
    END IF;

    -- 3. Coarse (1h/1d) rollups.
    v_step := v_step + 1;
    IF v_total > v_budget THEN
        PERFORM pgfc_observe.rollup_retain(v_far, keep_rollup_coarse, keep_rollup_coarse);
        SELECT COALESCE(sum(bytes), 0) INTO v_total FROM pgfc_govern.storage_budget();
        RETURN QUERY SELECT v_step, 'rollups_coarse'::text, 'pruned'::text, v_total;
    ELSE
        RETURN QUERY SELECT v_step, 'rollups_coarse'::text, 'skipped:under_budget'::text, v_total;
    END IF;

    -- 4. Routine (resolved) diagnostics.
    v_step := v_step + 1;
    IF v_total > v_budget THEN
        PERFORM pgfc_govern.retain(v_far, v_far, v_far, keep_diagnostics);
        SELECT COALESCE(sum(bytes), 0) INTO v_total FROM pgfc_govern.storage_budget();
        RETURN QUERY SELECT v_step, 'diagnostics'::text, 'pruned'::text, v_total;
    ELSE
        RETURN QUERY SELECT v_step, 'diagnostics'::text, 'skipped:under_budget'::text, v_total;
    END IF;

    -- 5. Decisions / actions / ticks.
    v_step := v_step + 1;
    IF v_total > v_budget THEN
        PERFORM pgfc_govern.retain(keep_actions, keep_actions, keep_actions, v_far);
        SELECT COALESCE(sum(bytes), 0) INTO v_total FROM pgfc_govern.storage_budget();
        RETURN QUERY SELECT v_step, 'actions'::text, 'pruned'::text, v_total;
    ELSE
        RETURN QUERY SELECT v_step, 'actions'::text, 'skipped:under_budget'::text, v_total;
    END IF;

    -- 6. Policy / policy_history — the human-owned record of intent. NEVER pruned.
    v_step := v_step + 1;
    RETURN QUERY SELECT v_step, 'policy'::text, 'preserved'::text, v_total;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.degrade(bigint, interval, interval, interval, interval) IS
  'Graceful-degrade prune order (S6): shed storage raw (force-sweep the fixed ring, FMEA-001) → fine → coarse rollups → diagnostics → actions until under budget; policy is never pruned. No-op when no budget is configured; a budget below the fixed raw-ring floor is unsatisfiable. Returns the ordered prune log. [subsystem:G6]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Parameter registry  (Phase 1.6 — parameter governance, P1)
-- ─────────────────────────────────────────────────────────────────────────────
-- Canonical registry of pgfc_govern's governed constants — the control-logic values the
-- governor steers with — and the single source the code now READS from: classify(),
-- estimate(), plan(), snap_sf(), _findings(), governor_status, and apply() take their
-- constants via the _param()/_sf_grid()/_class_target() accessors above, not inline
-- literals (P2). What
-- is NOT yet true: the tie is not enforced — nothing structurally prevents a future inline
-- literal from diverging from this registry. The "registry up to date" CI gate that makes
-- divergence impossible lands in P3.
-- category ∈ {postgresql_derived, safety_bound, empirical_default, operator_policy,
-- adaptive_value, implementation_convenience}; override_allowed is orthogonal to category.
CREATE OR REPLACE FUNCTION pgfc_govern._parameter_registry()
RETURNS TABLE(
    parameter_name   text,
    category         text,
    default_value    text,
    unit             text,
    rationale        text,
    source           text,
    owner            text,
    override_allowed boolean,
    config_ref       text)
LANGUAGE sql IMMUTABLE AS $fn$
VALUES
  -- Safety bounds
  ('sf_min', 'safety_bound', '0.01', 'fraction',
   'Floor of the scale-factor actuator range; the governor never sets a table cleaner than this.',
   'safety analysis', 'maintainer', false, NULL),
  ('sf_max', 'safety_bound', '0.50', 'fraction',
   'Ceiling of the scale-factor actuator range.',
   'safety analysis', 'maintainer', false, NULL),
  ('freeze_thr', 'safety_bound', '0.6', 'fraction of wraparound limit',
   'Freeze debt at/above this fraction forces the cleanest scale factor (freeze floor), overriding saturation suppression.',
   'safety analysis', 'maintainer', false, NULL),
  ('lock_timeout', 'safety_bound', '100', 'ms',
   'apply() SET LOCAL lock_timeout: never block on actuation — fail fast and retry.',
   'safety analysis', 'maintainer', false, NULL),
  ('daily_mutation_budget', 'safety_bound', '500', 'changes/day',
   'Cluster-wide cap on applied catalog mutations per day (also operator policy).',
   'design review', 'operator', true, 'policy.daily_mutation_budget'),
  ('global_max_changes_per_cycle', 'safety_bound', '50', 'changes/cycle',
   'Cluster-wide cap on applied changes per control cycle (also operator policy).',
   'design review', 'operator', true, 'policy.global_max_changes_per_cycle'),
  ('min_interval', 'safety_bound', '1 hour', 'interval',
   'Per-relation minimum interval between catalog mutations (also operator policy).',
   'design review', 'operator', true, 'policy.min_interval'),
  -- Empirical defaults (estimation + classification + control grid)
  ('observe_cadence', 'empirical_default', '1', 'minutes',
   'How often observe_tick() runs.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'pg_cron schedule'),
  ('control_cadence', 'empirical_default', '5', 'minutes',
   'How often control_tick() runs.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'pg_cron schedule'),
  ('ewma_tau', 'empirical_default', '3600', 'seconds',
   'Time constant of the rate EWMA in estimate().',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('ewma_effa', 'empirical_default', '0.5', 'weight',
   'EWMA weight for cleanup effectiveness / peak in estimate().',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('saturation_persistence_k', 'empirical_default', '3', 'cycles',
   'Cycles a saturation cause must persist before estimate() commits it (hysteresis on the saturation state machine).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('class_persistence_n_sustain', 'empirical_default', '3', 'cycles',
   'Cycles a candidate class must persist before classify() commits it (hysteresis on the classification state machine; distinct from saturation_persistence_k).',
   'MVP estimate — not yet benchmarked', 'operator', true, 'policy.n_sustain'),
  ('classify_floor', 'empirical_default', '50', 'writes',
   'Minimum recent writes before a relation is classified on its write-mix fractions.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('classify_large', 'empirical_default', '100000', 'rows',
   'reltuples above which a new, idle relation defaults to ''archive''.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('classify_append_only_ins_frac', 'empirical_default', '0.95', 'fraction',
   'Insert fraction above which a relation is append_only.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('classify_delete_frac', 'empirical_default', '0.30', 'fraction',
   'Delete fraction above which a relation is queue or delete_heavy (and update fraction for oltp).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('classify_queue_balance_frac', 'empirical_default', '0.10', 'fraction',
   'Max |ins−del| fraction for a delete-heavy relation to count as a balanced queue.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('classify_append_only_del_frac', 'empirical_default', '0.01', 'fraction',
   'Delete fraction below which (with high inserts) a relation is append_only.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('eff_low', 'empirical_default', '0.5', 'fraction',
   'Cleanup-effectiveness below which a vacuum that ran is treated as ineffective (saturation discriminator).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('av_running_window', 'empirical_default', '1 hour', 'interval',
   'How recently autovacuum must have run for a relation to count as "autovacuum is running" (the config vs io_limited saturation discriminator).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('target_queue', 'empirical_default', '0.05', 'fraction',
   'Target dead-tuple fraction for the queue class (before aggressiveness scaling).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('target_delete_heavy', 'empirical_default', '0.10', 'fraction',
   'Target dead-tuple fraction for the delete_heavy class.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('target_oltp', 'empirical_default', '0.20', 'fraction',
   'Target dead-tuple fraction for the oltp class.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('target_mixed', 'empirical_default', '0.20', 'fraction',
   'Target dead-tuple fraction for the mixed class.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('target_append_only', 'empirical_default', '0.40', 'fraction',
   'Target dead-tuple fraction for the append_only class.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('target_archive', 'empirical_default', '0.50', 'fraction',
   'Target dead-tuple fraction for the archive class.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('sf_grid', 'empirical_default', '{0.01,0.02,0.05,0.10,0.20,0.30,0.50}', 'fraction set',
   'Quantization grid the scale-factor target snaps to (snap_sf); the spacing is the anti-oscillation deadband.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  -- Operator policy
  ('aggressiveness', 'operator_policy', '1.0', 'multiplier',
   'Scales every class target: >1 cleaner, <1 more bloat tolerated.',
   'operator default', 'operator', true, 'policy.aggressiveness'),
  ('freeze_posture', 'operator_policy', 'standard', 'enum',
   'Freeze-safety posture: standard | conservative.',
   'operator default', 'operator', true, 'policy.freeze_posture'),
  ('manage_user_owned', 'operator_policy', 'false', 'boolean',
   'Whether the governor may overwrite a reloption a user/other system set first.',
   'operator default', 'operator', true, 'policy.manage_user_owned'),
  ('advisory_only', 'operator_policy', 'true', 'boolean',
   'Dry-run gate: when true, plan() decides but apply() never fires.',
   'operator default', 'operator', true, 'policy.advisory_only'),
  ('storage_budget_bytes', 'operator_policy', 'NULL', 'bytes',
   'Total on-disk cap across both schemas that degrade() enforces; NULL disables it.',
   'operator default', 'operator', true, 'storage_config.budget_bytes'),
  ('keep_decisions_days', 'operator_policy', '180', 'days',
   'Default retention for decision_log.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'retain() argument'),
  ('keep_actions_days', 'operator_policy', '180', 'days',
   'Default retention for action_history.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'retain() argument'),
  ('keep_ticks_days', 'operator_policy', '180', 'days',
   'Default retention for tick_log.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'retain() argument'),
  ('keep_diagnostics_days', 'operator_policy', '365', 'days',
   'Default retention for resolved diagnostics.',
   'MVP estimate — not yet benchmarked', 'operator', true, 'retain() argument'),
  ('keep_transitions_days', 'operator_policy', '180', 'days',
   'Default retention for the health-state transition audit (Phase 1.7 F2).',
   'MVP estimate — not yet benchmarked', 'operator', true, 'retain() argument'),
  -- Governor health-state thresholds (Phase 1.7 F2 — self-protection). The transition
  -- bounds the evaluator compares the governor_metrics substrate against; born governed
  -- so the state machine has no inline magic numbers (the payoff of sequencing 1.6 first).
  ('health_lag_degraded_secs', 'empirical_default', '600', 'seconds',
   'Observation lag (newest snapshot age) above which the governor is degraded — telemetry is going stale.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('health_lag_emergency_secs', 'empirical_default', '3600', 'seconds',
   'Observation lag above which the governor is in emergency — it is effectively flying blind.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('health_control_lag_degraded_secs', 'empirical_default', '1200', 'seconds',
   'Control-loop lag (age of the last successfully-completed control_tick) above which the governor is degraded — the control loop is stalling. Must exceed the control cadence with margin so a normal between-cycle gap never trips it (the FMEA-003 heartbeat).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('health_control_lag_emergency_secs', 'empirical_default', '3600', 'seconds',
   'Control-loop lag above which the governor is in emergency — control_tick has stopped completing cycles and actuation has silently ceased (the FMEA-003 heartbeat).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('health_failed_degraded', 'empirical_default', '3', 'failed actions/hour',
   'Failed actuation attempts in the last hour above which the governor is degraded.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('health_failed_diagnostic', 'empirical_default', '10', 'failed actions/hour',
   'Failed actuation attempts in the last hour above which the governor enters diagnostic.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('health_lock_timeouts_diagnostic', 'empirical_default', '10', 'lock timeouts/hour',
   'Lock-timeout failures in the last hour above which the governor enters diagnostic (cannot acquire locks to act).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  -- Control-oscillation detection (Phase 1.7 F5 — self-protection). Flapping (the controller
  -- fighting itself) is a safety failure: it trips diagnostic, suspending actuation.
  ('oscillation_window', 'empirical_default', '1 day', 'interval',
   'Window over which applied scale-factor changes are examined for flapping; also the cooldown after which a stopped oscillation ages out and the governor auto-recovers. Must exceed min_interval (which spaces the changes) by enough cycles to observe a flap.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  ('oscillation_min_reversals', 'empirical_default', '2', 'reversals',
   'Direction reversals in a relation''s applied scale-factor sequence within oscillation_window at or above which the governor treats it as oscillating (a full A->B->A->B flap is 2 reversals).',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  -- Load shedding (Phase 1.7 F6 — self-protection). When the database is under connection
  -- pressure, the governor sheds its own load by suspending actuation (the pg_flight_recorder
  -- load_shedding_active_pct pattern, adapted from collector-sampling to actuation authority):
  -- it consumes fewer resources, and stops competing for locks, when the database needs them
  -- most. Born governed (a stress %, like every other health-transition threshold).
  ('load_shed_connection_pct', 'empirical_default', '0.9', 'fraction',
   'Connection pressure (client_backends / max_connections, from the newest snapshot) at or above which the governor sheds load: it enters diagnostic and the F4 authority gate suspends actuation cluster-wide until the pressure eases. A fraction in (0, 1]; lower sheds sooner.',
   'MVP estimate — not yet benchmarked', 'maintainer', false, NULL),
  -- Implementation convenience
  ('govern_av_threshold', 'implementation_convenience', '200', 'rows',
   'Static autovacuum threshold on the govern audit/state tables (scale_factor 0).',
   'design review (S6)', 'maintainer', false, NULL),
  -- Adaptive value (computed by the control logic; recorded in the audit trail, not a constant)
  ('relation_scale_factor', 'adaptive_value', 'computed', 'fraction',
   'Per-relation scale-factor setpoint plan() derives from the class target, aggressiveness, and table size; not a fixed value. Operators steer it indirectly via class and aggressiveness, never directly.',
   'governor state estimation / control logic', 'governor', false, 'decision_log / action_history')
$fn$;
COMMENT ON FUNCTION pgfc_govern._parameter_registry() IS
  'Canonical registry of pgfc_govern governed constants; the control logic reads its values from here through the registry accessor functions (Phase 1.6 P2, single-sourced). The CI drift gate that makes divergence impossible lands in P3. [subsystem:G3]';

-- Operator-facing unified view: every governed parameter across BOTH schemas, tagged by
-- schema. Lives in pgfc_govern (the dependent layer) so pgfc_observe stays standalone —
-- the same layering as storage_budget()/self_health. The "inspect parameters without
-- reading source" surface (Appendix-E reviewability). Effective-value resolution against
-- live overrides arrives with the getter in a later increment; P1 exposes the canonical
-- defaults + provenance.
CREATE OR REPLACE VIEW pgfc_govern.parameter_registry AS
    SELECT 'pgfc_observe'::text AS schema_name, r.*
    FROM pgfc_observe._parameter_registry() r
    UNION ALL
    SELECT 'pgfc_govern'::text, r.*
    FROM pgfc_govern._parameter_registry() r;
COMMENT ON VIEW pgfc_govern.parameter_registry IS
  'Unified, operator-facing parameter registry (Phase 1.6 P1): every governed constant across both schemas with category and provenance. [subsystem:G3]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Drift gate  (Phase 1.6 — parameter governance, P3)
-- ─────────────────────────────────────────────────────────────────────────────
-- Makes the single-sourcing ENFORCED, not merely real: scans the BODIES of the
-- decision/actuation path and returns any numeric or interval literal that is not a
-- structural constant — i.e. an unregistered control value. A pgTAP test asserts this
-- returns zero rows, so it rides the all-versions test gate; operators can also call it
-- to audit. Bodies are pulled by function NAME from the catalog (pg_proc.prosrc /
-- pg_get_viewdef), not by line position, so the check cannot rot as the file changes.
-- Intervals/quantities are scanned as a first-class category (most control windows are
-- intervals; stripping strings would blind the gate to exactly the literal it exists to
-- catch). A quoted string that BEGINS with a digit is a quantity ('1 hour', '100ms',
-- '180 days'); prose strings ('... (Phase 3).') are not, so they don't false-positive.
-- Bare code numerics are scanned only after all string literals are removed.
--
-- SCOPE — what this enforces vs what is documented-only:
--   ENFORCED: every pgfc_govern function by default (fail-closed — see the exclusion set
--     in the query), plus governor_status's target computation. So the control path
--     (estimate, classify, plan, snap_sf, _findings, _reconcile_diagnostics,
--     _oscillating_relations, _reconcile_oscillation, apply, observe_tick, control_tick,
--     verify) and any control function added later are scanned
--     automatically; every governed value there must come through the accessors.
--   DOCUMENTED but NOT gate-enforced (excluded; may still drift from the registry — a
--     later call): retain()/degrade() (operator retention orchestration; their signature
--     DEFAULTs aren't in prosrc anyway), the policy table-column DEFAULTs, and
--     catalog_health's reporting-window intervals — operator-policy / reporting, not
--     values the governor steers with.
-- Allowlist is intentionally tiny ({0,1,0.0,1.0}); a new entry needs a one-line reason.
CREATE OR REPLACE FUNCTION pgfc_govern._audit_control_literals()
RETURNS TABLE(object_name text, literal text)
LANGUAGE sql STABLE AS $fn$
WITH bodies AS (
    SELECT p.proname::text AS object_name,
           regexp_replace(p.prosrc, '--.*', '', 'gn') AS body   -- strip line comments
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'pgfc_govern'
      AND p.prokind = 'f'
      -- FAIL-CLOSED: scan every govern function by default, so a NEW control function
      -- (Phase 2 actuators, the bloat brake, circuit breakers, …) is enforced
      -- automatically — born governed — without anyone remembering to list it. The
      -- exclusion set is small and explicit:
      AND p.proname NOT IN (
          '_parameter_registry',      -- the registry itself (its literals ARE the data)
          '_audit_control_literals',  -- this auditor (its allowlist/regex are literals)
          'degrade', 'retain',        -- operator retention orchestration (documented, not enforced)
          'storage_budget',           -- reporting
          'validate_parameters',      -- reviewability/reporting surface
          '_log_policy_change')       -- audit-trigger plumbing
    UNION ALL
    SELECT 'governor_status',
           regexp_replace(pg_get_viewdef('pgfc_govern.governor_status'::regclass),
                          '--.*', '', 'gn')
),
quoted AS (   -- quoted strings that begin with a digit = quantity/interval literals
    SELECT b.object_name, m[1] AS literal
    FROM bodies b,
         regexp_matches(b.body, '(''[0-9][^'']*'')', 'g') AS m
),
bare AS (      -- bare code numerics, after removing ALL string literals (so prose digits
               -- like "(Phase 3)" cannot false-positive)
    SELECT s.object_name, m[1] AS literal
    FROM (SELECT object_name, regexp_replace(body, '''[^'']*''', '', 'g') AS body
          FROM bodies) s,
         regexp_matches(s.body, '(\y[0-9]+\.?[0-9]*\y)', 'g') AS m
)
SELECT object_name, literal
FROM (SELECT * FROM quoted UNION ALL SELECT * FROM bare) u
WHERE literal NOT IN ('0', '1', '0.0', '1.0')   -- structural-only allowlist
ORDER BY object_name, literal;
$fn$;
COMMENT ON FUNCTION pgfc_govern._audit_control_literals() IS
  'Drift gate (Phase 1.6 P3): returns unregistered numeric/interval literals in the decision/actuation path. A pgTAP test asserts it is empty; non-empty means a control value escaped the registry. [subsystem:G3]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Parameter validation  (Phase 1.6 — parameter governance, P4)
-- ─────────────────────────────────────────────────────────────────────────────
-- The reviewability surface (Appendix E): grade the LIVE operator configuration against
-- the safety bounds the registry encodes, so a hazardous setting is visible without
-- reading source. Returns one row per checked parameter, status OK | WARNING | CRITICAL
-- (the pg_flight_recorder validate_config() pattern). Checks are structural (> 0, = 0,
-- IS NULL) — it asserts hard safety properties, not tuning opinions — so it carries no
-- magic numbers of its own; it is a reporting surface and is excluded from the P3 gate.
CREATE OR REPLACE FUNCTION pgfc_govern.validate_parameters()
RETURNS TABLE(parameter text, status text, message text)
LANGUAGE sql STABLE AS $fn$
WITH pol AS (
    SELECT * FROM pgfc_govern.policy WHERE enabled ORDER BY policy_name LIMIT 1
), cfg AS (
    SELECT budget_bytes FROM pgfc_govern.storage_config
)
-- No enabled policy at all: the governor is inert. Surfaced standalone (not FROM pol, so
-- it still reports when pol is empty) — without it, an unconfigured governor would show no
-- findings at all.
SELECT 'enabled_policy',
       CASE WHEN EXISTS (SELECT 1 FROM pgfc_govern.policy WHERE enabled) THEN 'OK' ELSE 'WARNING' END,
       CASE WHEN EXISTS (SELECT 1 FROM pgfc_govern.policy WHERE enabled)
            THEN 'an enabled policy drives the loop'
            ELSE 'no enabled policy — the governor plans and applies nothing' END
UNION ALL
-- aggressiveness scales every class target (target = template / aggressiveness), so a
-- non-positive value is a divide-by-zero / sign inversion: hard CRITICAL.
SELECT 'aggressiveness',
       CASE WHEN p.aggressiveness IS NULL OR p.aggressiveness <= 0 THEN 'CRITICAL' ELSE 'OK' END,
       format('aggressiveness = %s; must be > 0 (targets are class_template / aggressiveness, clamped to [%s, %s])',
              p.aggressiveness, pgfc_govern._param('sf_min'), pgfc_govern._param('sf_max'))
FROM pol p
UNION ALL
SELECT 'daily_mutation_budget',
       CASE WHEN p.daily_mutation_budget < 0 THEN 'CRITICAL'
            WHEN p.daily_mutation_budget = 0 THEN 'WARNING' ELSE 'OK' END,
       format('daily_mutation_budget = %s (0 means the governor can never apply a change)', p.daily_mutation_budget)
FROM pol p
UNION ALL
SELECT 'global_max_changes_per_cycle',
       CASE WHEN p.global_max_changes_per_cycle < 0 THEN 'CRITICAL'
            WHEN p.global_max_changes_per_cycle = 0 THEN 'WARNING' ELSE 'OK' END,
       format('global_max_changes_per_cycle = %s (0 means no change is ever applied per cycle)', p.global_max_changes_per_cycle)
FROM pol p
UNION ALL
SELECT 'min_interval',
       CASE WHEN extract(epoch FROM p.min_interval) < 0 THEN 'CRITICAL'
            WHEN extract(epoch FROM p.min_interval) = 0 THEN 'WARNING' ELSE 'OK' END,
       format('min_interval = %s (0 removes the per-relation rate limit)', p.min_interval)
FROM pol p
UNION ALL
SELECT 'n_sustain',
       CASE WHEN p.n_sustain < 1 THEN 'WARNING' ELSE 'OK' END,
       format('n_sustain = %s (below 1 disables classification hysteresis — risks flapping)', p.n_sustain)
FROM pol p
UNION ALL
SELECT 'manage_user_owned',
       CASE WHEN p.manage_user_owned THEN 'WARNING' ELSE 'OK' END,
       format('manage_user_owned = %s (true lets the governor overwrite user/other-system reloptions)', p.manage_user_owned)
FROM pol p
UNION ALL
SELECT 'advisory_only',
       CASE WHEN p.advisory_only THEN 'OK' ELSE 'WARNING' END,
       format('advisory_only = %s (false: the governor actively applies changes under the health-state gate; true: plans only)', p.advisory_only)
FROM pol p
UNION ALL
SELECT 'storage_budget_bytes',
       CASE WHEN c.budget_bytes IS NOT NULL AND c.budget_bytes < 0 THEN 'CRITICAL' ELSE 'OK' END,
       format('budget_bytes = %s (NULL = no storage cap, degrade() disabled)', c.budget_bytes)
FROM cfg c
ORDER BY 1;
$fn$;
COMMENT ON FUNCTION pgfc_govern.validate_parameters() IS
  'Parameter validation (Phase 1.6 P4): grades the live operator configuration against the registry''s safety bounds (OK/WARNING/CRITICAL). The reviewability surface; checks hard safety properties only. [subsystem:G3]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Additive upgrades
-- ─────────────────────────────────────────────────────────────────────────────
-- P4: adaptive-value provenance — the estimated benefit of an adjust on decision_log.
ALTER TABLE pgfc_govern.decision_log ADD COLUMN IF NOT EXISTS estimated_benefit double precision;

-- F3: operator-forced override columns on the (F2) governor_state singleton, for installs
-- that already have governor_state from F2. NULL operator_forced = fully automatic.
ALTER TABLE pgfc_govern.governor_state
    ADD COLUMN IF NOT EXISTS operator_forced pgfc_govern.governor_health_state;
ALTER TABLE pgfc_govern.governor_state ADD COLUMN IF NOT EXISTS forced_reason text;
ALTER TABLE pgfc_govern.governor_state ADD COLUMN IF NOT EXISTS forced_by     text;
ALTER TABLE pgfc_govern.governor_state ADD COLUMN IF NOT EXISTS forced_at     timestamptz;

-- F6: the failure-taxonomy class on action_history, for installs that already have the
-- table. Add the (nullable) column, then the five-category CHECK (guarded: ADD CONSTRAINT
-- has no IF NOT EXISTS), then backfill historical failed rows through _failure_class() — the
-- same single-source mapping apply() now stamps live. NULLs (applied rows, or an unknown
-- reason) pass the CHECK, so the order is safe.
ALTER TABLE pgfc_govern.action_history ADD COLUMN IF NOT EXISTS failure_class text;
DO $$ BEGIN
    ALTER TABLE pgfc_govern.action_history
        ADD CONSTRAINT action_history_failure_class_check
        CHECK (failure_class IS NULL
               OR failure_class IN ('observation','decision','actuation','resource','safety'));
EXCEPTION WHEN duplicate_object THEN NULL; END $$;
UPDATE pgfc_govern.action_history
   SET failure_class = pgfc_govern._failure_class(failure_reason)
 WHERE status = 'failed' AND failure_class IS NULL
   AND pgfc_govern._failure_class(failure_reason) IS NOT NULL;

-- S6: static autovacuum reloptions on the governor's own audit/state tables. Unlike
-- the partition-rotated observe tables, these are mutated in place (UPDATE-heavy state
-- tables; DELETE-pruned audit tables by retain()/degrade()), so they DO accrue dead
-- tuples and need predictable cleanup. scale_factor=0 makes the trigger a fixed row
-- count (static, not drifting with table size). ALTER ... SET is idempotent, so this
-- covers both fresh installs and upgrades.
DO $reloptions$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY[
        'policy', 'policy_history', 'relation_class', 'relation_estimate',
        'actuator_state', 'decision_log', 'action_history', 'tick_log',
        'diagnostics', 'storage_config'
    ] LOOP
        EXECUTE format(
            'ALTER TABLE pgfc_govern.%I SET ('
            'autovacuum_vacuum_scale_factor=0, autovacuum_vacuum_threshold=200, '
            'autovacuum_analyze_scale_factor=0, autovacuum_analyze_threshold=200)', t);
    END LOOP;
END
$reloptions$;

-- ─────────────────────────────────────────────────────────────────────────────
-- Control-oscillation detection  (Phase 1.7 F5 — governor self-protection)
-- ─────────────────────────────────────────────────────────────────────────────
-- A setting that flaps — repeatedly increased then decreased then increased — is the
-- controller fighting itself (appendix F "Control Oscillation Detection"), a SAFETY failure,
-- not a tuning question. We read it straight from the catalog-mutation audit (action_history,
-- status='applied'): per relation, order the applied scale-factor values by time and count
-- DIRECTION REVERSALS (a step up after a step down, or vice versa) within the governed
-- oscillation_window. A relation with at least oscillation_min_reversals reversals is flapping.
-- Defined before governor_metrics because that view counts its output. STABLE/SQL; reads only
-- the audit. All thresholds via _param(), so it stays clean under the P3 drift gate (which
-- scans this body). relid 0 (the synthetic cluster-budget audit rows) and other actuators are
-- excluded; ties on applied_at are broken by action_id so the lag() ordering is deterministic.
CREATE OR REPLACE FUNCTION pgfc_govern._oscillating_relations()
RETURNS TABLE(relid oid, relname text, reversals bigint, n_changes bigint,
              first_at timestamptz, last_at timestamptz, recent_values text[])
LANGUAGE sql STABLE AS $fn$
WITH seq AS (
    SELECT ah.relid, ah.relname, ah.action_id, ah.applied_at,
           ah.new_value::double precision AS v
    FROM pgfc_govern.action_history ah
    WHERE ah.status = 'applied'
      AND ah.actuator = 'autovacuum_vacuum_scale_factor'
      AND ah.relid <> 0::oid
      AND ah.applied_at > now() - pgfc_govern._param('oscillation_window')::interval
), dir AS (   -- direction of each change vs the previous one for the same relation
    SELECT relid, relname, action_id, applied_at, v,
           sign(v - lag(v) OVER (PARTITION BY relid ORDER BY applied_at, action_id)) AS d
    FROM seq
), rev AS (   -- a reversal: this step's direction differs from the previous step's
    SELECT relid, relname, action_id, applied_at, v, d,
           lag(d) OVER (PARTITION BY relid ORDER BY applied_at, action_id) AS prev_d
    FROM dir
)
SELECT r.relid,
       max(r.relname)                                          AS relname,
       count(*) FILTER (WHERE r.d <> 0 AND r.prev_d <> 0
                              AND r.d <> r.prev_d)              AS reversals,
       count(*)                                                AS n_changes,
       min(r.applied_at)                                       AS first_at,
       max(r.applied_at)                                       AS last_at,
       array_agg(r.v::text ORDER BY r.applied_at, r.action_id) AS recent_values
FROM rev r
GROUP BY r.relid
HAVING count(*) FILTER (WHERE r.d <> 0 AND r.prev_d <> 0 AND r.d <> r.prev_d)
       >= pgfc_govern._param('oscillation_min_reversals')::bigint;
$fn$;
COMMENT ON FUNCTION pgfc_govern._oscillating_relations() IS
  'Control-oscillation detector (Phase 1.7 F5): relations whose applied scale-factor flaps — at least oscillation_min_reversals direction reversals within oscillation_window. Read from action_history (applied only). The governor_metrics oscillating_relations count and the evaluate_health() oscillation signal both read it; the plan() reconciler raises the operator-visible finding. [subsystem:G4]';

-- Open/resolve the operator-visible oscillation diagnostic (appendix F: "operator
-- visibility"). One unresolved control_oscillation row per flapping relation; resolved when
-- the relation stops flapping (the changes age out of the window — actuation having been
-- suspended by the diagnostic state, so no new ones arrive). Called from plan() alongside
-- the saturation reconciler, which is scoped NOT to touch this class. No magic numbers (the
-- window comes through _param), so it stays clean under the drift gate that scans it.
CREATE OR REPLACE FUNCTION pgfc_govern._reconcile_oscillation()
RETURNS void LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
BEGIN
    INSERT INTO pgfc_govern.diagnostics (relid, severity, inhibitor_class, evidence, recommendation)
    SELECT o.relid, 'critical', 'control_oscillation',
           jsonb_build_object('reversals', o.reversals,
                              'changes', o.n_changes,
                              'window', pgfc_govern._param('oscillation_window'),
                              'recent_values', o.recent_values,
                              'first_at', o.first_at,
                              'last_at', o.last_at),
           format('Scale factor is flapping (%s direction reversals in %s) — the controller is '
                  'fighting itself. The governor has entered diagnostic mode and suspended '
                  'actuation cluster-wide. Investigate the relation''s workload stability and '
                  'class; actuation resumes automatically once the oscillation ages out of the '
                  'window.', o.reversals, pgfc_govern._param('oscillation_window'))
    FROM pgfc_govern._oscillating_relations() o
    WHERE NOT EXISTS (
        SELECT 1 FROM pgfc_govern.diagnostics d
        WHERE d.resolved_at IS NULL AND d.relid = o.relid
          AND d.inhibitor_class = 'control_oscillation');

    UPDATE pgfc_govern.diagnostics d SET resolved_at = now()
    WHERE d.resolved_at IS NULL
      AND d.inhibitor_class = 'control_oscillation'
      AND NOT EXISTS (SELECT 1 FROM pgfc_govern._oscillating_relations() o
                       WHERE o.relid = d.relid);
END
$fn$;
COMMENT ON FUNCTION pgfc_govern._reconcile_oscillation() IS
  'Open/resolve the control_oscillation diagnostic (Phase 1.7 F5, appendix F "operator visibility"): one unresolved critical finding per flapping relation, auto-resolved when it stops flapping. Called from plan(); the saturation reconciler is scoped not to touch this class. [subsystem:G4]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Self-monitoring  (Phase 1.7 F1 — governor self-protection)
-- ─────────────────────────────────────────────────────────────────────────────
-- The single one-row substrate the F2 health-state evaluator will read. It has NO
-- driving FROM, so it ALWAYS returns exactly one row — counts COALESCE to 0, and
-- freshness signals (observation lag, last tick) are NULL when nothing has been
-- observed/ticked yet. That property is the point: the view must not vanish
-- precisely when the governor is least healthy (no snapshots landing, no ticks
-- finishing). Defined here, at the file tail, because it reads self_health (S6).
-- The reporting-window literals are the same out-of-scope convention as
-- catalog_health (deliberately not in the drift gate; the gate scans the
-- decision/actuation path and governor_status, not these report views). The
-- action-count columns overlap catalog_health (the operator-facing pg_class
-- footprint view) on purpose; this is the machine substrate, adding lock-timeouts,
-- observation lag, loop durations, tick errors, and the self-health footprint.
CREATE OR REPLACE VIEW pgfc_govern.governor_metrics AS
SELECT
    -- actuation outcomes over a window (mutation pressure + breaker substrate)
    (SELECT COALESCE(count(*), 0) FROM pgfc_govern.action_history
      WHERE status = 'applied' AND applied_at > now() - interval '1 hour')  AS applied_actions_last_hour,
    (SELECT COALESCE(count(*), 0) FROM pgfc_govern.action_history
      WHERE status = 'applied' AND applied_at > now() - interval '1 day')   AS applied_actions_last_day,
    (SELECT COALESCE(count(*), 0) FROM pgfc_govern.action_history
      WHERE status = 'failed'  AND applied_at > now() - interval '1 hour')  AS failed_actions_last_hour,
    (SELECT COALESCE(count(*), 0) FROM pgfc_govern.action_history
      WHERE status = 'failed'  AND applied_at > now() - interval '1 day')   AS failed_actions_last_day,
    (SELECT COALESCE(count(*), 0) FROM pgfc_govern.action_history
      WHERE failure_reason = 'lock_timeout' AND applied_at > now() - interval '1 hour') AS lock_timeouts_last_hour,
    (SELECT COALESCE(count(*), 0) FROM pgfc_govern.action_history
      WHERE failure_reason = 'lock_timeout' AND applied_at > now() - interval '1 day')  AS lock_timeouts_last_day,
    -- observation freshness (NULL = nothing observed yet)
    (SELECT max(collected_at) FROM pgfc_observe.snapshots)                   AS newest_snapshot_at,
    now() - (SELECT max(collected_at) FROM pgfc_observe.snapshots)           AS observation_lag,
    -- loop health from tick_log (NULL = nothing ticked / not yet finished)
    (SELECT started_at  FROM pgfc_govern.tick_log ORDER BY tick_id DESC LIMIT 1) AS last_tick_started_at,
    (SELECT finished_at FROM pgfc_govern.tick_log ORDER BY tick_id DESC LIMIT 1) AS last_tick_finished_at,
    (SELECT finished_at - started_at FROM pgfc_govern.tick_log
       ORDER BY tick_id DESC LIMIT 1)                                        AS last_tick_duration,
    (SELECT max(finished_at - started_at) FROM pgfc_govern.tick_log
       WHERE started_at > now() - interval '1 day')                         AS max_tick_duration_last_day,
    (SELECT COALESCE(count(*), 0) FROM pgfc_govern.tick_log
      WHERE error IS NOT NULL AND started_at > now() - interval '1 day')    AS tick_errors_last_day,
    -- storage footprint (sourced from the self-health view)
    (SELECT total_bytes FROM pgfc_govern.self_health)                       AS storage_bytes,
    (SELECT over_budget FROM pgfc_govern.self_health)                       AS over_budget,
    -- retention backlog: age of the oldest retained mutation audit row. A raw,
    -- threshold-free signal; F2 compares it to the governed retention cutoff.
    (SELECT min(applied_at) FROM pgfc_govern.action_history)                AS oldest_action_at,
    -- control oscillation (Phase 1.7 F5): how many relations are currently flapping their
    -- scale factor. The evaluate_health() oscillation signal reads this; 0 when none.
    (SELECT COALESCE(count(*), 0) FROM pgfc_govern._oscillating_relations()) AS oscillating_relations,
    -- connection pressure (Phase 1.7 F6 — load shedding): the client_backends/max_connections
    -- ratio from the NEWEST snapshot (observe() collects both). The evaluate_health()
    -- load-shed signal reads connection_pressure; NULL when nothing observed yet or a pre-F6
    -- snapshot didn't collect the inputs — never treated as "no load". The raw inputs are
    -- carried alongside so the reason string and operator views can name them.
    (SELECT client_backends FROM pgfc_observe.snapshots
       ORDER BY snapshot_id DESC LIMIT 1)                                    AS client_backends,
    (SELECT max_connections FROM pgfc_observe.snapshots
       ORDER BY snapshot_id DESC LIMIT 1)                                    AS max_connections,
    (SELECT s.client_backends::numeric / NULLIF(s.max_connections, 0)
       FROM pgfc_observe.snapshots s ORDER BY s.snapshot_id DESC LIMIT 1)    AS connection_pressure,
    -- the same pressure as a whole-percent integer, for the human-readable reason string.
    -- Computed in the view (not a control function) so evaluate_health() carries no inline
    -- 100 literal under the P3 drift gate.
    (SELECT round(100 * s.client_backends::numeric / NULLIF(s.max_connections, 0))
       FROM pgfc_observe.snapshots s ORDER BY s.snapshot_id DESC LIMIT 1)    AS connection_pressure_pct,
    -- control-loop heartbeat (FMEA-003): the last FULLY-completed cycle. finished_at is set
    -- only after verify() succeeds, and a hard error rolls the whole tick row back, so
    -- max(finished_at) is a faithful "last successful control_tick". It stays fresh in
    -- advisory_only / disabled (those still run the cycle, just don't actuate), aging only on a
    -- genuine wedge or a stopped control cron. NULL until the first cycle completes (boot):
    -- absence is not ill health — the evaluate_health() candidate treats NULL as normal,
    -- mirroring observation_lag. APPENDED AT THE END (not grouped with the tick_log signals
    -- above) so CREATE OR REPLACE VIEW stays valid on the re-run-install upgrade path:
    -- PostgreSQL only permits APPENDING columns to an existing view, never inserting mid-list.
    (SELECT max(finished_at) FROM pgfc_govern.tick_log)                     AS last_successful_tick_at,
    now() - (SELECT max(finished_at) FROM pgfc_govern.tick_log)             AS control_loop_lag;
COMMENT ON VIEW pgfc_govern.governor_metrics IS
  'One-row governor self-monitoring substrate (Phase 1.7 F1) for the F2 health-state evaluator: applied/failed/lock-timeout action counts over 1h/1d windows, observation lag (newest snapshot age), loop durations + tick errors + the control-loop heartbeat (control_loop_lag — age of the last fully-completed cycle, FMEA-003) (tick_log), the self-health storage footprint, the oldest retained audit row (retention backlog), the count of oscillating relations (Phase 1.7 F5), and the connection pressure from the newest snapshot (Phase 1.7 F6 load-shedding input). Always returns one row; counts are 0 and freshness signals NULL when nothing has happened yet. [subsystem:G4]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Failure taxonomy — unified operator surface  (Phase 1.7 F6 — self-protection)
-- ─────────────────────────────────────────────────────────────────────────────
-- One row per appendix-F failure category, always all five, so an operator can read the
-- governor's whole failure picture at a glance: which categories are CURRENTLY in failure
-- and the recorded actuation failures by class. condition_present is the live signal for
-- the category (drawn from the same governor_metrics/self_health substrate the health-state
-- machine reads), recorded_failures_last_day counts action_history rows stamped with that
-- failure_class (only actuation is produced today — the other categories' conditions are not
-- action_history rows but surface here via their live signals). This is a reporting view,
-- not a control function, so it is not scanned by the P3 drift gate; the lag threshold still
-- comes through _param() rather than an inline literal, for consistency with the evaluator.
CREATE OR REPLACE VIEW pgfc_govern.failure_taxonomy AS
WITH m AS (SELECT * FROM pgfc_govern.governor_metrics),
     recorded AS (
        SELECT failure_class, count(*) AS n
        FROM pgfc_govern.action_history
        WHERE status = 'failed' AND failure_class IS NOT NULL
          AND applied_at > now() - interval '1 day'
        GROUP BY failure_class
     )
SELECT cat.failure_class,
       cat.condition_present,
       COALESCE(r.n, 0)  AS recorded_failures_last_day,
       cat.detail
FROM m,
LATERAL (VALUES
    -- observation: the governor is losing sight of the database (stale telemetry). NULL lag
    -- (nothing observed yet) is fresh, not failing — COALESCE so condition_present is never NULL.
    ('observation',
     COALESCE(m.observation_lag > make_interval(secs => pgfc_govern._param('health_lag_degraded_secs')::double precision), false),
     CASE WHEN COALESCE(m.observation_lag > make_interval(secs => pgfc_govern._param('health_lag_degraded_secs')::double precision), false)
          THEN format('observation lag %s — telemetry is stale', m.observation_lag)
          ELSE 'telemetry fresh' END),
    -- decision: the control loop is failing. Two sources, OR'd. (1) A recorded tick error —
    -- a LATENT out-of-band hook: nothing writes tick_log.error in-band, because recording it
    -- there would require swallowing the error (blinding pg_cron's external retry/alerting), so
    -- this clause stays dormant unless an out-of-band recorder ever fills the column (FMEA-003).
    -- (2) The LIVE production signal: control_loop_lag past the degraded bound — control_tick
    -- has stopped completing cycles. NULL lag (boot) is fresh, not failing (COALESCE to false).
    ('decision',
     m.tick_errors_last_day > 0
       OR COALESCE(m.control_loop_lag > make_interval(secs => pgfc_govern._param('health_control_lag_degraded_secs')::double precision), false),
     CASE WHEN m.tick_errors_last_day > 0
          THEN format('%s control cycle(s) errored in the last day', m.tick_errors_last_day)
          WHEN COALESCE(m.control_loop_lag > make_interval(secs => pgfc_govern._param('health_control_lag_degraded_secs')::double precision), false)
          THEN format('no successful control cycle in %s — the control loop is stalled', m.control_loop_lag)
          ELSE 'no cycle errors' END),
    -- actuation: an attempted change failed (lock timeout / permission / conflicting DDL)
    ('actuation',
     m.failed_actions_last_hour > 0,
     CASE WHEN m.failed_actions_last_day > 0
          THEN format('%s failed action(s) in the last hour, %s in the last day',
                      m.failed_actions_last_hour, m.failed_actions_last_day)
          ELSE 'no failed actions' END),
    -- resource: the governor is over its own storage footprint budget
    ('resource',
     COALESCE(m.over_budget, false),
     CASE WHEN COALESCE(m.over_budget, false)
          THEN format('governor storage footprint over budget (%s bytes)', m.storage_bytes)
          ELSE 'within storage budget' END),
    -- safety: the controller is fighting itself (control oscillation — F5)
    ('safety',
     m.oscillating_relations > 0,
     CASE WHEN m.oscillating_relations > 0
          THEN format('%s relation(s) oscillating — control is flapping', m.oscillating_relations)
          ELSE 'no safety-class failures' END)
) AS cat(failure_class, condition_present, detail)
LEFT JOIN recorded r ON r.failure_class = cat.failure_class;
COMMENT ON VIEW pgfc_govern.failure_taxonomy IS
  'Unified failure-classification surface (Phase 1.7 F6, appendix F): one row per category (observation/decision/actuation/resource/safety) with condition_present (the live signal, from the same substrate the health-state machine reads) and recorded_failures_last_day (action_history rows stamped with that failure_class — actuation only, today). The governor''s whole failure picture in five rows. [subsystem:G4]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Health-state machine  (Phase 1.7 F2 — governor self-protection)
-- ─────────────────────────────────────────────────────────────────────────────
-- Compute the current health state from the F1 governor_metrics substrate against the
-- born-governed transition thresholds, write the singleton governor_state, and record a
-- state_transitions row ONLY when the state actually changes. Advisory in F2: it does not
-- gate actuation (the apply() authority gate consults governor_state in F4).
--
-- Each signal contributes a candidate (state, reason); the WORST state wins via the enum's
-- native ordering (ORDER BY state DESC). A signal that is within bounds contributes a
-- 'normal' candidate with a NULL reason, so the baseline "all within bounds" reason is
-- chosen only when nothing is elevated (reason-IS-NULL sorts last). Absence of data is NOT
-- ill health: NULL observation_lag (no snapshots yet — boot) yields normal, not emergency.
-- All thresholds come through _param() — no inline magic numbers — so this control function
-- stays clean under the P3 drift gate. The automatic range is normal→emergency; 'disabled'
-- is operator-forced only (F3).
CREATE OR REPLACE FUNCTION pgfc_govern.evaluate_health()
RETURNS pgfc_govern.governor_health_state
LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
DECLARE
    m          record;
    v_lag      numeric;
    v_clag     numeric;
    v_current  pgfc_govern.governor_health_state;
    v_computed pgfc_govern.governor_health_state;
    v_reason   text;
    v_forced   pgfc_govern.governor_health_state;
    v_freason  text;
    v_daily_budget integer;
BEGIN
    SELECT * INTO m FROM pgfc_govern.governor_metrics;     -- guaranteed one row (F1)
    v_lag := EXTRACT(EPOCH FROM m.observation_lag);        -- NULL when nothing observed yet
    v_clag := EXTRACT(EPOCH FROM m.control_loop_lag);      -- NULL when no cycle completed yet

    -- Effective daily mutation budget (Phase 1.7 F4 breaker), resolved the same way apply()
    -- does: live policy, falling back to the registry default — so the breaker tracks the
    -- same cap the authority limiter enforces.
    SELECT daily_mutation_budget INTO v_daily_budget
      FROM pgfc_govern.policy WHERE enabled ORDER BY policy_name LIMIT 1;
    v_daily_budget := COALESCE(v_daily_budget, pgfc_govern._param('daily_mutation_budget')::integer);

    SELECT c.state, c.reason INTO v_computed, v_reason
    FROM (VALUES
        -- baseline: healthiest, always present, only wins when nothing is elevated
        ('normal'::pgfc_govern.governor_health_state,
         'all self-monitoring signals within bounds'::text),
        -- stale observation: the governor is losing sight of the database
        (CASE WHEN v_lag > pgfc_govern._param('health_lag_emergency_secs')::numeric THEN 'emergency'
              WHEN v_lag > pgfc_govern._param('health_lag_degraded_secs')::numeric  THEN 'degraded'
              ELSE 'normal' END::pgfc_govern.governor_health_state,
         CASE WHEN v_lag > pgfc_govern._param('health_lag_degraded_secs')::numeric
              THEN format('observation lag %ss — telemetry is stale', round(v_lag)) END),
        -- stale control loop (FMEA-003): control_tick() has stopped completing cycles. This
        -- evaluator runs from observe_tick() too, so a WEDGED control_tick — which cannot
        -- evaluate its own health (this function runs inside it) — is still caught by the
        -- INDEPENDENT fast loop. Mirrors the observation-lag ladder (degraded -> emergency); the
        -- symmetry is the point — control_tick watches observe via observation_lag, observe
        -- watches control via control_loop_lag. NULL lag (no completed cycle yet — boot, or
        -- control never scheduled) yields the 'normal' candidate, so absence is not ill health.
        (CASE WHEN v_clag > pgfc_govern._param('health_control_lag_emergency_secs')::numeric THEN 'emergency'
              WHEN v_clag > pgfc_govern._param('health_control_lag_degraded_secs')::numeric  THEN 'degraded'
              ELSE 'normal' END::pgfc_govern.governor_health_state,
         CASE WHEN v_clag > pgfc_govern._param('health_control_lag_degraded_secs')::numeric
              THEN format('control loop lag %ss — no successful control cycle', round(v_clag)) END),
        -- repeated actuation failures: a circuit-breaker precursor
        (CASE WHEN m.failed_actions_last_hour > pgfc_govern._param('health_failed_diagnostic')::bigint THEN 'diagnostic'
              WHEN m.failed_actions_last_hour > pgfc_govern._param('health_failed_degraded')::bigint   THEN 'degraded'
              ELSE 'normal' END::pgfc_govern.governor_health_state,
         CASE WHEN m.failed_actions_last_hour > pgfc_govern._param('health_failed_degraded')::bigint
              THEN format('%s failed actions in the last hour', m.failed_actions_last_hour) END),
        -- lock-timeout storm: cannot acquire locks to act
        (CASE WHEN m.lock_timeouts_last_hour > pgfc_govern._param('health_lock_timeouts_diagnostic')::bigint
              THEN 'diagnostic' ELSE 'normal' END::pgfc_govern.governor_health_state,
         CASE WHEN m.lock_timeouts_last_hour > pgfc_govern._param('health_lock_timeouts_diagnostic')::bigint
              THEN format('%s lock timeouts in the last hour', m.lock_timeouts_last_hour) END),
        -- storage pressure: the governor is over its own footprint budget
        (CASE WHEN m.over_budget THEN 'degraded' ELSE 'normal' END::pgfc_govern.governor_health_state,
         CASE WHEN m.over_budget THEN 'governor storage footprint over budget' END),
        -- mutation-budget circuit breaker (Phase 1.7 F4): the governor has spent its
        -- per-day Invariant-4 budget. This is a degraded-level SIGNAL, never diagnostic:
        -- hitting the budget is normal authority limiting, not ill health, and apply()'s
        -- hard cap already refuses the over-budget mutations — so the governor stays
        -- visible (degraded) and keeps acting up to the cap, rather than suspending itself.
        (CASE WHEN m.applied_actions_last_day >= v_daily_budget THEN 'degraded'
              ELSE 'normal' END::pgfc_govern.governor_health_state,
         CASE WHEN m.applied_actions_last_day >= v_daily_budget
              THEN format('daily mutation budget spent (%s applied in the last day)',
                          m.applied_actions_last_day) END),
        -- control oscillation (Phase 1.7 F5): a setting flapping is the controller fighting
        -- itself — a SAFETY failure, so it trips diagnostic (not degraded): the F4 authority
        -- gate then suspends actuation cluster-wide while the oscillating relation gets an
        -- operator-visible finding (_reconcile_oscillation in plan()). Diagnostic, not
        -- emergency: observation and diagnosis stay on. It auto-recovers once the flapping
        -- ages out of oscillation_window (actuation having been suspended, none is added).
        (CASE WHEN m.oscillating_relations > 0 THEN 'diagnostic'
              ELSE 'normal' END::pgfc_govern.governor_health_state,
         CASE WHEN m.oscillating_relations > 0
              THEN format('%s relation(s) oscillating — control is flapping', m.oscillating_relations) END),
        -- load shedding (Phase 1.7 F6): under connection pressure the governor sheds its own
        -- load by entering diagnostic, so the F4 authority gate suspends actuation cluster-wide
        -- — it stops competing for locks and consumes fewer resources when the database needs
        -- them most ("the governor should consume fewer resources when the database needs them
        -- most"). Diagnostic, not emergency: observation and diagnosis stay on (observe
        -- aggressively, act cautiously). A degraded tier would be cosmetic here — degraded still
        -- actuates, so it would not actually shed — so the single threshold goes straight to the
        -- tier that bites. NULL pressure (boot, or a pre-F6 snapshot) yields the 'normal'
        -- candidate (NULL >= x is NULL → ELSE), so absence of data is not ill health. Recovers
        -- automatically: when pressure eases, the next evaluation returns to normal (transient,
        -- unlike F5's windowed oscillation hold). Surfaced via governor_state.reason and the
        -- state_transitions audit, like the other breaker signals.
        (CASE WHEN m.connection_pressure >= pgfc_govern._param('load_shed_connection_pct')::numeric
              THEN 'diagnostic' ELSE 'normal' END::pgfc_govern.governor_health_state,
         CASE WHEN m.connection_pressure >= pgfc_govern._param('load_shed_connection_pct')::numeric
              THEN format('connection pressure %s%% (%s/%s client backends) — shedding load, actuation suspended',
                          m.connection_pressure_pct, m.client_backends, m.max_connections) END)
    ) AS c(state, reason)
    ORDER BY c.state DESC, (c.reason IS NULL)              -- worst state; non-null reason wins ties
    LIMIT 1;

    -- Operator override (Phase 1.7 F3): the forced state is a caution FLOOR. Take the WORST
    -- of the auto-computed state and any operator-forced state, so a human can force MORE
    -- caution but never less. NULL operator_forced = fully automatic. When the hold binds
    -- (it is at least as cautious as the automatic state), its reason is surfaced; when the
    -- automatic state is worse, that binds instead and the hold simply stays recorded.
    SELECT operator_forced, forced_reason INTO v_forced, v_freason
      FROM pgfc_govern.governor_state;
    IF v_forced IS NOT NULL AND v_forced >= v_computed THEN
        v_reason   := format('operator-forced %s: %s', v_forced,
                             COALESCE(v_freason, '(no reason given)'));
        v_computed := v_forced;
    END IF;

    SELECT state INTO v_current FROM pgfc_govern.governor_state;

    IF v_computed IS DISTINCT FROM v_current THEN
        INSERT INTO pgfc_govern.state_transitions (from_state, to_state, reason, triggering_condition)
        VALUES (v_current, v_computed, v_reason, to_jsonb(m));
        UPDATE pgfc_govern.governor_state
           SET state = v_computed, since = now(), reason = v_reason, evaluated_at = now();
    ELSE
        UPDATE pgfc_govern.governor_state
           SET reason = v_reason, evaluated_at = now();    -- refresh reason/timestamp, no transition
    END IF;

    RETURN v_computed;
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.evaluate_health() IS
  'Compute the governor health state (Phase 1.7 F2) from the governor_metrics substrate against the born-governed transition thresholds (failed actions, lock timeouts, observation lag, the control-loop-lag heartbeat (FMEA-003), storage footprint, the F4 daily-mutation-budget circuit breaker — degraded-level only — the F5 control-oscillation signal — diagnostic — and the F6 connection-pressure load-shedding signal — diagnostic), then apply the F3 operator override as a caution floor (worst of auto and operator_forced); write governor_state and record a state_transitions row on change. The state it writes is the input to the F4 apply() authority gate. Returns the effective state. [subsystem:G4]';

-- ─────────────────────────────────────────────────────────────────────────────
-- Human-override surface  (Phase 1.7 F3 — governor self-protection)
-- ─────────────────────────────────────────────────────────────────────────────
-- Operators retain ultimate authority (appendix F "Human Override"): they can force the
-- governor into a MORE cautious state and release the hold. The override is a caution
-- FLOOR, not a setpoint — evaluate_health() takes the worst of the auto-computed state and
-- operator_forced (see above), so forcing 'degraded' while the automatic signals demand
-- 'diagnostic' still yields 'diagnostic'. A human can therefore force more caution but never
-- less; the way back to less caution is clear_forced_state(), not forcing 'normal'. Every
-- force/clear runs through evaluate_health(), so the resulting change is audited as a
-- state_transitions row exactly like an automatic transition, and forced_by/forced_at on
-- governor_state record who placed the hold and when. These functions set state only — they
-- do not themselves gate actuation (that is the F4 authority gate, which reads the state
-- they set). No magic numbers: they carry no governed constants (nothing for the drift gate
-- or the registry).

-- Force the governor into a specified (more-cautious) state and hold it there until cleared.
-- 'normal' is rejected: it is not a more-cautious target, and releasing a hold is what
-- clear_forced_state() is for. Returns the resulting effective state (which may be even more
-- cautious if an automatic signal is worse than the forced floor).
CREATE OR REPLACE FUNCTION pgfc_govern.force_state(
    p_state  pgfc_govern.governor_health_state,
    p_reason text)
RETURNS pgfc_govern.governor_health_state
LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
BEGIN
    IF p_state = 'normal' THEN
        RAISE EXCEPTION 'cannot force the normal state (a force only adds caution); use clear_forced_state() to release a hold';
    END IF;
    UPDATE pgfc_govern.governor_state
       SET operator_forced = p_state,
           forced_reason   = p_reason,
           forced_by       = current_user,
           forced_at       = now();
    RETURN pgfc_govern.evaluate_health();   -- recompute (worst-of) + audit the transition
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.force_state(pgfc_govern.governor_health_state, text) IS
  'Operator override (Phase 1.7 F3): force the governor into a more-cautious state (a caution floor honored by evaluate_health''s worst-of rule); rejects normal. Audited as a state transition; recorded in operator_forced/forced_by/forced_at. Returns the effective state. Released by clear_forced_state(). [subsystem:G4]';

-- Release any operator-forced hold and return the governor to fully automatic control.
-- Idempotent — clearing when no hold is set is a no-op that simply re-evaluates.
CREATE OR REPLACE FUNCTION pgfc_govern.clear_forced_state(p_reason text DEFAULT NULL)
RETURNS pgfc_govern.governor_health_state
LANGUAGE plpgsql
    SET search_path = pgfc_govern, pgfc_observe, pg_catalog
AS $fn$
BEGIN
    UPDATE pgfc_govern.governor_state
       SET operator_forced = NULL,
           forced_reason   = NULL,
           forced_by       = NULL,
           forced_at       = NULL;
    RETURN pgfc_govern.evaluate_health();   -- recompute purely from automatic signals
END
$fn$;
COMMENT ON FUNCTION pgfc_govern.clear_forced_state(text) IS
  'Operator override (Phase 1.7 F3): release any operator-forced hold and return to fully automatic control. The subsequent automatic transition is audited. Returns the (now automatic) effective state. [subsystem:G4]';

-- Disable the governor entirely (appendix F "Disabled Mode"): all control activity ceases;
-- history is preserved. A hard operator stop, distinct from policy.enabled (which gates a
-- given policy row driving the loop) — disable() forces the health state itself to disabled,
-- which the F4 authority gate then honors regardless of policy.
CREATE OR REPLACE FUNCTION pgfc_govern.disable(p_reason text)
RETURNS pgfc_govern.governor_health_state
LANGUAGE sql AS $fn$
    SELECT pgfc_govern.force_state('disabled', p_reason);
$fn$;
COMMENT ON FUNCTION pgfc_govern.disable(text) IS
  'Operator override (Phase 1.7 F3): force the disabled state (all control ceases, history preserved). Distinct from policy.enabled — this forces the health state, which the F4 authority gate honors. Released by clear_forced_state(). [subsystem:G4]';

-- Suspend actuation while keeping full observation and diagnosis (appendix F "suspend
-- actuation" / "force diagnostic mode" — the same state: diagnostic's defining capability is
-- observe/estimate/diagnose with actuation suspended).
CREATE OR REPLACE FUNCTION pgfc_govern.suspend_actuation(p_reason text)
RETURNS pgfc_govern.governor_health_state
LANGUAGE sql AS $fn$
    SELECT pgfc_govern.force_state('diagnostic', p_reason);
$fn$;
COMMENT ON FUNCTION pgfc_govern.suspend_actuation(text) IS
  'Operator override (Phase 1.7 F3): force the diagnostic state — actuation suspended, full observation/diagnosis retained (appendix F "suspend actuation"). Released by clear_forced_state(). [subsystem:G4]';
