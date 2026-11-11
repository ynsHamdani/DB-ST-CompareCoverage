/*=============================================================================
  ST_ComparableAreasByTime — direct usage examples

  IMPORTANT
  ---------
  Call the function directly in the FROM clause. The function returns its
  result rows; callers do not need (and should not query) pg_temp test tables.

  Prerequisites:
    - stcmp_experiment.st_comparable_areas_by_time(...) is installed.
    - stcmp_experiment.st_coverage_profile(...) is installed.
    - The fixture schema exists if you run Example 1.

  Run these examples in the database where the function is installed.
=============================================================================*/

/*-----------------------------------------------------------------------------
  EXAMPLE 1 — Run the function against the bundled main-sequence fixture.

  This uses the fixture view and study area A. The optional group_id is
  returned as metadata in each observation's JSON sequence. It does NOT
  impose a one-observation-per-group rule in ByTime.
-----------------------------------------------------------------------------*/
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.effective_area,
    r.common_support_geom,
    r.effective_support_geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                => 'stcmp_experiment.v_main_sequence'::regclass,
    p_observation_id_column => 'observation_id',
    p_geom_column           => 'geom',
    p_time_column           => 'temporal_support',
    p_study_area            => (
        SELECT sa.geom
        FROM stcmp_experiment.study_area AS sa
        WHERE sa.area_id = 'A'
    ),
    p_order_mode            => 'nonoverlapping_ordered',
    p_group_column          => 'group_id',
    p_min_sequence_length   => 2,
    p_min_common_area       => 0,
    p_min_elapsed           => NULL,
    p_max_elapsed           => INTERVAL '1100 days',
    p_time_window           => NULL
) AS r
ORDER BY r.sequence_length, r.observation_sequence::text;


/*-----------------------------------------------------------------------------
  EXAMPLE 2 — Same fixture, allowing temporal overlap.

  Starts must be strictly increasing. Temporal overlap is permitted, and the
  elapsed-time bounds are measured between successive observation start times.
-----------------------------------------------------------------------------*/
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.effective_area,
    r.effective_support_geom AS geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                => 'stcmp_experiment.v_main_sequence'::regclass,
    p_observation_id_column => 'observation_id',
    p_geom_column           => 'geom',
    p_time_column           => 'temporal_support',
    p_study_area            => (
        SELECT sa.geom
        FROM stcmp_experiment.study_area AS sa
        WHERE sa.area_id = 'A'
    ),
    p_order_mode            => 'start_ordered_overlap_allowed',
    p_group_column          => 'group_id',
    p_min_sequence_length   => 2,
    p_min_common_area       => 0,
    p_min_elapsed           => NULL,
    p_max_elapsed           => INTERVAL '1100 days',
    p_time_window           => NULL
) AS r
ORDER BY r.sequence_length, r.observation_sequence::text;


/*-----------------------------------------------------------------------------
  EXAMPLE 3 — Apply the function to YOUR source relation.

  Replace the relation, column names, study-area query, and thresholds below.
  The source can be a table or a view. A view is useful when your real schema
  uses different names or needs timestamp-without-time-zone normalization.

  p_min_common_area is measured in squared units of the geometry CRS. Use a
  projected CRS with suitable linear units for meaningful area thresholds.
-----------------------------------------------------------------------------*/
/*
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.effective_area,
    r.common_support_geom,
    r.effective_support_geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                => 'your_schema.your_observation_view'::regclass,
    p_observation_id_column => 'observation_id',
    p_geom_column           => 'geom',
    p_time_column           => 'temporal_support',
    p_study_area            => (
        SELECT a.geom
        FROM your_schema.study_areas AS a
        WHERE a.study_area_id = 'YOUR_AREA_ID'
    ),
    p_order_mode            => 'nonoverlapping_ordered',
    p_group_column          => 'campaign_id',  -- use NULL when not available
    p_min_sequence_length   => 2,
    p_min_common_area       => 1000,            -- CRS area units squared
    p_min_elapsed           => INTERVAL '30 days',
    p_max_elapsed           => INTERVAL '1825 days',
    p_time_window           => NULL             -- or a tstzrange, e.g. '[2010-01-01,2025-01-01)'
) AS r
WHERE r.sequence_length >= 3
ORDER BY r.sequence_length, r.observation_sequence::text;
*/


/*-----------------------------------------------------------------------------
  EXAMPLE 4 — Persist one analysis run as a normal table.

  Uncomment and adapt the statement if you want to keep the result after the
  query/session ends, use it in QGIS, or index its geometries. Unlike pg_temp,
  this is a regular table in your chosen schema.
-----------------------------------------------------------------------------*/
/*
CREATE TABLE your_schema.comparable_areas_run_01 AS
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.effective_area,
    r.common_support_geom,
    r.effective_support_geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                => 'your_schema.your_observation_view'::regclass,
    p_observation_id_column => 'observation_id',
    p_geom_column           => 'geom',
    p_time_column           => 'temporal_support',
    p_study_area            => (
        SELECT a.geom
        FROM your_schema.study_areas AS a
        WHERE a.study_area_id = 'YOUR_AREA_ID'
    ),
    p_order_mode            => 'nonoverlapping_ordered',
    p_group_column          => 'campaign_id',
    p_min_sequence_length   => 2,
    p_min_common_area       => 1000,
    p_min_elapsed           => INTERVAL '30 days',
    p_max_elapsed           => INTERVAL '1825 days',
    p_time_window           => NULL
) AS r;

CREATE INDEX comparable_areas_run_01_effective_geom_gix
    ON your_schema.comparable_areas_run_01
    USING GIST (effective_support_geom);

ANALYZE your_schema.comparable_areas_run_01;
*/


/*-----------------------------------------------------------------------------
  EXAMPLE 5 — Inspect only the geometries in a GIS-friendly result shape.

  Alias the returned geometry as geom so GIS clients can identify it easily.
  This is still a direct function call; no intermediate temporary table is
  required. Adapt the source and study-area arguments as in Example 3.
-----------------------------------------------------------------------------*/
/*
SELECT
    row_number() OVER (ORDER BY r.sequence_length, r.observation_sequence::text)
        AS result_id,
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.effective_area,
    r.effective_support_geom AS geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                => 'your_schema.your_observation_view'::regclass,
    p_observation_id_column => 'observation_id',
    p_geom_column           => 'geom',
    p_time_column           => 'temporal_support',
    p_study_area            => (
        SELECT a.geom
        FROM your_schema.study_areas AS a
        WHERE a.study_area_id = 'YOUR_AREA_ID'
    ),
    p_order_mode            => 'nonoverlapping_ordered',
    p_group_column          => 'campaign_id',
    p_min_sequence_length   => 2,
    p_min_common_area       => 1000,
    p_min_elapsed           => NULL,
    p_max_elapsed           => INTERVAL '1825 days',
    p_time_window           => NULL
) AS r
WHERE r.effective_support_geom IS NOT NULL
  AND NOT ST_IsEmpty(r.effective_support_geom);
*/




-------------

SELECT
    ROW_NUMBER() OVER () AS seq_id,
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.effective_area,
    st_astext(r.common_support_geom) as common_geom_text,
    st_astext(r.effective_support_geom) as effective_geom_text
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                => 'stcmp_experiment.v_main_sequence'::regclass,
    p_observation_id_column => 'observation_id',
    p_geom_column           => 'geom',
    p_time_column           => 'temporal_support',
    p_study_area            => (
        SELECT sa.geom
        FROM stcmp_experiment.study_area AS sa
        WHERE sa.area_id = 'A'
    ),
    p_order_mode            => 'nonoverlapping_ordered',
    --p_group_column          => 'group_id',
    p_min_sequence_length   => 2,
    p_min_common_area       => 0,
    p_min_elapsed           => INTERVAL '90 days 6 hours',
    p_max_elapsed           => INTERVAL '1100 days',
    p_time_window           => NULL
) AS r
ORDER BY r.sequence_length;