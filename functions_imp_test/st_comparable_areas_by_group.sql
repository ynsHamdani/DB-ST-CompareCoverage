/*=============================================================================
  ST_ComparableAreasByGroup — group-unique spatiotemporal sequence operator

  Purpose
  -------
  Returns every valid temporally ordered observation sequence in which each
  observation belongs to a DIFFERENT group. Unlike ST_ComparableAreasByTime,
  this operator never permits two observations with the same group_id in one
  sequence. Different observations from the same group remain available as
  alternative members of different candidate sequences.

  Main semantics
  --------------
  - Same temporal ordering modes as ST_ComparableAreasByTime:
      nonoverlapping_ordered
      start_ordered_overlap_allowed
  - Same per-adjacent-pair elapsed-time bounds.
  - Same cumulative common-support geometry: intersection of every clipped
    observation footprint in the sequence.
  - Every valid sequence is retained. No prefix-dominance subtraction occurs.
  - p_min_sequence_length and optional p_max_sequence_length control returned
    sequence lengths.
  - has_valid_extension means at least one valid next observation can be
    appended while satisfying temporal, spatial, elapsed-time, AND group
    uniqueness constraints. One internal probe level is generated beyond the
    requested maximum where necessary.

  Group semantics
  ---------------
  - p_group_column is REQUIRED.
  - A NULL or blank group identifier among the spatially clipped, temporally
    known observations is an error. The function does not invent a group for
    an observation with unknown group membership.
  - Group identifiers are compared as text exactly as returned by
    ST_CoverageProfile; no trimming, case folding, or normalization is done.
  - Group acquisition periods are metadata only. Temporal ordering is always
    derived from each observation's own temporal_support.
  - A group may contribute different observations to different result
    sequences, but at most one observation from that group may occur in any
    individual sequence.

  Efficient implementation
  ------------------------
  - Calls ST_CoverageProfile once and materializes clipped observations.
  - Assigns compact integer group ordinals with DENSE_RANK, so candidate
    sequences track used groups as integer arrays rather than repeating long
    text identifiers.
  - Rejects a repeated group during candidate expansion, before exact spatial
    intersection is evaluated.
  - Creates temporary B-tree/GiST indexes and ANALYZEs work relations.
  - Expands only the current length frontier, not the complete candidate set.
  - Uses bounding-box and exact-intersection prefilters before ST_Intersection.
  - Bounds the maximum generation depth by the number of distinct groups.
  - Uses uniquely named temporary relations, cleaned up on successful return.
  - Does not create a persistent graph or any permanent result table.

  Prerequisites
  -------------
  - PostgreSQL and PostGIS.
  - stcmp_experiment.comparable_order_mode enum (installed below if absent).
  - stcmp_experiment.st_coverage_profile(...) helper.
  - Fixture objects in stcmp_experiment are needed only for the sanity tests
    and direct usage examples at the end of this file.

  Temporal support contract
  -------------------------
  - tstzrange supports closed singleton [t,t] instants and [start,end)
    intervals only; all endpoints must be finite and bounded.
  - NULL temporal support is excluded from sequence generation.
  - Timestamp columns are normalized by ST_CoverageProfile into singleton
    ranges. timestamp without time zone requires prior explicit timezone
    normalization in a source view.
  - p_min_elapsed/p_max_elapsed accept fixed day/hour/minute/second durations.
    Calendar years/months are deliberately rejected. A day is 24 hours.

  Complexity
  ----------
  Enumerating all group-unique sequences can still be exponential. Use a
  selective source view, p_time_window, p_min_common_area, and/or
  p_max_sequence_length for large datasets. The algorithm does not discard
  valid shorter sequences or alternative observations from the same group.
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
          AND p.proname = 'st_comparable_areas_by_group'
    LOOP
        EXECUTE 'DROP FUNCTION ' || v_signature;
    END LOOP;
END;
$drop_old$;

CREATE FUNCTION stcmp_experiment.st_comparable_areas_by_group(
    p_source                 regclass,
    p_observation_id_column  name,
    p_geom_column            name,
    p_time_column            name,
    p_study_area             geometry,
    p_order_mode             stcmp_experiment.comparable_order_mode,
    p_group_column           name,
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
    v_distinct_group_count   bigint;
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

    IF p_group_column IS NULL THEN
        RAISE EXCEPTION
            'p_group_column is required for ST_ComparableAreasByGroup'
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

    /* The effective generation limit is set after counting distinct groups. */

    /*---------------- Materialize clipped known-time observations ----------*/

    v_sql := format($sql$
        CREATE TEMP TABLE %1$I ON COMMIT DROP AS
        SELECT
            ROW_NUMBER() OVER (
                ORDER BY lower(cp.temporal_support),
                         upper(cp.temporal_support),
                         cp.observation_id
            )::integer AS obs_ord,
            DENSE_RANK() OVER (ORDER BY cp.group_id COLLATE "C")::integer AS group_ord,
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

    /* Group uniqueness cannot be evaluated with missing/blank identifiers. */
    EXECUTE format($sql$
        SELECT count(*)
        FROM pg_temp.%1$I
        WHERE group_id IS NULL OR btrim(group_id) = ''
    $sql$, v_obs_table)
    INTO v_bad_count;

    IF v_bad_count > 0 THEN
        RAISE EXCEPTION
            'The clipped source contains % observations with NULL or blank group identifiers; ST_ComparableAreasByGroup requires a group for every eligible observation',
            v_bad_count
            USING ERRCODE = '22023';
    END IF;

    EXECUTE format(
        'SELECT count(DISTINCT group_id COLLATE "C") FROM pg_temp.%I',
        v_obs_table
    )
    INTO v_distinct_group_count;

    /*
      No sequence can contain more observations than there are distinct
      groups. If a user maximum is supplied, generate one additional level
      only when the group count permits it, for has_valid_extension.
    */
    IF p_max_sequence_length IS NULL THEN
        v_generation_limit := v_distinct_group_count::integer;
    ELSE
        v_generation_limit := LEAST(
            p_max_sequence_length + 1,
            v_distinct_group_count::integer
        );
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
            used_group_ordinals     integer[] NOT NULL,
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
            used_group_ordinals,
            last_temporal_support,
            common_support_geom,
            common_area
        )
        SELECT
            NULL,
            1,
            o.obs_ord,
            ARRAY[o.obs_ord],
            ARRAY[o.group_ord],
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
                    used_group_ordinals,
                    last_temporal_support,
                    common_support_geom,
                    common_area
                )
                SELECT
                    c.candidate_id,
                    c.sequence_length + 1,
                    o.obs_ord,
                    c.observation_ordinals || o.obs_ord,
                    c.used_group_ordinals || o.group_ord,
                    o.temporal_support,
                    ix.geom,
                    ST_Area(ix.geom)
                FROM pg_temp.%2$I AS f
                JOIN pg_temp.%1$I AS c
                  ON c.candidate_id = f.candidate_id
                JOIN pg_temp.%3$I AS o
                  ON o.obs_ord > c.last_obs_ord
                 /* Group uniqueness is checked before spatial intersection. */
                 AND NOT (o.group_ord = ANY(c.used_group_ordinals))
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
      Every entry includes its non-NULL group_id. Group uniqueness has already
      been enforced during candidate expansion.
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

COMMENT ON FUNCTION stcmp_experiment.st_comparable_areas_by_group(
    regclass, name, name, name, geometry,
    stcmp_experiment.comparable_order_mode,
    name, integer, integer, double precision, interval, interval, tstzrange
) IS
'Returns every valid temporally ordered observation sequence with at most one observation per group, together with its complete cumulative common polygonal support. Does not remove shorter prefix sequences. p_max_sequence_length optionally limits returned lengths; has_valid_extension includes temporal, spatial, elapsed-time, and group-uniqueness checks, including beyond the requested maximum.';

/*=============================================================================
  SANITY CHECKS

  Required before running this section:
    1. st_comparableareas_experiment_setup.sql
    2. st_coverage_profile_implementation_tests.sql
    3. This function installation section

  The fixture's main view deliberately contains O15 and O15_ALT in the same
  group. These tests verify that they can be alternatives across different
  sequences, but can never occur together inside one sequence.
=============================================================================*/

/* A grouped copy of selected temporal edge cases lets the tests exercise
   temporal modes while giving each temporal observation a distinct group. */
CREATE OR REPLACE TEMP VIEW stcbg_temporal_grouped AS
SELECT
    observation_id,
    observation_id::text AS test_group_id,
    geom,
    temporal_support
FROM stcmp_experiment.v_temporal_edge_cases
WHERE observation_id IN (
    'T_INTERVAL_1', 'T_I_AT_START', 'T_I_AT_END',
    'T_OVERLAP_1', 'T_OVERLAP_2',
    'T_OUTER', 'T_INNER',
    'T_EQUAL_START_1', 'T_EQUAL_START_2'
);

/* A -> B -> A chronological pattern: ByGroups must reject the third member. */
CREATE OR REPLACE TEMP VIEW stcbg_extension_group_test AS
SELECT
    'C_PAST'::text AS observation_id,
    'GROUP_C'::text AS group_id,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)) AS geom,
    tstzrange('2019-01-01 00:00:00+00', '2019-01-01 00:00:00+00', '[]') AS temporal_support
UNION ALL
SELECT
    'A_EARLY',
    'GROUP_A'::text AS group_id,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)) AS geom,
    tstzrange('2020-01-01 00:00:00+00', '2020-01-01 00:00:00+00', '[]') AS temporal_support
UNION ALL
SELECT
    'B_MIDDLE',
    'GROUP_B',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2021-01-01 00:00:00+00', '2021-01-01 00:00:00+00', '[]')
UNION ALL
SELECT
    'A_LATE',
    'GROUP_A',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2022-01-01 00:00:00+00', '2022-01-01 00:00:00+00', '[]');

/* Test 1 — Every returned sequence contains distinct group identifiers. */
DO $test$
DECLARE
    v_bad_count bigint;
BEGIN
    SELECT count(*)
      INTO v_bad_count
    FROM (
        SELECT r.observation_sequence
        FROM stcmp_experiment.st_comparable_areas_by_group(
            'stcmp_experiment.v_main_sequence'::regclass,
            'observation_id', 'geom', 'temporal_support',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
            'nonoverlapping_ordered', 'group_id', 2, 5, 0,
            NULL, INTERVAL '1100 days', NULL
        ) AS r
        CROSS JOIN LATERAL
            jsonb_array_elements(r.observation_sequence) AS e(item)
        GROUP BY r.observation_sequence, r.sequence_length
        HAVING count(DISTINCT e.item ->> 'group_id') <> r.sequence_length
    ) AS invalid_sequences;

    IF v_bad_count > 0 THEN
        RAISE EXCEPTION
            'Test 1 failed: % returned sequences contain repeated groups',
            v_bad_count;
    END IF;
END;
$test$;

/* Test 2 — O15 and O15_ALT (same group) must never occur together. */
DO $test$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*)
      INTO v_count
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 5, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.observation_sequence @> '[{"observation_id":"O15"}]'::jsonb
      AND r.observation_sequence @> '[{"observation_id":"O15_ALT"}]'::jsonb;

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'Test 2 failed: O15 and O15_ALT appeared together in % sequences',
            v_count;
    END IF;
END;
$test$;

/* Test 3 — Same-group observations remain available as alternatives in
   different sequences (O15->O17 and O15_ALT->O17 both exist). */
DO $test$
DECLARE
    v_o15_count bigint;
    v_alt_count bigint;
BEGIN
    SELECT count(*) INTO v_o15_count
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'O15'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O17';

    SELECT count(*) INTO v_alt_count
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'O15_ALT'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O17';

    IF v_o15_count <> 1 OR v_alt_count <> 1 THEN
        RAISE EXCEPTION
            'Test 3 failed: alternative sequences O15->O17 count %, O15_ALT->O17 count %',
            v_o15_count, v_alt_count;
    END IF;
END;
$test$;

/* Test 4 — A shorter valid sequence and its longer extension are both kept. */
DO $test$
DECLARE
    v_short_count bigint;
    v_long_count bigint;
    v_short_area double precision;
    v_long_area double precision;
BEGIN
    SELECT count(*), max(common_area)
      INTO v_short_count, v_short_area
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 4, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18';

    SELECT count(*), max(common_area)
      INTO v_long_count, v_long_area
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 4, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 3
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18'
      AND r.observation_sequence -> 2 ->> 'observation_id' = 'O20';

    IF v_short_count <> 1 OR v_long_count <> 1
       OR abs(v_short_area - 20000.0) > 0.01
       OR abs(v_long_area - 20000.0) > 0.01 THEN
        RAISE EXCEPTION
            'Test 4 failed: short count/area %, %, long count/area %, %',
            v_short_count, v_short_area, v_long_count, v_long_area;
    END IF;
END;
$test$;

/* Test 5 — has_valid_extension respects the group uniqueness condition. */
DO $test$
DECLARE
    v_can_extend boolean;
    v_terminal boolean;
BEGIN
    SELECT has_valid_extension INTO v_can_extend
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18';

    SELECT has_valid_extension INTO v_terminal
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O18'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O20';

    IF v_can_extend IS DISTINCT FROM TRUE
       OR v_terminal IS DISTINCT FROM FALSE THEN
        RAISE EXCEPTION
            'Test 5 failed: O17->O18 extension %, O18->O20 extension %',
            v_can_extend, v_terminal;
    END IF;
END;
$test$;

/* Test 6 — has_valid_extension must reject an extension that repeats a
   group, even when time and space would otherwise permit it. */
DO $test$
DECLARE
    v_extension boolean;
    v_invalid_long_count bigint;
BEGIN
    SELECT has_valid_extension INTO v_extension
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'pg_temp.stcbg_extension_group_test'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, INTERVAL '800 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'A_EARLY'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'B_MIDDLE';

    SELECT count(*) INTO v_invalid_long_count
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'pg_temp.stcbg_extension_group_test'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 3, 3, 0,
        NULL, INTERVAL '800 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'A_EARLY'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'B_MIDDLE'
      AND r.observation_sequence -> 2 ->> 'observation_id' = 'A_LATE';

    IF v_extension IS DISTINCT FROM FALSE OR v_invalid_long_count <> 0 THEN
        RAISE EXCEPTION
            'Test 6 failed: repeated-group extension flag %, invalid A-B-A sequence count %',
            v_extension, v_invalid_long_count;
    END IF;
END;
$test$;

/* Test 7 — p_max_sequence_length caps returned rows but still probes one
   further level for has_valid_extension. */
DO $test$
DECLARE
    v_max_length integer;
    v_extension boolean;
BEGIN
    SELECT max(sequence_length) INTO v_max_length
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, INTERVAL '1100 days', NULL
    );

    SELECT has_valid_extension INTO v_extension
    FROM stcmp_experiment.st_comparable_areas_by_group(
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
            'Test 7 failed: max returned length %, extension flag %',
            v_max_length, v_extension;
    END IF;
END;
$test$;

/* Test 8 — Length distribution is 7 pairs, 7 triples, and 2 quadruples
   for the main fixture with a 1,100-day maximum gap. This also confirms that
   the two O15 alternatives are not combined in one sequence. */
DO $test$
DECLARE
    v_pairs bigint;
    v_triples bigint;
    v_quads bigint;
    v_total bigint;
BEGIN
    SELECT
        count(*) FILTER (WHERE sequence_length = 2),
        count(*) FILTER (WHERE sequence_length = 3),
        count(*) FILTER (WHERE sequence_length = 4),
        count(*)
    INTO v_pairs, v_triples, v_quads, v_total
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 5, 0,
        NULL, INTERVAL '1100 days', NULL
    );

    IF v_pairs <> 7 OR v_triples <> 7 OR v_quads <> 2 OR v_total <> 16 THEN
        RAISE EXCEPTION
            'Test 8 failed: expected 7/7/2 = 16; got pairs %, triples %, quads %, total %',
            v_pairs, v_triples, v_quads, v_total;
    END IF;
END;
$test$;

/* Test 9 — Minimum sequence length is respected. */
DO $test$
DECLARE
    v_count bigint;
    v_min integer;
    v_max integer;
BEGIN
    SELECT count(*), min(sequence_length), max(sequence_length)
    INTO v_count, v_min, v_max
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 3, 3, 0,
        NULL, INTERVAL '1100 days', NULL
    );

    IF v_count <> 7 OR v_min <> 3 OR v_max <> 3 THEN
        RAISE EXCEPTION
            'Test 9 failed: expected seven length-3 rows; count %, min %, max %',
            v_count, v_min, v_max;
    END IF;
END;
$test$;

/* Test 10 — The cumulative three-way intersection rejects the pairwise chain. */
DO $test$
DECLARE
    v_pairs bigint;
    v_triples bigint;
BEGIN
    SELECT count(*) FILTER (WHERE sequence_length = 2),
           count(*) FILTER (WHERE sequence_length = 3)
    INTO v_pairs, v_triples
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_spatial_chain'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 3, 0,
        NULL, INTERVAL '1000 days', NULL
    );

    IF v_pairs <> 2 OR v_triples <> 0 THEN
        RAISE EXCEPTION
            'Test 10 failed: expected two pairwise supports and no triple; got %, %',
            v_pairs, v_triples;
    END IF;
END;
$test$;

/* Test 11 — Group-aware extension also obeys per-pair elapsed-time bounds.
   O15->O20 is too long, while O15->O17->O20 remains valid. */
DO $test$
DECLARE
    v_direct bigint;
    v_via_2017 bigint;
BEGIN
    SELECT count(*) INTO v_direct
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 3, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 2
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O15'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O20';

    SELECT count(*) INTO v_via_2017
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 3, 3, 0,
        NULL, INTERVAL '1100 days', NULL
    ) AS r
    WHERE r.sequence_length = 3
      AND r.observation_sequence -> 0 ->> 'observation_id' = 'O15'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 2 ->> 'observation_id' = 'O20';

    IF v_direct <> 0 OR v_via_2017 <> 1 THEN
        RAISE EXCEPTION
            'Test 11 failed: direct O15->O20 count %, via O17 count %',
            v_direct, v_via_2017;
    END IF;
END;
$test$;

/* Test 12 — Start-ordered mode permits overlapping intervals when groups
   are distinct, while non-overlapping mode rejects that same pair. */
DO $test$
DECLARE
    v_start_ordered bigint;
    v_nonoverlap bigint;
BEGIN
    SELECT count(*) INTO v_start_ordered
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'pg_temp.stcbg_temporal_grouped'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'start_ordered_overlap_allowed', 'test_group_id', 2, 2, 0,
        NULL, INTERVAL '10 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'T_OVERLAP_1'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'T_OVERLAP_2';

    SELECT count(*) INTO v_nonoverlap
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'pg_temp.stcbg_temporal_grouped'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'test_group_id', 2, 2, 0,
        NULL, INTERVAL '10 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'T_OVERLAP_1'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'T_OVERLAP_2';

    IF v_start_ordered <> 1 OR v_nonoverlap <> 0 THEN
        RAISE EXCEPTION
            'Test 12 failed: overlap-allowed count %, nonoverlap count %',
            v_start_ordered, v_nonoverlap;
    END IF;
END;
$test$;

/* Test 13 — Nonoverlapping mode rejects an instant at an interval's inclusive
   start, but accepts an instant at the interval's exclusive end. */
DO $test$
DECLARE
    v_at_start bigint;
    v_at_end bigint;
BEGIN
    SELECT count(*) INTO v_at_start
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'pg_temp.stcbg_temporal_grouped'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'test_group_id', 2, 2, 0,
        NULL, INTERVAL '3 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'T_INTERVAL_1'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'T_I_AT_START';

    SELECT count(*) INTO v_at_end
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'pg_temp.stcbg_temporal_grouped'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'test_group_id', 2, 2, 0,
        NULL, INTERVAL '3 days', NULL
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'T_INTERVAL_1'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'T_I_AT_END';

    IF v_at_start <> 0 OR v_at_end <> 1 THEN
        RAISE EXCEPTION
            'Test 13 failed: instant at interval start count %, at end count %',
            v_at_start, v_at_end;
    END IF;
END;
$test$;

/* Test 14 — Equal starts are not ordered by an arbitrary ID tie-breaker. */
DO $test$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*) INTO v_count
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'pg_temp.stcbg_temporal_grouped'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'start_ordered_overlap_allowed', 'test_group_id', 2, 2, 0,
        NULL, INTERVAL '10 days', NULL
    ) AS r
    WHERE r.observation_sequence @> '[{"observation_id":"T_EQUAL_START_1"}]'::jsonb
      AND r.observation_sequence @> '[{"observation_id":"T_EQUAL_START_2"}]'::jsonb;

    IF v_count <> 0 THEN
        RAISE EXCEPTION
            'Test 14 failed: equal-start observations were ordered in % sequences',
            v_count;
    END IF;
END;
$test$;

/* Test 15 — Fixed multi-granularity intervals (days/hours/minutes/seconds)
   are accepted. */
DO $test$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*) INTO v_count
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 3, 0,
        INTERVAL '1 day 2 hours 3 minutes 4 seconds',
        INTERVAL '1100 days 6 hours 30 minutes', NULL
    );

    IF v_count = 0 THEN
        RAISE EXCEPTION
            'Test 15 failed: multi-granularity fixed elapsed intervals yielded no results';
    END IF;
END;
$test$;

/* Test 16 — Calendar years/months are rejected deliberately. */
DO $test$
DECLARE
    v_raised boolean := false;
BEGIN
    BEGIN
        PERFORM 1
        FROM stcmp_experiment.st_comparable_areas_by_group(
            'stcmp_experiment.v_main_sequence'::regclass,
            'observation_id', 'geom', 'temporal_support',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
            'nonoverlapping_ordered', 'group_id', 2, 3, 0,
            INTERVAL '1 year 6 months', NULL, NULL
        );
    EXCEPTION WHEN invalid_parameter_value THEN
        v_raised := true;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION
            'Test 16 failed: calendar year/month interval should be rejected';
    END IF;
END;
$test$;

/* Test 17 — NULL group IDs are rejected instead of being treated as unique. */
DO $test$
DECLARE
    v_raised boolean := false;
BEGIN
    BEGIN
        PERFORM 1
        FROM stcmp_experiment.st_comparable_areas_by_group(
            'stcmp_experiment.v_temporal_edge_cases'::regclass,
            'observation_id', 'geom', 'temporal_support',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
            'nonoverlapping_ordered', 'group_id', 2, 2, 0,
            NULL, INTERVAL '10 days', NULL
        );
    EXCEPTION WHEN invalid_parameter_value THEN
        v_raised := true;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION
            'Test 17 failed: NULL group identifiers were not rejected';
    END IF;
END;
$test$;

/* Test 18 — A group column is mandatory. */
DO $test$
DECLARE
    v_raised boolean := false;
BEGIN
    BEGIN
        PERFORM 1
        FROM stcmp_experiment.st_comparable_areas_by_group(
            p_source                => 'stcmp_experiment.v_main_sequence'::regclass,
            p_observation_id_column => 'observation_id',
            p_geom_column           => 'geom',
            p_time_column           => 'temporal_support',
            p_study_area            => (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
            p_order_mode            => 'nonoverlapping_ordered',
            p_group_column          => NULL
        );
    EXCEPTION WHEN invalid_parameter_value THEN
        v_raised := true;
    END;

    IF NOT v_raised THEN
        RAISE EXCEPTION 'Test 18 failed: missing group column was not rejected';
    END IF;
END;
$test$;

/* Test 19 — A time window filters eligible source observations. */
DO $test$
DECLARE
    v_count bigint;
BEGIN
    SELECT count(*) INTO v_count
    FROM stcmp_experiment.st_comparable_areas_by_group(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'nonoverlapping_ordered', 'group_id', 2, 2, 0,
        NULL, NULL,
        tstzrange('2017-01-01 00:00:00+00', '2019-01-01 00:00:00+00', '[)')
    ) AS r
    WHERE r.observation_sequence -> 0 ->> 'observation_id' = 'O17'
      AND r.observation_sequence -> 1 ->> 'observation_id' = 'O18';

    IF v_count <> 1 THEN
        RAISE EXCEPTION
            'Test 19 failed: expected O17->O18 inside time window; got %', v_count;
    END IF;
END;
$test$;

SELECT 'ST_ComparableAreasByGroup: all 19 sanity tests passed' AS test_status;

/*=============================================================================
  DIRECT USAGE EXAMPLES

  These examples call the public function directly. They do not depend on
  temporary test result tables.
=============================================================================*/

/* Example 1 — Main fixture: all valid sequences with distinct groups. */
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom
FROM stcmp_experiment.st_comparable_areas_by_group(
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

/* Example 2 — Constrain sequence length and elapsed time. */
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom
FROM stcmp_experiment.st_comparable_areas_by_group(
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

/* Example 3 — QGIS-friendly output with a native PostGIS geometry column. */
SELECT
    ROW_NUMBER() OVER (
        ORDER BY r.sequence_length, r.observation_sequence::text
    ) AS seq_id,
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom AS geom
FROM stcmp_experiment.st_comparable_areas_by_group(
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

/* Example 4 — Adapt this query to your own source and study-area table.

SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom AS geom
FROM stcmp_experiment.st_comparable_areas_by_group(
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
) AS r
ORDER BY r.sequence_length, r.observation_sequence::text;

*/

/* Example 5 — Persist an analysis run and add a spatial index.
   Replace the target table and source arguments as appropriate.

CREATE TABLE your_schema.comparable_areas_by_group_run_01 AS
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom AS geom
FROM stcmp_experiment.st_comparable_areas_by_group(
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
    p_min_elapsed            => INTERVAL '30 days',
    p_max_elapsed            => INTERVAL '1825 days',
    p_time_window            => NULL
) AS r;

CREATE INDEX comparable_areas_by_group_run_01_geom_gix
    ON your_schema.comparable_areas_by_group_run_01 USING GIST (geom);
ANALYZE your_schema.comparable_areas_by_group_run_01;
*/
