/*=============================================================================
  ST_ComparableAreasByTime — revised implementation (v2)

  Main semantic changes from the previous version
  ------------------------------------------------
  1. Every valid sequence is retained, including sequences that have valid
     longer extensions. No prefix-dominance subtraction is performed.
  2. common_support_geom is the complete cumulative polygonal intersection
     of all observations in the sequence.
  3. p_max_sequence_length is added. NULL means no user-imposed maximum.
  4. has_valid_extension indicates whether at least one valid one-observation
     extension exists, even when p_max_sequence_length is set. For this flag,
     the function internally generates one extra level beyond the requested
     maximum, but does not return those extra-level sequences.
  5. Elapsed-time bounds accept fixed intervals made from days, hours,
     minutes, and seconds. Year/month components are intentionally rejected.

  Prerequisites
  -------------
  - PostgreSQL and PostGIS.
  - Schema stcmp_experiment (or adapt the schema name below).
  - The tested helper function:
      stcmp_experiment.st_coverage_profile(
        regclass, name, name, name, geometry, name, tstzrange,
        double precision
      )
  - The experiment fixture views/tables are required only for the sanity
    tests and usage examples at the end of this file.

  Source relation contract
  ------------------------
  - Source columns: unique observation ID, polygonal geometry, and either
    tstzrange or timestamptz temporal support.
  - Known temporal supports must be finite and bounded, represented either as
    a closed singleton [t,t] for an instant or as [start,end) for an interval.
  - NULL temporal support is ignored for sequence generation.
  - The source geometry and study area must use the same projected CRS if
    area values are expected in square metres.

  Semantics
  ---------
  nonoverlapping_ordered:
    For each adjacent pair, the previous range must end no later than the next
    range starts AND the two ranges must not overlap. The second condition is
    important for a closed singleton instant at an interval's inclusive start.
    Elapsed time = lower(next) - upper(previous).

  start_ordered_overlap_allowed:
    Start times must be strictly increasing. Overlap, containment, and
    disjointness are allowed. Elapsed time = lower(next) - lower(previous).

  p_min_elapsed / p_max_elapsed:
    Applied to EVERY adjacent pair. Values are converted to elapsed seconds.
    Days are treated as 24-hour durations; no calendar month/year arithmetic
    is performed. A caller can express days, hours, minutes, seconds, e.g.
    INTERVAL '365 days 6 hours 30 minutes'.

  Common geometry:
    H(q) = intersection of the clipped footprints of every observation in q.
    Each extension intersects the current common geometry with the next
    clipped footprint. Empty or too-small intersections are pruned immediately.

  Sequence generation:
    A breadth-by-length expansion generates all valid ordered subsequences.
    Every candidate is extended by all eligible later observations, not merely
    by the next observation in the globally sorted list. A parent pointer is
    retained so that has_valid_extension can be determined efficiently.

  Performance
  -----------
  - Calls ST_CoverageProfile once per function invocation.
  - Materializes clipped observations once into a temporary relation.
  - Creates temporary B-tree and GiST indexes and ANALYZEs the work relation.
  - Applies temporal eligibility and index-aware spatial predicates before
    calling the exact ST_Intersection.
  - Uses cumulative geometry pruning (area threshold) at every extension.
  - Uses temporary relations only; no persistent graph or result tables.

  Important complexity note
  -------------------------
  Enumerating ALL valid sequences can be exponential in the number of
  observations. Restrict the input relation/view and/or use p_time_window and
  p_max_sequence_length for large sources. No semantic shortcut is applied
  that would silently discard valid shorter or non-prefix sequences.
=============================================================================*/

CREATE SCHEMA IF NOT EXISTS stcmp_experiment;

/* Idempotently install the ordering-mode enum. */
DO $enum$
DECLARE
    v_labels text[];
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        WHERE n.nspname = 'stcmp_experiment'
          AND t.typname = 'comparable_order_mode'
          AND t.typtype = 'e'
    ) THEN
        CREATE TYPE stcmp_experiment.comparable_order_mode AS ENUM (
            'nonoverlapping_ordered',
            'start_ordered_overlap_allowed'
        );
    ELSE
        SELECT array_agg(e.enumlabel::text ORDER BY e.enumsortorder)
          INTO v_labels
        FROM pg_type t
        JOIN pg_namespace n ON n.oid = t.typnamespace
        JOIN pg_enum e ON e.enumtypid = t.oid
        WHERE n.nspname = 'stcmp_experiment'
          AND t.typname = 'comparable_order_mode';

        IF v_labels IS DISTINCT FROM ARRAY[
            'nonoverlapping_ordered',
            'start_ordered_overlap_allowed'
        ]::text[] THEN
            RAISE EXCEPTION
                'stcmp_experiment.comparable_order_mode exists with unexpected labels: %',
                v_labels;
        END IF;
    END IF;
END;
$enum$;

/*
  Drop older overloads of this specifically named experimental operator.
  This is required because the argument list and return shape changed in v2.
*/
DO $drop_old$
DECLARE
    v_signature text;
BEGIN
    FOR v_signature IN
        SELECT p.oid::regprocedure::text
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'stcmp_experiment'
          AND p.proname = 'st_comparable_areas_by_time'
    LOOP
        EXECUTE 'DROP FUNCTION ' || v_signature;
    END LOOP;
END;
$drop_old$;

CREATE FUNCTION stcmp_experiment.st_comparable_areas_by_time(
    p_source                 regclass,
    p_observation_id_column  name,
    p_geom_column            name,
    p_time_column            name,
    p_study_area             geometry,
    p_order_mode             stcmp_experiment.comparable_order_mode,
    p_group_column           name DEFAULT NULL,
    p_min_sequence_length    integer DEFAULT 2,
    p_max_sequence_length    integer DEFAULT NULL,
    p_min_common_area        double precision DEFAULT 0,
    p_min_elapsed            interval DEFAULT NULL,
    p_max_elapsed            interval DEFAULT NULL,
    p_time_window            tstzrange DEFAULT NULL
)
RETURNS TABLE (
    sequence_length       integer,
    observation_sequence  jsonb,
    common_support_geom   geometry,
    common_area           double precision,
    has_valid_extension   boolean
)
LANGUAGE plpgsql
VOLATILE
PARALLEL UNSAFE
SET search_path = pg_catalog, public, stcmp_experiment
AS $function$
DECLARE
    v_obs_table              text;
    v_candidate_table        text;
    v_frontier_table         text;
    v_token                  text;
    v_inserted               bigint;
    v_current_length         integer := 1;
    v_generation_limit       integer;
    v_min_elapsed_seconds    double precision;
    v_max_elapsed_seconds    double precision;
    v_bad_count              bigint;
    v_sql                    text;
    v_coverage_function      regprocedure;
BEGIN
    /*--------------------------- Argument checks ---------------------------*/

    IF p_source IS NULL THEN
        RAISE EXCEPTION 'p_source must identify a source relation'
            USING ERRCODE = '22023';
    END IF;

    IF p_observation_id_column IS NULL
       OR p_geom_column IS NULL
       OR p_time_column IS NULL THEN
        RAISE EXCEPTION
            'Observation ID, geometry, and temporal column names are required'
            USING ERRCODE = '22023';
    END IF;

    IF p_study_area IS NULL OR ST_IsEmpty(p_study_area) THEN
        RAISE EXCEPTION 'p_study_area must be a non-empty geometry'
            USING ERRCODE = '22023';
    END IF;

    IF GeometryType(p_study_area) NOT IN ('POLYGON', 'MULTIPOLYGON') THEN
        RAISE EXCEPTION
            'p_study_area must be POLYGON or MULTIPOLYGON; got %',
            GeometryType(p_study_area)
            USING ERRCODE = '22023';
    END IF;

    IF NOT ST_IsValid(p_study_area) THEN
        RAISE EXCEPTION 'p_study_area must be a valid geometry'
            USING ERRCODE = '22023';
    END IF;

    IF ST_SRID(p_study_area) <= 0 THEN
        RAISE EXCEPTION 'p_study_area must have a defined SRID'
            USING ERRCODE = '22023';
    END IF;

    IF p_order_mode IS NULL THEN
        RAISE EXCEPTION 'p_order_mode is required'
            USING ERRCODE = '22023';
    END IF;

    IF p_min_sequence_length IS NULL OR p_min_sequence_length < 2 THEN
        RAISE EXCEPTION 'p_min_sequence_length must be an integer >= 2'
            USING ERRCODE = '22023';
    END IF;

    IF p_max_sequence_length IS NOT NULL
       AND p_max_sequence_length < p_min_sequence_length THEN
        RAISE EXCEPTION
            'p_max_sequence_length (%) must be >= p_min_sequence_length (%)',
            p_max_sequence_length, p_min_sequence_length
            USING ERRCODE = '22023';
    END IF;

    IF p_max_sequence_length = 2147483647 THEN
        RAISE EXCEPTION
            'p_max_sequence_length must be less than 2147483647 because one extra level is generated to evaluate has_valid_extension'
            USING ERRCODE = '22023';
    END IF;

    IF p_min_common_area IS NULL
       OR p_min_common_area < 0
       OR NOT (p_min_common_area < 'Infinity'::double precision) THEN
        RAISE EXCEPTION
            'p_min_common_area must be a finite, non-negative number'
            USING ERRCODE = '22023';
    END IF;

    IF p_time_window IS NOT NULL AND isempty(p_time_window) THEN
        RAISE EXCEPTION 'p_time_window must not be an empty range'
            USING ERRCODE = '22023';
    END IF;

    /*---------------- Fixed-duration interval validation ------------------*/

    IF p_min_elapsed IS NOT NULL THEN
        IF NOT isfinite(p_min_elapsed) OR p_min_elapsed < INTERVAL '0'
           OR EXTRACT(YEAR FROM p_min_elapsed) <> 0
           OR EXTRACT(MONTH FROM p_min_elapsed) <> 0 THEN
            RAISE EXCEPTION
                'p_min_elapsed must be a finite, non-negative fixed duration without year/month components'
                USING ERRCODE = '22023';
        END IF;
        v_min_elapsed_seconds := EXTRACT(EPOCH FROM p_min_elapsed)::double precision;
    ELSE
        v_min_elapsed_seconds := NULL;
    END IF;

    IF p_max_elapsed IS NOT NULL THEN
        IF NOT isfinite(p_max_elapsed) OR p_max_elapsed < INTERVAL '0'
           OR EXTRACT(YEAR FROM p_max_elapsed) <> 0
           OR EXTRACT(MONTH FROM p_max_elapsed) <> 0 THEN
            RAISE EXCEPTION
                'p_max_elapsed must be a finite, non-negative fixed duration without year/month components'
                USING ERRCODE = '22023';
        END IF;
        v_max_elapsed_seconds := EXTRACT(EPOCH FROM p_max_elapsed)::double precision;
    ELSE
        v_max_elapsed_seconds := NULL;
    END IF;

    IF v_min_elapsed_seconds IS NOT NULL
       AND v_max_elapsed_seconds IS NOT NULL
       AND v_min_elapsed_seconds > v_max_elapsed_seconds THEN
        RAISE EXCEPTION
            'p_min_elapsed must be <= p_max_elapsed'
            USING ERRCODE = '22023';
    END IF;

    /*--------------------------- Prerequisites -----------------------------*/

    v_coverage_function := to_regprocedure(
        'stcmp_experiment.st_coverage_profile(regclass,name,name,name,geometry,name,tstzrange,double precision)'
    );

    IF v_coverage_function IS NULL THEN
        RAISE EXCEPTION
            'Required helper stcmp_experiment.st_coverage_profile(...) is not installed'
            USING ERRCODE = '42883';
    END IF;

    /*---------------------- Unique temporary names -------------------------*/

    v_token := substr(
        md5(clock_timestamp()::text || random()::text || pg_backend_pid()::text),
        1, 16
    );
    v_obs_table       := 'stcb_obs_' || v_token;
    v_candidate_table := 'stcb_candidates_' || v_token;
    v_frontier_table  := 'stcb_frontier_' || v_token;

    /*
      Generate sequences one level beyond p_max_sequence_length solely to
      compute has_valid_extension for sequences at the requested maximum.
      These probe sequences will be excluded from the returned rows.
    */
    IF p_max_sequence_length IS NULL THEN
        v_generation_limit := NULL;
    ELSE
        v_generation_limit := p_max_sequence_length + 1;
    END IF;

    /*---------------- Materialize clipped known-time observations ----------*/

    v_sql := format($sql$
        CREATE TEMP TABLE %1$I ON COMMIT DROP AS
        SELECT
            ROW_NUMBER() OVER (
                ORDER BY lower(cp.temporal_support),
                         upper(cp.temporal_support),
                         cp.observation_id
            )::integer AS obs_ord,
            cp.observation_id,
            cp.group_id,
            cp.temporal_support,
            lower(cp.temporal_support) AS start_time,
            upper(cp.temporal_support) AS end_time,
            cp.support_geom
        FROM stcmp_experiment.st_coverage_profile(
            $1, $2, $3, $4, $5, $6, $7, $8
        ) AS cp
        WHERE cp.temporal_support IS NOT NULL
    $sql$, v_obs_table);

    EXECUTE v_sql
    USING
        p_source,
        p_observation_id_column,
        p_geom_column,
        p_time_column,
        p_study_area,
        p_group_column,
        p_time_window,
        p_min_common_area;

    /* Unique, non-NULL IDs are needed to identify an observation sequence. */
    EXECUTE format($sql$
        SELECT count(*)
        FROM (
            SELECT observation_id
            FROM pg_temp.%1$I
            GROUP BY observation_id
            HAVING observation_id IS NULL OR count(*) > 1
        ) AS duplicates
    $sql$, v_obs_table)
    INTO v_bad_count;

    IF v_bad_count > 0 THEN
        RAISE EXCEPTION
            'The clipped source contains % NULL or duplicate observation IDs; observation IDs must be non-NULL and unique',
            v_bad_count
            USING ERRCODE = '22023';
    END IF;

    /* Enforce the temporal-support conventions used by this operator. */
    EXECUTE format($sql$
        SELECT count(*)
        FROM pg_temp.%1$I
        WHERE isempty(temporal_support)
           OR lower_inf(temporal_support)
           OR upper_inf(temporal_support)
           OR NOT isfinite(start_time)
           OR NOT isfinite(end_time)
           OR NOT (
                (start_time = end_time
                 AND lower_inc(temporal_support)
                 AND upper_inc(temporal_support))
                OR
                (start_time < end_time
                 AND lower_inc(temporal_support)
                 AND NOT upper_inc(temporal_support))
           )
    $sql$, v_obs_table)
    INTO v_bad_count;

    IF v_bad_count > 0 THEN
        RAISE EXCEPTION
            'The source contains % unsupported temporal supports. Use finite closed singleton ranges [t,t] for instants or lower-inclusive/upper-exclusive ranges [start,end) for intervals.',
            v_bad_count
            USING ERRCODE = '22023';
    END IF;

    /* Temporary indexes support indexed spatial candidate lookup. */
    EXECUTE format(
        'CREATE INDEX %I ON pg_temp.%I (obs_ord)',
        v_obs_table || '_ord_idx', v_obs_table
    );
    EXECUTE format(
        'CREATE INDEX %I ON pg_temp.%I USING GIST (support_geom)',
        v_obs_table || '_geom_gix', v_obs_table
    );
    EXECUTE format('ANALYZE pg_temp.%I', v_obs_table);

    /*------------------------ Candidate work relation ----------------------*/

    EXECUTE format($sql$
        CREATE TEMP TABLE %1$I (
            candidate_id             bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
            parent_candidate_id      bigint,
            sequence_length          integer NOT NULL,
            last_obs_ord             integer NOT NULL,
            observation_ordinals    integer[] NOT NULL,
            last_temporal_support    tstzrange NOT NULL,
            common_support_geom      geometry NOT NULL,
            common_area              double precision NOT NULL
        ) ON COMMIT DROP
    $sql$, v_candidate_table);

    EXECUTE format(
        'CREATE INDEX %I ON pg_temp.%I (parent_candidate_id)',
        v_candidate_table || '_parent_idx', v_candidate_table
    );

    /*
      A separate frontier stores only the candidates at the current sequence
      length. This avoids rescanning/index-filtering the full candidate history
      at every expansion level.
    */
    EXECUTE format($sql$
        CREATE TEMP TABLE %1$I (
            candidate_id    bigint PRIMARY KEY,
            sequence_length integer NOT NULL
        ) ON COMMIT DROP
    $sql$, v_frontier_table);
    EXECUTE format(
        'CREATE INDEX %I ON pg_temp.%I (sequence_length)',
        v_frontier_table || '_stage_idx', v_frontier_table
    );

    /* Seed length-one candidates from the clipped observation footprints. */
    EXECUTE format($sql$
        INSERT INTO pg_temp.%1$I (
            parent_candidate_id,
            sequence_length,
            last_obs_ord,
            observation_ordinals,
            last_temporal_support,
            common_support_geom,
            common_area
        )
        SELECT
            NULL,
            1,
            o.obs_ord,
            ARRAY[o.obs_ord],
            o.temporal_support,
            o.support_geom,
            ST_Area(o.support_geom)
        FROM pg_temp.%2$I AS o
        WHERE ST_Area(o.support_geom) > $1
    $sql$, v_candidate_table, v_obs_table)
    USING p_min_common_area;

    EXECUTE format($sql$
        INSERT INTO pg_temp.%1$I (candidate_id, sequence_length)
        SELECT candidate_id, sequence_length
        FROM pg_temp.%2$I
        WHERE sequence_length = 1
    $sql$, v_frontier_table, v_candidate_table);
    EXECUTE format('ANALYZE pg_temp.%I', v_frontier_table);

    /*
      Expand only the current frontier by every eligible later observation.
      A separate frontier prevents each generation from scanning all earlier
      sequence levels. The exact intersection is evaluated only after temporal,
      bounding-box, and exact-intersects filters have passed.
    */
    LOOP
        IF v_generation_limit IS NOT NULL
           AND v_current_length >= v_generation_limit THEN
            EXIT;
        END IF;

        v_sql := format($sql$
            WITH inserted_candidates AS (
                INSERT INTO pg_temp.%1$I (
                    parent_candidate_id,
                    sequence_length,
                    last_obs_ord,
                    observation_ordinals,
                    last_temporal_support,
                    common_support_geom,
                    common_area
                )
                SELECT
                    c.candidate_id,
                    c.sequence_length + 1,
                    o.obs_ord,
                    c.observation_ordinals || o.obs_ord,
                    o.temporal_support,
                    ix.geom,
                    ST_Area(ix.geom)
                FROM pg_temp.%2$I AS f
                JOIN pg_temp.%1$I AS c
                  ON c.candidate_id = f.candidate_id
                JOIN pg_temp.%3$I AS o
                  ON o.obs_ord > c.last_obs_ord
                 AND (
                        (
                            $1 = 'nonoverlapping_ordered'::stcmp_experiment.comparable_order_mode
                            AND upper(c.last_temporal_support) <= lower(o.temporal_support)
                            AND NOT (c.last_temporal_support && o.temporal_support)
                        )
                        OR
                        (
                            $1 = 'start_ordered_overlap_allowed'::stcmp_experiment.comparable_order_mode
                            AND lower(c.last_temporal_support) < lower(o.temporal_support)
                        )
                     )
                 AND o.support_geom && c.common_support_geom
                 AND ST_Intersects(o.support_geom, c.common_support_geom)
                CROSS JOIN LATERAL (
                    SELECT ST_Multi(
                        ST_CollectionExtract(
                            ST_Intersection(c.common_support_geom, o.support_geom),
                            3
                        )
                    ) AS geom
                ) AS ix
                CROSS JOIN LATERAL (
                    SELECT CASE
                        WHEN $1 = 'nonoverlapping_ordered'::stcmp_experiment.comparable_order_mode
                        THEN EXTRACT(EPOCH FROM (
                            lower(o.temporal_support) - upper(c.last_temporal_support)
                        ))::double precision
                        ELSE EXTRACT(EPOCH FROM (
                            lower(o.temporal_support) - lower(c.last_temporal_support)
                        ))::double precision
                    END AS elapsed_seconds
                ) AS elapsed
                WHERE f.sequence_length = $2
                  AND NOT ST_IsEmpty(ix.geom)
                  AND ST_Area(ix.geom) > $3
                  AND ($4 IS NULL OR elapsed.elapsed_seconds >= $4)
                  AND ($5 IS NULL OR elapsed.elapsed_seconds <= $5)
                RETURNING candidate_id, sequence_length
            )
            INSERT INTO pg_temp.%2$I (candidate_id, sequence_length)
            SELECT candidate_id, sequence_length
            FROM inserted_candidates
        $sql$, v_candidate_table, v_frontier_table, v_obs_table);

        EXECUTE v_sql
        USING
            p_order_mode,
            v_current_length,
            p_min_common_area,
            v_min_elapsed_seconds,
            v_max_elapsed_seconds;

        GET DIAGNOSTICS v_inserted = ROW_COUNT;
        EXIT WHEN v_inserted = 0;

        /* Remove the just-expanded parents; frontier now contains only children. */
        EXECUTE format(
            'DELETE FROM pg_temp.%I WHERE sequence_length = $1',
            v_frontier_table
        ) USING v_current_length;
        EXECUTE format('ANALYZE pg_temp.%I', v_frontier_table);

        v_current_length := v_current_length + 1;
    END LOOP;

    /* Planner statistics for the candidate relation. */
    EXECUTE format('ANALYZE pg_temp.%I', v_candidate_table);

    /*------------------------------ Results --------------------------------*/

    /*
      observation_sequence is a JSON array in temporal sequence order.
      group_id is included as metadata (or JSON null when p_group_column is
      NULL); it never imposes a group-uniqueness restriction in this operator.
    */
    v_sql := format($sql$
        SELECT
            c.sequence_length,
            seq.observation_sequence,
            c.common_support_geom,
            c.common_area,
            EXISTS (
                SELECT 1
                FROM pg_temp.%1$I AS child
                WHERE child.parent_candidate_id = c.candidate_id
                  AND child.sequence_length = c.sequence_length + 1
            ) AS has_valid_extension
        FROM pg_temp.%1$I AS c
        CROSS JOIN LATERAL (
            SELECT jsonb_agg(
                jsonb_build_object(
                    'position', s.position,
                    'observation_id', o.observation_id,
                    'group_id', o.group_id,
                    'temporal_support', jsonb_build_object(
                        'kind', CASE
                            WHEN lower(o.temporal_support) = upper(o.temporal_support)
                                THEN 'instant'
                            ELSE 'interval'
                        END,
                        'start', lower(o.temporal_support),
                        'end', upper(o.temporal_support),
                        'lower_inclusive', lower_inc(o.temporal_support),
                        'upper_inclusive', upper_inc(o.temporal_support)
                    )
                )
                ORDER BY s.position
            ) AS observation_sequence
            FROM unnest(c.observation_ordinals)
                 WITH ORDINALITY AS s(obs_ord, position)
            JOIN pg_temp.%2$I AS o
              ON o.obs_ord = s.obs_ord
        ) AS seq
        WHERE c.sequence_length >= $1
          AND ($2 IS NULL OR c.sequence_length <= $2)
        ORDER BY c.sequence_length, c.candidate_id
    $sql$, v_candidate_table, v_obs_table);

    RETURN QUERY EXECUTE v_sql
    USING p_min_sequence_length, p_max_sequence_length;

    /* Explicit cleanup allows repeated calls in the same transaction/session. */
    EXECUTE format(
        'DROP TABLE IF EXISTS pg_temp.%I, pg_temp.%I, pg_temp.%I',
        v_candidate_table, v_frontier_table, v_obs_table
    );

    RETURN;
END;
$function$;

COMMENT ON FUNCTION stcmp_experiment.st_comparable_areas_by_time(
    regclass, name, name, name, geometry,
    stcmp_experiment.comparable_order_mode,
    name, integer, integer, double precision, interval, interval, tstzrange
) IS
'Returns every valid temporally ordered observation sequence and its complete cumulative common polygonal support. Does not remove shorter prefix sequences. p_max_sequence_length optionally limits returned lengths; has_valid_extension reports whether a valid one-step extension exists, including beyond the requested maximum.';

/*=============================================================================
  SANITY TESTS

  Prerequisites for this section:
    - Run st_comparableareas_experiment_setup.sql
    - Run st_coverage_profile_implementation_tests.sql
    - Install this function file

  Each DO block raises an exception on failure. The final SELECT prints a
  success marker only if every assertion has completed successfully.
=============================================================================*/

/* Test 1 — A shorter sequence and its longer extension are BOTH returned. */
DO $test$
DECLARE
    v_short_area double precision;
    v_long_area  double precision;
    v_short_count integer;
    v_long_count integer;
BEGIN
    SELECT count(*), max(common_area)
      INTO v_short_count, v_short_area
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 4, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18'
      AND r.sequence_length = 2;

    SELECT count(*), max(common_area)
      INTO v_long_count, v_long_area
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 4, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18'
      AND r.observation_sequence -> 2 ->> 'observation_id' = 'O20'
      AND r.sequence_length = 3;

    IF v_short_count <> 1 OR v_long_count <> 1
       OR abs(v_short_area - 20000.0) > 0.01
       OR abs(v_long_area - 20000.0) > 0.01 THEN
        RAISE EXCEPTION
            'Test 1 failed: short count/area %, %, long count/area %, %',
            v_short_count, v_short_area, v_long_count, v_long_area;
    END IF;
END;
$test$;

/* Test 2 — has_valid_extension is TRUE for O17->O18 and FALSE for O18->O20. */
DO $test$
DECLARE
    v_short_extension boolean;
    v_terminal_extension boolean;
BEGIN
    SELECT has_valid_extension
      INTO v_short_extension
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 4, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18';

    SELECT has_valid_extension
      INTO v_terminal_extension
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 4, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O18'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O20';

    IF v_short_extension IS DISTINCT FROM TRUE
       OR v_terminal_extension IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION
            'Test 2 failed: O17->O18 extension %, O18->O20 extension %',
            v_short_extension, v_terminal_extension;
    END IF;
END;
$test$;

/* Test 3 — p_max_sequence_length caps outputs, but extension flag probes +1. */
DO $test$
DECLARE
    v_max_length integer;
    v_extension boolean;
BEGIN
    SELECT max(sequence_length)
      INTO v_max_length
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, INTERVAL '1100 days', NULL
    );

    SELECT has_valid_extension
      INTO v_extension
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18';

    IF v_max_length <> 2 OR v_extension IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION
            'Test 3 failed: max returned length %, valid extension flag %',
            v_max_length, v_extension;
    END IF;
END;
$test$;

/* Test 4 — minimum sequence length is respected. */
DO $test$
DECLARE
    v_count bigint;
    v_min_length integer;
    v_max_length integer;
BEGIN
    SELECT count(*), min(sequence_length), max(sequence_length)
      INTO v_count, v_min_length, v_max_length
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 3, 3, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r;

    IF v_count = 0 OR v_min_length <> 3 OR v_max_length <> 3 THEN
        RAISE EXCEPTION
            'Test 4 failed: expected non-empty results of length exactly 3; count %, min %, max %',
            v_count, v_min_length, v_max_length;
    END IF;
END;
$test$;

/* Test 5 — ByTime allows two observations from the same group. */
DO $test$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*)
      INTO v_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 3, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O15'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O15_ALT';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Test 5 failed: expected O15->O15_ALT despite shared group; got %',
            v_count;
    END IF;
END;
$test$;

/* Test 6 — min elapsed applies to every adjacent pair. */
DO $test$
DECLARE
    v_short_gap_count bigint;
    v_valid_pair_count bigint;
BEGIN
    SELECT count(*)
      INTO v_short_gap_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 4, 0,
        INTERVAL '365 days', INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'O15'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O15_ALT';

    SELECT count(*)
      INTO v_valid_pair_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 3, 0,
        INTERVAL '365 days', INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18';

    IF v_short_gap_count <> 0 OR v_valid_pair_count <> 1 THEN
        RAISE EXCEPTION
            'Test 6 failed: short-gap sequence count %, valid O17->O18 count %',
            v_short_gap_count, v_valid_pair_count;
    END IF;
END;
$test$;

/* Test 7 — Full cumulative intersection rejects a pairwise-overlap chain. */
DO $test$
DECLARE
    v_ab_count bigint;
    v_bc_count bigint;
    v_abc_count bigint;
BEGIN
    SELECT count(*) INTO v_ab_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_spatial_chain'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 3, 0,
        NULL, INTERVAL '800 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'CHAIN_A'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'CHAIN_B';

    SELECT count(*) INTO v_bc_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_spatial_chain'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 3, 0,
        NULL, INTERVAL '800 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'CHAIN_B'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'CHAIN_C';

    SELECT count(*) INTO v_abc_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_spatial_chain'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 3, 0,
        NULL, INTERVAL '800 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'CHAIN_A'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'CHAIN_B'
      AND r.observation_sequence -> 2 ->> 'observation_id' = 'CHAIN_C';

    IF v_ab_count <> 1 OR v_bc_count <> 1 OR v_abc_count <> 0 THEN
        RAISE EXCEPTION
            'Test 7 failed: A-B %, B-C %, A-B-C %',
            v_ab_count, v_bc_count, v_abc_count;
    END IF;
END;
$test$;

/* Test 8 — Nonoverlapping mode rejects an instant followed by an interval
   whose inclusive lower bound is that same instant. This specifically tests
   the explicit NOT (previous_range && next_range) condition. */
DO $test$
DECLARE
    v_bad_count bigint;
BEGIN
    SELECT count(*)
      INTO v_bad_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_temporal_edge_cases'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', NULL, 2, 3, 0,
        NULL, INTERVAL '3 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'T_I_AT_START'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'T_INTERVAL_1';

    IF v_bad_count <> 0 THEN
        RAISE EXCEPTION
            'Test 8 failed: instant at inclusive interval start was treated as non-overlapping';
    END IF;
END;
$test$;

/* Test 9 — Nonoverlapping mode accepts an interval followed by an instant at its exclusive end. */
DO $test$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*)
      INTO v_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_temporal_edge_cases'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', NULL, 2, 3, 0,
        NULL, INTERVAL '3 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'T_INTERVAL_1'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'T_I_AT_END';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Test 9 failed: touching interval/instant pair should be accepted';
    END IF;
END;
$test$;

/* Test 10 — Start-ordered mode allows overlap and containment. */
DO $test$
DECLARE
    v_overlap_count bigint;
    v_containment_count bigint;
BEGIN
    SELECT count(*) INTO v_overlap_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_temporal_edge_cases'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'start_ordered_overlap_allowed', NULL, 2, 2, 0,
        NULL, INTERVAL '10 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'T_OVERLAP_1'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'T_OVERLAP_2';

    SELECT count(*) INTO v_containment_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_temporal_edge_cases'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'start_ordered_overlap_allowed', NULL, 2, 2, 0,
        NULL, INTERVAL '10 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'T_OUTER'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'T_INNER';

    IF v_overlap_count <> 1 OR v_containment_count <> 1 THEN
        RAISE EXCEPTION
            'Test 10 failed: overlap pair %, containment pair %',
            v_overlap_count, v_containment_count;
    END IF;
END;
$test$;

/* Test 11 — Start-ordered mode rejects equal start times in either order. */
DO $test$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*) INTO v_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_temporal_edge_cases'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'start_ordered_overlap_allowed', NULL, 2, 2, 0,
        NULL, INTERVAL '10 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id'
            IN ('T_EQUAL_START_1', 'T_EQUAL_START_2')
      AND r.observation_sequence -> 1 ->> 'observation_id'
            IN ('T_EQUAL_START_1', 'T_EQUAL_START_2');

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'Test 11 failed: equal-start observations were incorrectly ordered';
    END IF;
END;
$test$;

/* Test 12 — Multi-granularity fixed elapsed intervals are accepted. */
DO $test$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*)
      INTO v_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', NULL, 2, 2, 0,
        INTERVAL '1 day 2 hours 3 minutes 4 seconds',
        INTERVAL '1100 days 6 hours 30 minutes',
        NULL
    );

    IF v_count = 0 THEN
        RAISE EXCEPTION
            'Test 12 failed: supported day/hour/minute/second interval expression returned no sequences';
    END IF;
END;
$test$;

/* Test 13 — Calendar month/year intervals are rejected deliberately. */
DO $test$
DECLARE
    v_raised boolean := false;
BEGIN
    BEGIN
        PERFORM 1
        FROM stcmp_experiment.st_comparable_areas_by_time(
            'stcmp_experiment.v_main_sequence'::regclass,
            'observation_id', 'geom', 'temporal_support',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
            'nonoverlapping_ordered', NULL, 2, 2, 0,
            INTERVAL '1 year', NULL, NULL
        );
    EXCEPTION WHEN invalid_parameter_value THEN
        v_raised := true;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION
            'Test 13 failed: calendar year interval should be rejected';
    END IF;
END;
$test$;

/* Test 14 — No output sequence exceeds the specified maximum. */
DO $test$
DECLARE
    v_bad_count bigint;
BEGIN
    SELECT count(*)
      INTO v_bad_count
    FROM stcmp_experiment.st_comparable_areas_by_time(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', NULL, 2, 3, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length > 3;

    IF v_bad_count <> 0 THEN
        RAISE EXCEPTION
            'Test 14 failed: returned % sequences longer than max length 3',
            v_bad_count;
    END IF;
END;
$test$;

SELECT 'ST_ComparableAreasByTime v2: all 14 sanity tests passed' AS test_status;

/*=============================================================================
  DIRECT USAGE EXAMPLES

  Run these independently after installation. The examples call the function
  directly; they do NOT depend on pg_temp test tables.
=============================================================================*/

/* Example 1 — All valid sequences, no maximum length. */
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                 => 'stcmp_experiment.v_main_sequence'::regclass,
    p_observation_id_column  => 'observation_id',
    p_geom_column            => 'geom',
    p_time_column            => 'temporal_support',
    p_study_area             => (
        SELECT geom
        FROM stcmp_experiment.study_area
        WHERE area_id = 'A'
    ),
    p_order_mode             => 'nonoverlapping_ordered',
    p_group_column           => 'group_id',
    p_min_sequence_length    => 2,
    p_max_sequence_length    => NULL,
    p_min_common_area        => 0,
    p_min_elapsed            => NULL,
    p_max_elapsed            => INTERVAL '1100 days',
    p_time_window            => NULL
) AS r
ORDER BY r.sequence_length, r.observation_sequence::text;

/* Example 2 — Return only sequences of length 2 to 4. */
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                 => 'stcmp_experiment.v_main_sequence'::regclass,
    p_observation_id_column  => 'observation_id',
    p_geom_column            => 'geom',
    p_time_column            => 'temporal_support',
    p_study_area             => (
        SELECT geom
        FROM stcmp_experiment.study_area
        WHERE area_id = 'A'
    ),
    p_order_mode             => 'nonoverlapping_ordered',
    p_group_column           => 'group_id',
    p_min_sequence_length    => 2,
    p_max_sequence_length    => 4,
    p_min_common_area        => 1000,
    p_min_elapsed            => INTERVAL '365 days 6 hours',
    p_max_elapsed            => INTERVAL '1100 days',
    p_time_window            => NULL
) AS r
ORDER BY r.sequence_length, r.observation_sequence::text;

/* Example 3 — QGIS-friendly result shape (native PostGIS geometry). */
SELECT
    ROW_NUMBER() OVER (
        ORDER BY r.sequence_length, r.observation_sequence::text
    ) AS seq_id,
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom AS geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                 => 'stcmp_experiment.v_main_sequence'::regclass,
    p_observation_id_column  => 'observation_id',
    p_geom_column            => 'geom',
    p_time_column            => 'temporal_support',
    p_study_area             => (
        SELECT geom
        FROM stcmp_experiment.study_area
        WHERE area_id = 'A'
    ),
    p_order_mode             => 'nonoverlapping_ordered',
    p_group_column           => 'group_id',
    p_min_sequence_length    => 2,
    p_max_sequence_length    => 4,
    p_min_common_area        => 0,
    p_min_elapsed            => NULL,
    p_max_elapsed            => INTERVAL '1100 days',
    p_time_window            => NULL
) AS r
ORDER BY r.sequence_length, r.observation_sequence::text;

/* Example 4 — Persist the result for later use in QGIS or other queries.
   Adapt the target schema/table name and source parameters as required.

CREATE TABLE your_schema.comparable_areas_run_01 AS
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom AS geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                 => 'your_schema.your_observation_view'::regclass,
    p_observation_id_column  => 'observation_id',
    p_geom_column            => 'geom',
    p_time_column            => 'temporal_support',
    p_study_area             => (
        SELECT geom
        FROM your_schema.study_areas
        WHERE study_area_id = 'YOUR_AREA_ID'
    ),
    p_order_mode             => 'nonoverlapping_ordered',
    p_group_column           => 'campaign_id',
    p_min_sequence_length    => 2,
    p_max_sequence_length    => 5,
    p_min_common_area        => 1000,
    p_min_elapsed            => INTERVAL '30 days 4 hours',
    p_max_elapsed            => INTERVAL '1825 days',
    p_time_window            => NULL
) AS r;

CREATE INDEX comparable_areas_run_01_geom_gix
    ON your_schema.comparable_areas_run_01 USING GIST (geom);
ANALYZE your_schema.comparable_areas_run_01;
*/
