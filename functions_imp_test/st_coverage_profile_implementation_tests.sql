/*=============================================================================
  ST_CoverageProfile: PostgreSQL/PostGIS implementation and sanity tests

  Target setup:
    Existing schema: stcmp_experiment
    Existing canonical view: stcmp_experiment.v_observation_source
    Existing scenario views: v_main_sequence, v_partial_coverage,
      v_boundary_contact, v_temporal_edge_cases

  Run this AFTER st_comparableareas_experiment_setup.sql.

  Function contract:
    - One output row per source observation with positive-area intersection
      with p_study_area.
    - Spatial output is the polygonal component of ST_Intersection(source_geom,
      p_study_area), normalized to MultiPolygon.
    - Temporal support is returned unchanged when the source column is tstzrange.
    - A timestamptz source column is normalized to a closed singleton tstzrange.
    - A temporal window filters by overlap but never truncates the returned
      observation's original temporal support.
    - Unknown temporal support is retained when no time window is supplied;
      it is excluded when a time window is supplied.
    - Boundary-only contacts and line/point intersections are excluded.
    - The function returns a relation (set); callers must add ORDER BY when
      a presentation order is required.

  Source relation contract:
    - Must be a table, partitioned table, view, materialized view, or foreign
      table exposing the requested columns.
    - Observation ID values must be non-NULL and unique in the source relation.
    - Geometry must be valid, areal, non-empty, and use the same SRID as the
      study area. A typmod-declared SRID is checked by the function.
    - Temporal column must be tstzrange or timestamptz. timestamp without time
      zone must first be normalized through a view with an explicit time zone.
    - p_min_fragment_area is measured in squared units of the geometry CRS.

  Security:
    - SECURITY INVOKER (default): the caller needs SELECT permission on source.
    - Dynamic SQL identifiers are quoted with %I; values are bound with USING.
=============================================================================*/

CREATE OR REPLACE FUNCTION stcmp_experiment.st_coverage_profile(
    p_source                regclass,
    p_observation_id_column name,
    p_geom_column           name,
    p_time_column           name,
    p_study_area            geometry,
    p_group_column          name DEFAULT NULL,
    p_time_window           tstzrange DEFAULT NULL,
    p_min_fragment_area     double precision DEFAULT 0
)
RETURNS TABLE (
    observation_id   text,
    group_id         text,
    temporal_support tstzrange,
    support_geom     geometry
)
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, public, stcmp_experiment
AS $function$
DECLARE
    v_relkind             "char";
    v_schema_name         text;
    v_relation_name       text;
    v_source_sql          text;

    v_id_type             oid;
    v_geom_type           oid;
    v_geom_typmod         integer;
    v_time_type           oid;
    v_group_type          oid;
    v_declared_srid       integer;

    v_group_expression    text;
    v_time_expression     text;
    v_time_filter         text := '';
    v_area_parameter      text;
    v_sql                 text;

BEGIN
    /*------------------------- Argument validation -------------------------*/

    IF p_source IS NULL THEN
        RAISE EXCEPTION 'p_source must identify a relation'
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
        RAISE EXCEPTION 'p_study_area must be POLYGON or MULTIPOLYGON; got %',
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

    IF p_min_fragment_area IS NULL
       OR p_min_fragment_area < 0
       OR NOT (p_min_fragment_area < 'Infinity'::double precision) THEN
        RAISE EXCEPTION
            'p_min_fragment_area must be a finite, non-negative number'
            USING ERRCODE = '22023';
    END IF;

    IF p_time_window IS NOT NULL AND isempty(p_time_window) THEN
        RAISE EXCEPTION 'p_time_window must not be an empty range'
            USING ERRCODE = '22023';
    END IF;

    /*-------------------------- Relation validation ------------------------*/

    SELECT c.relkind, n.nspname, c.relname
      INTO v_relkind, v_schema_name, v_relation_name
    FROM pg_class AS c
    JOIN pg_namespace AS n ON n.oid = c.relnamespace
    WHERE c.oid = p_source::oid;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Source relation % does not exist', p_source
            USING ERRCODE = '42P01';
    END IF;

    IF v_relkind NOT IN ('r', 'p', 'v', 'm', 'f') THEN
        RAISE EXCEPTION
            'Source % must be a table, partitioned table, view, materialized view, or foreign table',
            p_source
            USING ERRCODE = '42809';
    END IF;

    v_source_sql := format('%I.%I', v_schema_name, v_relation_name);

    /*--------------------------- Column validation -------------------------*/

    SELECT a.atttypid
      INTO v_id_type
    FROM pg_attribute AS a
    WHERE a.attrelid = p_source::oid
      AND a.attname = p_observation_id_column
      AND a.attnum > 0
      AND NOT a.attisdropped;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Observation ID column % does not exist in %',
            p_observation_id_column, p_source
            USING ERRCODE = '42703';
    END IF;

    SELECT a.atttypid, a.atttypmod
      INTO v_geom_type, v_geom_typmod
    FROM pg_attribute AS a
    WHERE a.attrelid = p_source::oid
      AND a.attname = p_geom_column
      AND a.attnum > 0
      AND NOT a.attisdropped;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Geometry column % does not exist in %',
            p_geom_column, p_source
            USING ERRCODE = '42703';
    END IF;

    IF v_geom_type <> 'geometry'::regtype THEN
        RAISE EXCEPTION 'Column %.% must have PostGIS geometry type',
            p_source, p_geom_column
            USING ERRCODE = '42804';
    END IF;

    SELECT a.atttypid
      INTO v_time_type
    FROM pg_attribute AS a
    WHERE a.attrelid = p_source::oid
      AND a.attname = p_time_column
      AND a.attnum > 0
      AND NOT a.attisdropped;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'Temporal column % does not exist in %',
            p_time_column, p_source
            USING ERRCODE = '42703';
    END IF;

    IF v_time_type = 'tstzrange'::regtype THEN
        /* Preserve the source temporal support exactly. */
        v_time_expression := format('src.%I', p_time_column);
    ELSIF v_time_type = 'timestamp with time zone'::regtype THEN
        /* Normalize a timestamp instant to a closed singleton range. */
        v_time_expression := format(
            'CASE WHEN src.%1$I IS NULL THEN NULL::tstzrange '
            'ELSE tstzrange(src.%1$I, src.%1$I, ''[]'') END',
            p_time_column
        );
    ELSE
        RAISE EXCEPTION
            'Temporal column % in % has unsupported type %. Use tstzrange or timestamptz; normalize other types in a source view.',
            p_time_column, p_source, format_type(v_time_type, NULL)
            USING ERRCODE = '42804';
    END IF;

    IF p_group_column IS NULL THEN
        v_group_expression := 'NULL::text';
    ELSE
        SELECT a.atttypid
          INTO v_group_type
        FROM pg_attribute AS a
        WHERE a.attrelid = p_source::oid
          AND a.attname = p_group_column
          AND a.attnum > 0
          AND NOT a.attisdropped;

        IF NOT FOUND THEN
            RAISE EXCEPTION 'Group column % does not exist in %',
                p_group_column, p_source
                USING ERRCODE = '42703';
        END IF;

        v_group_expression := format('src.%I::text', p_group_column);
    END IF;

    /*
      If the geometry column has a PostGIS typmod with an explicit SRID,
      validate it against the study area. Generic geometry columns (typmod
      without an SRID) rely on the source relation's documented SRID contract.
    */
    IF v_geom_typmod >= 0 THEN
        v_declared_srid := postgis_typmod_srid(v_geom_typmod);
        IF v_declared_srid > 0 AND v_declared_srid <> ST_SRID(p_study_area) THEN
            RAISE EXCEPTION
                'SRID mismatch: source geometry column declares SRID %, study area has SRID %',
                v_declared_srid, ST_SRID(p_study_area)
                USING ERRCODE = '22023';
        END IF;
    END IF;

    /*------------------------ Dynamic query construction ------------------*/

    /*
      Use separate query shapes for filtered and unfiltered temporal calls.
      This avoids an OR condition such as ($window IS NULL OR time && $window),
      which can make temporal index use less predictable.
    */
    IF p_time_window IS NULL THEN
        v_time_filter := '';
        v_area_parameter := '$2';
    ELSE
        v_time_filter := format(' AND (%s) && $2 ', v_time_expression);
        v_area_parameter := '$3';
    END IF;

    v_sql := format($sql$
        WITH clipped AS (
            SELECT
                src.%1$I::text AS observation_id,
                %2$s AS group_id,
                %3$s AS temporal_support,
                ST_Multi(
                    ST_CollectionExtract(
                        ST_Intersection(src.%4$I, $1),
                        3
                    )
                ) AS support_geom
            FROM %5$s AS src
            WHERE src.%4$I && $1
              AND ST_Intersects(src.%4$I, $1)
              %6$s
        ),
        measured AS (
            SELECT
                observation_id,
                group_id,
                temporal_support,
                support_geom,
                ST_Area(support_geom) AS fragment_area
            FROM clipped
        )
        SELECT
            observation_id,
            group_id,
            temporal_support,
            support_geom
        FROM measured
        WHERE NOT ST_IsEmpty(support_geom)
          AND fragment_area > %7$s
    $sql$,
        p_observation_id_column,  -- %1$I
        v_group_expression,       -- %2$s
        v_time_expression,        -- %3$s
        p_geom_column,             -- %4$I
        v_source_sql,              -- %5$s, catalog-quoted relation
        v_time_filter,             -- %6$s, generated only from typed metadata
        v_area_parameter           -- %7$s, fixed placeholder
    );

    /*------------------------------ Execution ------------------------------*/

    IF p_time_window IS NULL THEN
        RETURN QUERY EXECUTE v_sql
            USING p_study_area, p_min_fragment_area;
    ELSE
        RETURN QUERY EXECUTE v_sql
            USING p_study_area, p_time_window, p_min_fragment_area;
    END IF;
END;
$function$;

COMMENT ON FUNCTION stcmp_experiment.st_coverage_profile(
    regclass, name, name, name, geometry, name, tstzrange, double precision
) IS
'Returns one row per source observation with positive-area intersection with a study area. Supports tstzrange and timestamptz source columns, optional group and temporal-window filters, and preserves original temporal support.';

/*=============================================================================
  SANITY TESTS

  The DO blocks raise an exception if any expected result is not obtained.
  Run this section after creating the function. It uses only the fixture views
  and rows from st_comparableareas_experiment_setup.sql.
=============================================================================*/

/* Test 1: Main scenario inventory; all five main observations are returned. */
DO $test$
DECLARE
    v_ids text[];
BEGIN
    SELECT array_agg(x.observation_id ORDER BY x.observation_id)
      INTO v_ids
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'group_id'
    ) AS x;

    IF v_ids IS DISTINCT FROM ARRAY['O15','O15_ALT','O17','O18','O20']::text[] THEN
        RAISE EXCEPTION 'Test 1 failed: unexpected observation IDs: %', v_ids;
    END IF;
END;
$test$;

/* Test 2: Exact clipped areas in the western half of the study area. */
DO $test$
DECLARE
    v_bad_count integer;
BEGIN
    WITH expected(observation_id, expected_area) AS (
        VALUES
          ('O15',     50000.0),
          ('O15_ALT', 30000.0),
          ('O17',     50000.0),
          ('O18',     10000.0),
          ('O20',     50000.0)
    ),
    actual AS (
        SELECT observation_id, ST_Area(support_geom) AS actual_area
        FROM stcmp_experiment.st_coverage_profile(
            'stcmp_experiment.v_main_sequence'::regclass,
            'observation_id', 'geom', 'temporal_support',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A_WEST'),
            'group_id'
        )
    )
    SELECT count(*)
      INTO v_bad_count
    FROM expected e
    FULL JOIN actual a USING (observation_id)
    WHERE e.observation_id IS NULL
       OR a.observation_id IS NULL
       OR abs(a.actual_area - e.expected_area) > 0.01;

    IF v_bad_count <> 0 THEN
        RAISE EXCEPTION 'Test 2 failed: % incorrect/missing clipped areas', v_bad_count;
    END IF;
END;
$test$;

/* Test 3: Partial footprints; threshold > 15,000 m^2 keeps only WEST_OUTSIDE. */
DO $test$
DECLARE
    v_ids text[];
    v_area double precision;
BEGIN
    SELECT array_agg(x.observation_id ORDER BY x.observation_id),
           max(ST_Area(x.support_geom))
      INTO v_ids, v_area
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_partial_coverage'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'group_id', NULL, 15000.0
    ) AS x;

    IF v_ids IS DISTINCT FROM ARRAY['WEST_OUTSIDE']::text[]
       OR abs(v_area - 20000.0) > 0.01 THEN
        RAISE EXCEPTION 'Test 3 failed: IDs %, area %', v_ids, v_area;
    END IF;
END;
$test$;

/* Test 4: Boundary-only contact is excluded; positive-area part is retained. */
DO $test$
DECLARE
    v_ids text[];
    v_area double precision;
BEGIN
    SELECT array_agg(x.observation_id ORDER BY x.observation_id),
           max(ST_Area(x.support_geom))
      INTO v_ids, v_area
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_boundary_contact'::regclass,
        'observation_id', 'geom', 'temporal_support',
        ST_Multi(ST_MakeEnvelope(570200, 6200000, 570300, 6200100, 25832)),
        'group_id'
    ) AS x;

    IF v_ids IS DISTINCT FROM ARRAY['BOUND_RIGHT']::text[]
       OR abs(v_area - 10000.0) > 0.01 THEN
        RAISE EXCEPTION 'Test 4 failed: IDs %, area %', v_ids, v_area;
    END IF;
END;
$test$;

/* Test 5: Temporal window selects O17 and O18, preserving original instants. */
DO $test$
DECLARE
    v_ids text[];
    v_wrong_support_count integer;
BEGIN
    SELECT array_agg(x.observation_id ORDER BY x.observation_id)
      INTO v_ids
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'group_id',
        tstzrange('2017-01-01 00:00:00+00', '2019-01-01 00:00:00+00', '[)')
    ) AS x;

    IF v_ids IS DISTINCT FROM ARRAY['O17','O18']::text[] THEN
        RAISE EXCEPTION 'Test 5 failed: unexpected IDs: %', v_ids;
    END IF;

    SELECT count(*)
      INTO v_wrong_support_count
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'group_id',
        tstzrange('2017-01-01 00:00:00+00', '2019-01-01 00:00:00+00', '[)')
    ) AS x
    JOIN stcmp_experiment.observation AS src USING (observation_id)
    WHERE x.temporal_support IS DISTINCT FROM src.temporal_support;

    IF v_wrong_support_count <> 0 THEN
        RAISE EXCEPTION 'Test 5 failed: function changed original temporal supports';
    END IF;
END;
$test$;

/* Test 6: A window intersecting T_RANGE_1 returns its ORIGINAL full range. */
DO $test$
DECLARE
    v_count integer;
    v_support tstzrange;
BEGIN
    SELECT count(*), (array_agg(x.temporal_support))[1]
      INTO v_count, v_support
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_temporal_edge_cases'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        NULL,
        tstzrange('2024-03-02 00:00:00+00', '2024-03-04 00:00:00+00', '[)')
    ) AS x
    WHERE x.observation_id = 'T_RANGE_1';

    IF v_count <> 1
       OR v_support IS DISTINCT FROM
          tstzrange('2024-03-01 00:00:00+00', '2024-03-03 00:00:00+00', '[)') THEN
        RAISE EXCEPTION 'Test 6 failed: count %, support %', v_count, v_support;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM stcmp_experiment.st_coverage_profile(
            'stcmp_experiment.v_temporal_edge_cases'::regclass,
            'observation_id', 'geom', 'temporal_support',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
            NULL,
            tstzrange('2024-03-02 00:00:00+00', '2024-03-04 00:00:00+00', '[)')
        ) AS x
        WHERE x.observation_id = 'T_RANGE_2'
    ) THEN
        RAISE EXCEPTION 'Test 6 failed: touching range T_RANGE_2 should not overlap the half-open window';
    END IF;
END;
$test$;

/* Test 7: Unknown temporal support is retained without a time filter. */
DO $test$
DECLARE
    v_unknown_count integer;
    v_unknown_time  tstzrange;
BEGIN
    SELECT count(*), (array_agg(x.temporal_support))[1]
      INTO v_unknown_count, v_unknown_time
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_temporal_edge_cases'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        NULL
    ) AS x
    WHERE x.observation_id = 'T_UNKNOWN';

    IF v_unknown_count <> 1 OR v_unknown_time IS NOT NULL THEN
        RAISE EXCEPTION 'Test 7 failed: unknown-time observation was not preserved';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM stcmp_experiment.st_coverage_profile(
            'stcmp_experiment.v_temporal_edge_cases'::regclass,
            'observation_id', 'geom', 'temporal_support',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
            NULL,
            tstzrange('2024-01-01 00:00:00+00', '2025-01-01 00:00:00+00', '[)')
        ) AS x
        WHERE x.observation_id = 'T_UNKNOWN'
    ) THEN
        RAISE EXCEPTION 'Test 7 failed: unknown-time observation passed a time-window filter';
    END IF;
END;
$test$;

/* Test 8: No group column supplied -> group_id is NULL. */
DO $test$
DECLARE
    v_bad_count integer;
BEGIN
    SELECT count(*)
      INTO v_bad_count
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_main_sequence'::regclass,
        'observation_id', 'geom', 'temporal_support',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A')
    ) AS x
    WHERE x.group_id IS NOT NULL;

    IF v_bad_count <> 0 THEN
        RAISE EXCEPTION 'Test 8 failed: group_id must be NULL when no group column is supplied';
    END IF;
END;
$test$;

/* Test 9: timestamptz source column is normalized to singleton tstzrange. */
CREATE OR REPLACE VIEW stcmp_experiment.v_instant_time_source AS
SELECT
    observation_id,
    group_id,
    geom,
    lower(temporal_support) AS observed_at
FROM stcmp_experiment.observation
WHERE observation_id IN ('O15', 'O17', 'O18', 'O20');

DO $test$
DECLARE
    v_count integer;
    v_bad_count integer;
BEGIN
    SELECT count(*),
           count(*) FILTER (
               WHERE lower(x.temporal_support) <> upper(x.temporal_support)
                  OR NOT lower_inc(x.temporal_support)
                  OR NOT upper_inc(x.temporal_support)
           )
      INTO v_count, v_bad_count
    FROM stcmp_experiment.st_coverage_profile(
        'stcmp_experiment.v_instant_time_source'::regclass,
        'observation_id', 'geom', 'observed_at',
        (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
        'group_id'
    ) AS x;

    IF v_count <> 4 OR v_bad_count <> 0 THEN
        RAISE EXCEPTION 'Test 9 failed: row count %, invalid singleton ranges %',
            v_count, v_bad_count;
    END IF;
END;
$test$;

/* Test 10: Invalid minimum area is rejected. */
DO $test$
BEGIN
    BEGIN
        PERFORM 1
        FROM stcmp_experiment.st_coverage_profile(
            'stcmp_experiment.v_main_sequence'::regclass,
            'observation_id', 'geom', 'temporal_support',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
            'group_id', NULL, -1.0
        );
        RAISE EXCEPTION 'Test 10 failed: negative area threshold was accepted';
    EXCEPTION
        WHEN SQLSTATE '22023' THEN
            NULL; -- Expected validation error.
    END;
END;
$test$;

/* Test 11: Unsupported timestamp-without-time-zone column is rejected. */
CREATE OR REPLACE VIEW stcmp_experiment.v_bad_timezone_source AS
SELECT
    observation_id,
    geom,
    lower(temporal_support)::timestamp without time zone AS observed_local_time
FROM stcmp_experiment.observation
WHERE observation_id = 'O15';

DO $test$
BEGIN
    BEGIN
        PERFORM 1
        FROM stcmp_experiment.st_coverage_profile(
            'stcmp_experiment.v_bad_timezone_source'::regclass,
            'observation_id', 'geom', 'observed_local_time',
            (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A')
        );
        RAISE EXCEPTION 'Test 11 failed: timestamp without time zone was accepted';
    EXCEPTION
        WHEN SQLSTATE '42804' THEN
            NULL; -- Expected: normalize through a view with an explicit TZ.
    END;
END;
$test$;

/*=============================================================================
  HUMAN-READABLE DIAGNOSTIC QUERIES

  Run after the assertions. These show actual returned IDs, areas, and temporal
  supports for manual inspection.
=============================================================================*/

/* Main scenario: five clipped observations. */
SELECT
    observation_id,
    group_id,
    temporal_support,
    round(ST_Area(support_geom)::numeric, 2) AS clipped_area_m2,
    ST_AsText(ST_Envelope(support_geom)) AS support_envelope
FROM stcmp_experiment.st_coverage_profile(
    'stcmp_experiment.v_main_sequence'::regclass,
    'observation_id', 'geom', 'temporal_support',
    (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
    'group_id'
)
ORDER BY observation_id;

/* Partial footprints and minimum-area filtering. */
SELECT
    observation_id,
    round(ST_Area(support_geom)::numeric, 2) AS clipped_area_m2
FROM stcmp_experiment.st_coverage_profile(
    'stcmp_experiment.v_partial_coverage'::regclass,
    'observation_id', 'geom', 'temporal_support',
    (SELECT geom FROM stcmp_experiment.study_area WHERE area_id = 'A'),
    'group_id', NULL, 15000.0
)
ORDER BY observation_id;

/* All assertions passed if execution reaches this final row. */
SELECT 'ST_CoverageProfile: all 11 sanity tests passed' AS test_status;

ANALYZE stcmp_experiment.observation;
