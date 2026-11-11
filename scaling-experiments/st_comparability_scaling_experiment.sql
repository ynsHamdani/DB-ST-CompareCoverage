/*=============================================================================
  Controlled scaling and selectivity experiment for
  stcmp_experiment.st_comparable_areas_by_time (v2)

  Purpose
  -------
  Generate three deterministic synthetic workloads and measure the actual
  v2 database function over N = 10, 20, 30, 40 observations:

    W1_DENSE                all footprints overlap; permissive temporal bound
    W2_TEMPORAL_SELECTIVE   same footprints; restrictive 3-day adjacent gap
    W3_SPATIAL_SELECTIVE    alternating, spatially disjoint half-area footprints

  For each workload and N:
    - Generate one source relation/view with exactly N observations.
    - Derive expected pair/triple result counts independently from the known
      observation indices, temporal supports, and spatial region labels.
    - Execute the real ByTime function once as a warm-up.
    - Execute it 3 measured times, consuming all output rows.
    - Record runtime, pair/triple counts, total result count, area checksum,
      extension-flag count, and correctness status.
    - Produce summary views and graph-ready SELECT statements.

  Output semantics
  ----------------
  p_max_sequence_length = 3. The public output therefore contains pairs and
  triples. The v2 function may internally generate one additional level to
  evaluate has_valid_extension for triples; that required probe work is
  included in measured runtime, while probe sequences are not counted as
  returned results.

  Requirements
  ------------
  1. PostgreSQL + PostGIS.
  2. Installed and verified:
       stcmp_experiment.st_coverage_profile(...)
       stcmp_experiment.st_comparable_areas_by_time(...)  -- v2
       stcmp_experiment.comparable_order_mode enum
  3. The ByTime v2 signature must include p_max_sequence_length and return:
       sequence_length, observation_sequence, common_support_geom,
       common_area, has_valid_extension

  Important
  ---------
  - The script drops/recreates ONLY the dedicated schema
      stcmp_bench_eval
    so previous benchmark runs in that schema are replaced.
  - It does not modify stcmp_experiment or the user's application tables.
  - Execute the complete script in one database. The benchmark DO block uses
    the functions installed in stcmp_experiment.
  - It is a warm-cache microbenchmark: one unrecorded warm-up then 3 measured
    repetitions per workload/N configuration.
  - Runtime is server-side function execution plus aggregate consumption of
    all returned rows; client/network transfer and GIS rendering are excluded.
  - No baseline comparison is claimed. This experiment studies how temporal
    and spatial selectivity affect the real operator's output cardinality and
    runtime, with a known result-count oracle.
=============================================================================*/

CREATE EXTENSION IF NOT EXISTS postgis;

/* Rebuild only the dedicated benchmark schema. */
DROP SCHEMA IF EXISTS stcmp_bench_eval CASCADE;
CREATE SCHEMA stcmp_bench_eval;

/*----------------------------- 1. Parameters ------------------------------*/

CREATE TABLE stcmp_bench_eval.experiment_config (
    config_key       text PRIMARY KEY,
    config_value     text NOT NULL
);

INSERT INTO stcmp_bench_eval.experiment_config(config_key, config_value)
VALUES
    ('observation_counts', '10,20,30,40'),
    ('min_sequence_length', '2'),
    ('max_sequence_length', '3'),
    ('measured_repetitions', '3'),
    ('warmup_repetitions', '1'),
    ('temporal_mode', 'nonoverlapping_ordered'),
    ('w1_max_elapsed', '365 days'),
    ('w2_max_elapsed', '3 days'),
    ('w3_max_elapsed', '365 days');

/*----------------------------- 2. Study area -------------------------------*/

CREATE TABLE stcmp_bench_eval.study_area (
    area_id text PRIMARY KEY,
    geom    geometry(MultiPolygon, 25832) NOT NULL,
    CHECK (ST_IsValid(geom)),
    CHECK (NOT ST_IsEmpty(geom))
);

INSERT INTO stcmp_bench_eval.study_area(area_id, geom)
VALUES (
    'A_BENCH',
    ST_Multi(ST_MakeEnvelope(600000, 6200000, 601000, 6201000, 25832))
);

/*
  Spatial layouts:
    FULL  = entire 1,000 m x 1,000 m study area = 1,000,000 m^2
    LEFT  = x=[600000,600490], y=[6200000,6201000] = 490,000 m^2
    RIGHT = x=[600510,601000], y=[6200000,6201000] = 490,000 m^2

  LEFT and RIGHT are separated by a 20 m gap. Thus an observation pair
  drawn from different regions has no spatial intersection (not even a
  boundary-only contact), while observations in the same region share the
  complete 490,000 m^2 region.
*/

/*----------------------------- 3. Source data ------------------------------*/

CREATE TABLE stcmp_bench_eval.observations (
    workload          text NOT NULL,
    n_obs             integer NOT NULL,
    obs_index         integer NOT NULL,
    observation_id    text NOT NULL,
    group_id          text NOT NULL,
    region_key        text NOT NULL,
    temporal_support  tstzrange NOT NULL,
    geom              geometry(MultiPolygon, 25832) NOT NULL,
    PRIMARY KEY (workload, n_obs, observation_id),
    UNIQUE (workload, n_obs, obs_index),
    CHECK (n_obs > 0),
    CHECK (obs_index BETWEEN 1 AND n_obs),
    CHECK (NOT isempty(temporal_support)),
    CHECK (NOT lower_inf(temporal_support)),
    CHECK (NOT upper_inf(temporal_support)),
    CHECK (lower_inc(temporal_support)),
    CHECK (
        (lower(temporal_support) = upper(temporal_support)
         AND upper_inc(temporal_support))
        OR
        (lower(temporal_support) < upper(temporal_support)
         AND NOT upper_inc(temporal_support))
    ),
    CHECK (ST_IsValid(geom)),
    CHECK (NOT ST_IsEmpty(geom))
);

/* Geometry/temporal indexes mirror the canonical observation interface. */
CREATE INDEX observations_scope_idx
    ON stcmp_bench_eval.observations(workload, n_obs, obs_index);

CREATE INDEX observations_geom_gix
    ON stcmp_bench_eval.observations USING GIST(geom);

CREATE INDEX observations_temporal_gix
    ON stcmp_bench_eval.observations USING GIST(temporal_support);

CREATE INDEX observations_group_idx
    ON stcmp_bench_eval.observations(workload, n_obs, group_id);

/*
  Deterministic generation:
    - Each observation is a singleton instant at 2020-01-01 + (i-1) days.
    - All observations are ordered by obs_index and time.
    - group_id repeats every two observations. ByTime ignores this column;
      it is retained to reflect realistic group metadata.
    - W1 and W2 use the full study-area footprint.
    - W3 alternates LEFT and RIGHT footprints.
*/

WITH
sizes(n_obs) AS (
    VALUES (10), (20), (30), (40)
),
workloads(workload, max_elapsed, layout) AS (
    VALUES
      ('W1_DENSE'::text,              INTERVAL '365 days', 'FULL'::text),
      ('W2_TEMPORAL_SELECTIVE'::text, INTERVAL '3 days',   'FULL'::text),
      ('W3_SPATIAL_SELECTIVE'::text,  INTERVAL '365 days', 'SPLIT'::text)
),
regions AS (
    SELECT
        ST_Multi(ST_MakeEnvelope(600000, 6200000, 601000, 6201000, 25832)) AS full_geom,
        ST_Multi(ST_MakeEnvelope(600000, 6200000, 600490, 6201000, 25832)) AS left_geom,
        ST_Multi(ST_MakeEnvelope(600510, 6200000, 601000, 6201000, 25832)) AS right_geom
)
INSERT INTO stcmp_bench_eval.observations(
    workload, n_obs, obs_index, observation_id, group_id,
    region_key, temporal_support, geom
)
SELECT
    w.workload,
    s.n_obs,
    i AS obs_index,
    format('%s_N%s_O%s', w.workload, s.n_obs, lpad(i::text, 3, '0')),
    format('GROUP_%s', lpad(ceil(i / 2.0)::integer::text, 3, '0')),
    CASE
        WHEN w.layout = 'FULL' THEN 'FULL'
        WHEN i % 2 = 1 THEN 'LEFT'
        ELSE 'RIGHT'
    END,
    tstzrange(
        timestamptz '2020-01-01 00:00:00+00'
          + (i - 1) * INTERVAL '1 day',
        timestamptz '2020-01-01 00:00:00+00'
          + (i - 1) * INTERVAL '1 day',
        '[]'
    ),
    CASE
        WHEN w.layout = 'FULL' THEN r.full_geom
        WHEN i % 2 = 1 THEN r.left_geom
        ELSE r.right_geom
    END
FROM sizes s
CROSS JOIN workloads w
CROSS JOIN LATERAL generate_series(1, s.n_obs) AS gs(i)
CROSS JOIN regions r;

ANALYZE stcmp_bench_eval.observations;

/* Basic input-data sanity summary. */
SELECT
    workload,
    n_obs,
    count(*) AS generated_observations,
    count(DISTINCT group_id) AS distinct_groups,
    count(DISTINCT region_key) AS spatial_regions,
    min(lower(temporal_support)) AS first_instant,
    max(upper(temporal_support)) AS last_instant
FROM stcmp_bench_eval.observations
GROUP BY workload, n_obs
ORDER BY workload, n_obs;

/*----------------------- 4. Scenario source views --------------------------*/

CREATE TABLE stcmp_bench_eval.scenarios (
    workload                 text NOT NULL,
    n_obs                    integer NOT NULL,
    source_relation          regclass NOT NULL,
    max_elapsed              interval NOT NULL,
    expected_area_per_result double precision NOT NULL,
    PRIMARY KEY (workload, n_obs)
);

DO $create_views$
DECLARE
    v_workload text;
    v_max_elapsed interval;
    v_layout text;
    v_n integer;
    v_view_name text;
    v_area double precision;
BEGIN
    FOR v_workload, v_max_elapsed, v_layout IN
        SELECT *
        FROM (VALUES
          ('W1_DENSE'::text,              INTERVAL '365 days', 'FULL'::text),
          ('W2_TEMPORAL_SELECTIVE'::text, INTERVAL '3 days',   'FULL'::text),
          ('W3_SPATIAL_SELECTIVE'::text,  INTERVAL '365 days', 'SPLIT'::text)
        ) AS w(workload, max_elapsed, layout)
    LOOP
        FOR v_n IN SELECT unnest(ARRAY[10,20,30,40])
        LOOP
            v_view_name := format('v_%s_n%s', lower(v_workload), v_n);

            EXECUTE format($view$
                CREATE VIEW stcmp_bench_eval.%I AS
                SELECT
                    observation_id,
                    group_id,
                    geom,
                    temporal_support
                FROM stcmp_bench_eval.observations
                WHERE workload = %L
                  AND n_obs = %s
            $view$, v_view_name, v_workload, v_n);

            v_area := CASE WHEN v_layout = 'FULL' THEN 1000000.0 ELSE 490000.0 END;

            INSERT INTO stcmp_bench_eval.scenarios(
                workload, n_obs, source_relation, max_elapsed,
                expected_area_per_result
            )
            VALUES (
                v_workload,
                v_n,
                format('stcmp_bench_eval.%I', v_view_name)::regclass,
                v_max_elapsed,
                v_area
            );
        END LOOP;
    END LOOP;
END;
$create_views$;

/*---------------- 5. Independent expected-result oracle --------------------*/

CREATE TABLE stcmp_bench_eval.expected_results (
    workload           text NOT NULL,
    n_obs              integer NOT NULL,
    expected_pairs     bigint NOT NULL,
    expected_triples   bigint NOT NULL,
    expected_sequences bigint NOT NULL,
    expected_area_sum  double precision NOT NULL,
    PRIMARY KEY (workload, n_obs)
);

/*
  The expected-count oracle does NOT call ST_ComparableAreasByTime and does
  NOT compute geometry overlays. It enumerates only integer observation
  indices and applies the known benchmark design:

    W1: all pairs/triples are temporally and spatially eligible.
    W2: each adjacent selected pair must be <= 3 days apart.
    W3: each selected observation must have the same LEFT/RIGHT region key.

  This gives an independent cardinality check for the actual PostGIS function.
*/

INSERT INTO stcmp_bench_eval.expected_results(
    workload, n_obs, expected_pairs, expected_triples,
    expected_sequences, expected_area_sum
)
SELECT
    s.workload,
    s.n_obs,
    p.expected_pairs,
    t.expected_triples,
    p.expected_pairs + t.expected_triples,
    (p.expected_pairs + t.expected_triples) * s.expected_area_per_result
FROM stcmp_bench_eval.scenarios s
CROSS JOIN LATERAL (
    SELECT count(*)::bigint AS expected_pairs
    FROM stcmp_bench_eval.observations a
    JOIN stcmp_bench_eval.observations b
      ON b.workload = a.workload
     AND b.n_obs = a.n_obs
     AND b.obs_index > a.obs_index
    WHERE a.workload = s.workload
      AND a.n_obs = s.n_obs
      AND upper(a.temporal_support) <= lower(b.temporal_support)
      AND NOT (a.temporal_support && b.temporal_support)
      AND lower(b.temporal_support) - upper(a.temporal_support) <= s.max_elapsed
      AND (
            s.workload <> 'W3_SPATIAL_SELECTIVE'
            OR a.region_key = b.region_key
          )
) p
CROSS JOIN LATERAL (
    SELECT count(*)::bigint AS expected_triples
    FROM stcmp_bench_eval.observations a
    JOIN stcmp_bench_eval.observations b
      ON b.workload = a.workload
     AND b.n_obs = a.n_obs
     AND b.obs_index > a.obs_index
    JOIN stcmp_bench_eval.observations c
      ON c.workload = b.workload
     AND c.n_obs = b.n_obs
     AND c.obs_index > b.obs_index
    WHERE a.workload = s.workload
      AND a.n_obs = s.n_obs
      AND upper(a.temporal_support) <= lower(b.temporal_support)
      AND NOT (a.temporal_support && b.temporal_support)
      AND lower(b.temporal_support) - upper(a.temporal_support) <= s.max_elapsed
      AND upper(b.temporal_support) <= lower(c.temporal_support)
      AND NOT (b.temporal_support && c.temporal_support)
      AND lower(c.temporal_support) - upper(b.temporal_support) <= s.max_elapsed
      AND (
            s.workload <> 'W3_SPATIAL_SELECTIVE'
            OR (a.region_key = b.region_key AND b.region_key = c.region_key)
          )
) t;

/* Expected counts should be visible before any timed execution. */
SELECT
    workload,
    n_obs,
    expected_pairs,
    expected_triples,
    expected_sequences,
    expected_area_sum
FROM stcmp_bench_eval.expected_results
ORDER BY workload, n_obs;

/* Assert the deterministic expected cardinalities for this generator. */
DO $expected_check$
DECLARE
    v_bad bigint;
BEGIN
    WITH expected AS (
        SELECT * FROM (VALUES
          ('W1_DENSE'::text, 10, 45::bigint, 120::bigint),
          ('W1_DENSE',      20, 190, 1140),
          ('W1_DENSE',      30, 435, 4060),
          ('W1_DENSE',      40, 780, 9880),
          ('W2_TEMPORAL_SELECTIVE', 10, 24, 54),
          ('W2_TEMPORAL_SELECTIVE', 20, 54, 144),
          ('W2_TEMPORAL_SELECTIVE', 30, 84, 234),
          ('W2_TEMPORAL_SELECTIVE', 40, 114, 324),
          ('W3_SPATIAL_SELECTIVE', 10, 20, 20),
          ('W3_SPATIAL_SELECTIVE', 20, 90, 240),
          ('W3_SPATIAL_SELECTIVE', 30, 210, 910),
          ('W3_SPATIAL_SELECTIVE', 40, 380, 2280)
        ) AS x(workload, n_obs, pairs, triples)
    )
    SELECT count(*)
      INTO v_bad
    FROM expected e
    LEFT JOIN stcmp_bench_eval.expected_results a
      ON a.workload = e.workload AND a.n_obs = e.n_obs
    WHERE a.workload IS NULL
       OR a.expected_pairs <> e.pairs
       OR a.expected_triples <> e.triples;

    IF v_bad <> 0 THEN
        RAISE EXCEPTION 'Expected-count oracle mismatch in % workload configurations', v_bad;
    END IF;
END;
$expected_check$;

/*--------------------- 6. Benchmark run storage ----------------------------*/

CREATE TABLE stcmp_bench_eval.batches (
    batch_id       bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    started_at     timestamptz NOT NULL DEFAULT clock_timestamp(),
    description    text NOT NULL
);

CREATE TABLE stcmp_bench_eval.runtime_runs (
    run_id               bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    batch_id             bigint NOT NULL REFERENCES stcmp_bench_eval.batches(batch_id),
    workload             text NOT NULL,
    n_obs                integer NOT NULL,
    repetition           integer NOT NULL,
    elapsed_ms           double precision NOT NULL,
    actual_pairs         bigint NOT NULL,
    actual_triples       bigint NOT NULL,
    actual_sequences     bigint NOT NULL,
    expected_pairs       bigint NOT NULL,
    expected_triples     bigint NOT NULL,
    expected_sequences   bigint NOT NULL,
    actual_area_sum      double precision NOT NULL,
    expected_area_sum    double precision NOT NULL,
    extension_true_count bigint NOT NULL,
    is_correct           boolean NOT NULL,
    started_at           timestamptz NOT NULL,
    finished_at          timestamptz NOT NULL,
    UNIQUE (batch_id, workload, n_obs, repetition)
);

CREATE INDEX runtime_runs_summary_idx
    ON stcmp_bench_eval.runtime_runs(batch_id, workload, n_obs);

/*------------------------ 7. Execute the benchmark -------------------------*/

DO $run_benchmark$
DECLARE
    s record;
    v_batch_id bigint;
    v_rep integer;
    v_source regclass;
    v_started timestamptz;
    v_finished timestamptz;
    v_elapsed_ms double precision;
    v_pairs bigint;
    v_triples bigint;
    v_total bigint;
    v_area_sum double precision;
    v_extension_true bigint;
    v_expected_pairs bigint;
    v_expected_triples bigint;
    v_expected_total bigint;
    v_expected_area_sum double precision;
    v_correct boolean;
    v_warm_count bigint;
    v_warm_area double precision;
BEGIN
    INSERT INTO stcmp_bench_eval.batches(description)
    VALUES ('ByTime v2: dense, temporal-selective, and spatial-selective workloads; N=10,20,30,40; max sequence length=3; warm-up + 3 measured runs')
    RETURNING batch_id INTO v_batch_id;

    FOR s IN
        SELECT
            sc.workload,
            sc.n_obs,
            sc.source_relation,
            sc.max_elapsed,
            e.expected_pairs,
            e.expected_triples,
            e.expected_sequences,
            e.expected_area_sum
        FROM stcmp_bench_eval.scenarios sc
        JOIN stcmp_bench_eval.expected_results e
          USING (workload, n_obs)
        ORDER BY sc.workload, sc.n_obs
    LOOP
        v_source := s.source_relation;
        v_expected_pairs := s.expected_pairs;
        v_expected_triples := s.expected_triples;
        v_expected_total := s.expected_sequences;
        v_expected_area_sum := s.expected_area_sum;

        /* One unrecorded warm-up for this scenario. */
        SELECT
            count(*)::bigint,
            COALESCE(sum(r.common_area), 0)::double precision
        INTO v_warm_count, v_warm_area
        FROM stcmp_experiment.st_comparable_areas_by_time(
            p_source                 => v_source,
            p_observation_id_column  => 'observation_id',
            p_geom_column            => 'geom',
            p_time_column            => 'temporal_support',
            p_study_area             => (
                SELECT geom
                FROM stcmp_bench_eval.study_area
                WHERE area_id = 'A_BENCH'
            ),
            p_order_mode             => 'nonoverlapping_ordered'::stcmp_experiment.comparable_order_mode,
            p_group_column           => NULL::name,
            p_min_sequence_length    => 2,
            p_max_sequence_length    => 3,
            p_min_common_area        => 0,
            p_min_elapsed            => NULL::interval,
            p_max_elapsed            => s.max_elapsed,
            p_time_window            => NULL::tstzrange
        ) AS r;

        /* Three measured repetitions. The aggregate consumes the entire output. */
        FOR v_rep IN 1..3 LOOP
            v_started := clock_timestamp();

            SELECT
                count(*) FILTER (WHERE r.sequence_length = 2)::bigint,
                count(*) FILTER (WHERE r.sequence_length = 3)::bigint,
                count(*)::bigint,
                COALESCE(sum(r.common_area), 0)::double precision,
                count(*) FILTER (WHERE r.has_valid_extension)::bigint
            INTO
                v_pairs,
                v_triples,
                v_total,
                v_area_sum,
                v_extension_true
            FROM stcmp_experiment.st_comparable_areas_by_time(
                p_source                 => v_source,
                p_observation_id_column  => 'observation_id',
                p_geom_column            => 'geom',
                p_time_column            => 'temporal_support',
                p_study_area             => (
                    SELECT geom
                    FROM stcmp_bench_eval.study_area
                    WHERE area_id = 'A_BENCH'
                ),
                p_order_mode             => 'nonoverlapping_ordered'::stcmp_experiment.comparable_order_mode,
                p_group_column           => NULL::name,
                p_min_sequence_length    => 2,
                p_max_sequence_length    => 3,
                p_min_common_area        => 0,
                p_min_elapsed            => NULL::interval,
                p_max_elapsed            => s.max_elapsed,
                p_time_window            => NULL::tstzrange
            ) AS r;

            v_finished := clock_timestamp();
            v_elapsed_ms := EXTRACT(EPOCH FROM (v_finished - v_started)) * 1000.0;

            v_correct :=
                v_pairs = v_expected_pairs
                AND v_triples = v_expected_triples
                AND v_total = v_expected_total
                AND abs(v_area_sum - v_expected_area_sum) <= 0.01;

            INSERT INTO stcmp_bench_eval.runtime_runs(
                batch_id, workload, n_obs, repetition, elapsed_ms,
                actual_pairs, actual_triples, actual_sequences,
                expected_pairs, expected_triples, expected_sequences,
                actual_area_sum, expected_area_sum,
                extension_true_count, is_correct, started_at, finished_at
            )
            VALUES (
                v_batch_id, s.workload, s.n_obs, v_rep, v_elapsed_ms,
                v_pairs, v_triples, v_total,
                v_expected_pairs, v_expected_triples, v_expected_total,
                v_area_sum, v_expected_area_sum,
                v_extension_true, v_correct, v_started, v_finished
            );
        END LOOP;
    END LOOP;
END;
$run_benchmark$;

/*-------------------------- 8. Summary views -------------------------------*/

CREATE VIEW stcmp_bench_eval.v_benchmark_summary AS
SELECT
    r.batch_id,
    r.workload,
    r.n_obs,
    max(r.expected_pairs) AS expected_pairs,
    max(r.expected_triples) AS expected_triples,
    max(r.expected_sequences) AS expected_sequences,
    percentile_cont(0.5) WITHIN GROUP (ORDER BY r.elapsed_ms) AS median_runtime_ms,
    min(r.elapsed_ms) AS min_runtime_ms,
    max(r.elapsed_ms) AS max_runtime_ms,
    avg(r.elapsed_ms) AS mean_runtime_ms,
    max(r.actual_pairs) AS actual_pairs,
    max(r.actual_triples) AS actual_triples,
    max(r.actual_sequences) AS actual_sequences,
    bool_and(r.is_correct) AS all_repetitions_correct,
    count(*) AS measured_repetitions
FROM stcmp_bench_eval.runtime_runs r
GROUP BY r.batch_id, r.workload, r.n_obs;

CREATE VIEW stcmp_bench_eval.v_latest_batch_summary AS
SELECT s.*
FROM stcmp_bench_eval.v_benchmark_summary s
WHERE s.batch_id = (SELECT max(batch_id) FROM stcmp_bench_eval.batches);

/*------------------------ 9. Correctness report ----------------------------*/

SELECT
    workload,
    n_obs,
    actual_pairs,
    expected_pairs,
    actual_triples,
    expected_triples,
    actual_sequences,
    expected_sequences,
    all_repetitions_correct
FROM stcmp_bench_eval.v_latest_batch_summary
ORDER BY workload, n_obs;

/* Any row returned here indicates an output-count/area validation discrepancy. */
SELECT *
FROM stcmp_bench_eval.runtime_runs
WHERE batch_id = (SELECT max(batch_id) FROM stcmp_bench_eval.batches)
  AND NOT is_correct
ORDER BY workload, n_obs, repetition;

/*----------------------- 10. Graph-ready result queries --------------------*/

/* Graph 1: W1 dense workload — X=N observations, Y=median runtime (ms). */
SELECT n_obs, median_runtime_ms, min_runtime_ms, max_runtime_ms, actual_sequences
FROM stcmp_bench_eval.v_latest_batch_summary
WHERE workload = 'W1_DENSE'
ORDER BY n_obs;

/* Graph 2: W2 temporal-selective workload. */
SELECT n_obs, median_runtime_ms, min_runtime_ms, max_runtime_ms, actual_sequences
FROM stcmp_bench_eval.v_latest_batch_summary
WHERE workload = 'W2_TEMPORAL_SELECTIVE'
ORDER BY n_obs;

/* Graph 3: W3 spatial-selective workload. */
SELECT n_obs, median_runtime_ms, min_runtime_ms, max_runtime_ms, actual_sequences
FROM stcmp_bench_eval.v_latest_batch_summary
WHERE workload = 'W3_SPATIAL_SELECTIVE'
ORDER BY n_obs;

/* Combined graph: three workload series on one chart. */
SELECT workload, n_obs, median_runtime_ms, actual_sequences
FROM stcmp_bench_eval.v_latest_batch_summary
ORDER BY workload, n_obs;

/* Raw per-repetition timing data, suitable for error bars / dispersion. */
SELECT
    workload,
    n_obs,
    repetition,
    elapsed_ms,
    actual_sequences,
    is_correct
FROM stcmp_bench_eval.runtime_runs
WHERE batch_id = (SELECT max(batch_id) FROM stcmp_bench_eval.batches)
ORDER BY workload, n_obs, repetition;

/* Expected output cardinalities for the paper's benchmark description. */
SELECT workload, n_obs, expected_pairs, expected_triples, expected_sequences
FROM stcmp_bench_eval.expected_results
ORDER BY workload, n_obs;

/*
  Exporting graph data:
    In pgAdmin/DBeaver: run one of the Graph 1--3 SELECT statements and export
    the result grid as CSV.

    In psql, for example:
      \copy (SELECT n_obs, median_runtime_ms, actual_sequences
             FROM stcmp_bench_eval.v_latest_batch_summary
             WHERE workload='W1_DENSE' ORDER BY n_obs)
      TO 'w1_dense_runtime.csv' CSV HEADER

  Plot recommendations:
    - X-axis: n_obs
    - Y-axis: median_runtime_ms
    - One line per workload for the combined graph
    - Optionally create a separate output-cardinality graph using
      actual_sequences. Do not put runtime and sequence count on the same
      Y-axis because they have different units.

  Interpretation:
    W1 gives a dense, high-output workload.
    W2 isolates temporal selectivity while keeping geometry identical to W1.
    W3 isolates spatial selectivity while retaining permissive temporal order.
    The returned sequence counts are checked against independent formulas.
*/
