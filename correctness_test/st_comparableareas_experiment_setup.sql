/*=============================================================================
  Controlled experiment setup for ST_CoverageProfile and ST_ComparableAreas

  Purpose
  -------
  1. Create a minimal, canonical relational source schema.
  2. Insert deterministic synthetic study areas, observation groups, and
     spatiotemporal observation footprints.
  3. Include carefully controlled spatial and temporal cases for later tests.

  Requirements
  ------------
  PostgreSQL + PostGIS.
  The geometries use EPSG:25832 (projected metres; illustrative Danish area).

  IMPORTANT
  ---------
  This script DROPS and recreates schema stcmp_experiment. Run it only in a
  dedicated test database/schema. Remove the DROP SCHEMA statement if you need
  to preserve existing experiment data.

  Temporal representation
  -----------------------
  * Instant: tstzrange(t, t, '[]')  -- closed singleton range.
  * Interval: tstzrange(start, end, '[)') -- lower-inclusive, upper-exclusive.
  * NULL temporal_support means the acquisition time is unknown.

  The data are synthetic, not actual Danish LiDAR acquisition records.
=============================================================================*/

CREATE EXTENSION IF NOT EXISTS postgis;

DROP SCHEMA IF EXISTS stcmp_experiment CASCADE;
CREATE SCHEMA stcmp_experiment;

/*=============================================================================
  STEP 1. SOURCE DATABASE SCHEMA
=============================================================================*/

/*
  An observation group is a generic collection such as a LiDAR campaign,
  survey, acquisition programme, map edition, or other domain grouping.
  group_period is nominal metadata; it is NOT substituted for the actual
  temporal_support of an individual observation.

  No group_order column is used. Candidate sequence ordering is derived from
  the actual temporal supports of observations.
*/
CREATE TABLE stcmp_experiment.observation_group (
    group_id       text PRIMARY KEY,
    group_name     text NOT NULL,
    group_period   tstzrange NOT NULL,
    description    text,
    metadata       jsonb NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT observation_group_period_valid CHECK (
        NOT isempty(group_period)
        AND NOT lower_inf(group_period)
        AND NOT upper_inf(group_period)
        AND isfinite(lower(group_period))
        AND isfinite(upper(group_period))
        AND lower_inc(group_period)
        AND NOT upper_inc(group_period)
        AND lower(group_period) < upper(group_period)
    ),
    CONSTRAINT observation_group_metadata_object CHECK (
        jsonb_typeof(metadata) = 'object'
    )
);

/*
  One row represents one spatiotemporal observation footprint.

  group_id is nullable because the general time-based operator must also be
  able to process observations that are not assigned to a group.

  temporal_support permits either:
    (a) a closed singleton [t,t] for an instant, or
    (b) a lower-inclusive / upper-exclusive interval [s,e).

  Other range-bound conventions are rejected to keep the semantics explicit.
*/
CREATE TABLE stcmp_experiment.observation (
    observation_id   text PRIMARY KEY,
    group_id         text NULL
                     REFERENCES stcmp_experiment.observation_group(group_id)
                     ON UPDATE CASCADE
                     ON DELETE RESTRICT,
    geom             geometry(MultiPolygon, 25832) NOT NULL,
    temporal_support tstzrange NULL,
    properties       jsonb NOT NULL DEFAULT '{}'::jsonb,

    CONSTRAINT observation_geom_nonempty CHECK (
        NOT ST_IsEmpty(geom)
    ),
    CONSTRAINT observation_geom_valid CHECK (
        ST_IsValid(geom)
    ),
    CONSTRAINT observation_geom_positive_area CHECK (
        ST_Area(geom) > 0
    ),
    CONSTRAINT observation_temporal_support_valid CHECK (
        temporal_support IS NULL
        OR (
            NOT isempty(temporal_support)
            AND NOT lower_inf(temporal_support)
            AND NOT upper_inf(temporal_support)
            AND isfinite(lower(temporal_support))
            AND isfinite(upper(temporal_support))
            AND (
                /* Instant: closed singleton [t,t]. */
                (
                    lower(temporal_support) = upper(temporal_support)
                    AND lower_inc(temporal_support)
                    AND upper_inc(temporal_support)
                )
                OR
                /* Interval: lower-inclusive, upper-exclusive [s,e). */
                (
                    lower(temporal_support) < upper(temporal_support)
                    AND lower_inc(temporal_support)
                    AND NOT upper_inc(temporal_support)
                )
            )
        )
    ),
    CONSTRAINT observation_properties_object CHECK (
        jsonb_typeof(properties) = 'object'
    )
);

/*
  Study areas are stored separately so the same observation collection can be
  tested against different query extents.
*/
CREATE TABLE stcmp_experiment.study_area (
    area_id   text PRIMARY KEY,
    area_name text NOT NULL,
    geom      geometry(MultiPolygon, 25832) NOT NULL,
    description text,

    CONSTRAINT study_area_geom_nonempty CHECK (
        NOT ST_IsEmpty(geom)
    ),
    CONSTRAINT study_area_geom_valid CHECK (
        ST_IsValid(geom)
    ),
    CONSTRAINT study_area_geom_positive_area CHECK (
        ST_Area(geom) > 0
    )
);

/*
  Indexes:
  - GiST on geometry supports index-aware spatial candidate filtering.
  - GiST on tstzrange supports temporal range predicates.
  - B-tree on group_id supports group-constrained sequence generation.
*/
CREATE INDEX observation_geom_gix
    ON stcmp_experiment.observation USING GIST (geom);

CREATE INDEX observation_temporal_support_gix
    ON stcmp_experiment.observation USING GIST (temporal_support);

CREATE INDEX observation_group_id_idx
    ON stcmp_experiment.observation (group_id);

CREATE INDEX study_area_geom_gix
    ON stcmp_experiment.study_area USING GIST (geom);

/*=============================================================================
  STEP 2. SYNTHETIC INSTANCES
=============================================================================*/

/*
  Coordinate design
  -----------------
  Main study area A:
      X = 570000 .. 571000  (1000 m)
      Y = 6200000 .. 6200100 (100 m)
      Area = 100000 m^2

  For the main example, use a conceptual horizontal axis x=0..10, where
  x=0 corresponds to easting 570000 and one conceptual unit equals 100 m.
  All main footprints span the full 100 m north-south height.

  Thus:
      [0,6]  -> easting 570000..570600
      [4,6]  -> easting 570400..570600
      [4,10] -> easting 570400..571000
*/

INSERT INTO stcmp_experiment.study_area
    (area_id, area_name, geom, description)
VALUES
(
    'A',
    'Main synthetic study area',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    'Main 1000 m by 100 m test extent in EPSG:25832.'
),
(
    'A_WEST',
    'Western half of main area',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 570500, 6200100, 25832)),
    'Subarea for clipping and partial-coverage checks.'
),
(
    'A_EAST',
    'Eastern half of main area',
    ST_Multi(ST_MakeEnvelope(570500, 6200000, 571000, 6200100, 25832)),
    'Subarea for clipping and partial-coverage checks.'
);

/*----------------------------- 2.1 Groups ----------------------------------*/

INSERT INTO stcmp_experiment.observation_group
    (group_id, group_name, group_period, description, metadata)
VALUES
(
    'SURVEY_2015', 'Synthetic survey 2015',
    tstzrange('2015-01-01 00:00:00+00', '2016-01-01 00:00:00+00', '[)'),
    'Main sequence example; deliberately contains two footprint observations.',
    '{"scenario":"main_sequence"}'::jsonb
),
(
    'SURVEY_2017', 'Synthetic survey 2017',
    tstzrange('2017-01-01 00:00:00+00', '2018-01-01 00:00:00+00', '[)'),
    'Main sequence example.',
    '{"scenario":"main_sequence"}'::jsonb
),
(
    'SURVEY_2018', 'Synthetic survey 2018',
    tstzrange('2018-01-01 00:00:00+00', '2019-01-01 00:00:00+00', '[)'),
    'Main sequence example.',
    '{"scenario":"main_sequence"}'::jsonb
),
(
    'SURVEY_2020', 'Synthetic survey 2020',
    tstzrange('2020-01-01 00:00:00+00', '2021-01-01 00:00:00+00', '[)'),
    'Main sequence example.',
    '{"scenario":"main_sequence"}'::jsonb
),
(
    'CHAIN_2021', 'Pairwise-chain test 2021',
    tstzrange('2021-01-01 00:00:00+00', '2022-01-01 00:00:00+00', '[)'),
    'First footprint in a chain of pairwise overlaps with no three-way common area.',
    '{"scenario":"spatial_chain"}'::jsonb
),
(
    'CHAIN_2022', 'Pairwise-chain test 2022',
    tstzrange('2022-01-01 00:00:00+00', '2023-01-01 00:00:00+00', '[)'),
    'Middle footprint in a chain of pairwise overlaps with no three-way common area.',
    '{"scenario":"spatial_chain"}'::jsonb
),
(
    'CHAIN_2023', 'Pairwise-chain test 2023',
    tstzrange('2023-01-01 00:00:00+00', '2024-01-01 00:00:00+00', '[)'),
    'Last footprint in a chain of pairwise overlaps with no three-way common area.',
    '{"scenario":"spatial_chain"}'::jsonb
),
(
    'BOUNDARY_2021', 'Boundary-contact test 2021',
    tstzrange('2021-02-01 00:00:00+00', '2022-02-01 00:00:00+00', '[)'),
    'First footprint in a boundary-only contact test.',
    '{"scenario":"boundary_contact"}'::jsonb
),
(
    'BOUNDARY_2022', 'Boundary-contact test 2022',
    tstzrange('2022-02-01 00:00:00+00', '2023-02-01 00:00:00+00', '[)'),
    'Second footprint in a boundary-only contact test.',
    '{"scenario":"boundary_contact"}'::jsonb
),
(
    'SLIVER_2021', 'Small-overlap test 2021',
    tstzrange('2021-03-01 00:00:00+00', '2022-03-01 00:00:00+00', '[)'),
    'First footprint in a deliberately small positive-area overlap test.',
    '{"scenario":"small_overlap"}'::jsonb
),
(
    'SLIVER_2022', 'Small-overlap test 2022',
    tstzrange('2022-03-01 00:00:00+00', '2023-03-01 00:00:00+00', '[)'),
    'Second footprint in a deliberately small positive-area overlap test.',
    '{"scenario":"small_overlap"}'::jsonb
),
(
    'PARTIAL_2021', 'Partial-coverage test 2021',
    tstzrange('2021-04-01 00:00:00+00', '2022-04-01 00:00:00+00', '[)'),
    'Footprints partially outside the main study area.',
    '{"scenario":"partial_coverage"}'::jsonb
);

/*-------------------------- 2.2 Main sequence ------------------------------*/

/*
  Main four-observation spatial pattern:

     O15: [0,10]
     O17: [0, 6]
     O18: [4,10]
     O20: [0,10]

  Expected raw common supports (before prefix dominance):
     O15 & O17                         -> [0,6]
     O15 & O18                         -> [4,10]
     O15 & O17 & O18                   -> [4,6]
     O15 & O17 & O18 & O20             -> [4,6]
     O15 & O18 & O20                   -> [4,10]

  Main observations are instants, represented as singleton tstzrange values.
  O15_ALT is a second footprint in the same group as O15; it tests the
  one-observation-per-group constraint in the group-constrained variant.
*/
INSERT INTO stcmp_experiment.observation
    (observation_id, group_id, geom, temporal_support, properties)
VALUES
(
    'O15', 'SURVEY_2015',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2015-01-10 10:00:00+00', '2015-01-10 10:00:00+00', '[]'),
    '{"scenario":"main_sequence","role":"full_coverage"}'::jsonb
),
(
    'O15_ALT', 'SURVEY_2015',
    ST_Multi(ST_MakeEnvelope(570200, 6200000, 570800, 6200100, 25832)),
    tstzrange('2015-01-20 08:00:00+00', '2015-01-20 12:00:00+00', '[)'),
    '{"scenario":"main_sequence","role":"second_observation_same_group"}'::jsonb
),
(
    'O17', 'SURVEY_2017',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 570600, 6200100, 25832)),
    tstzrange('2017-01-10 10:00:00+00', '2017-01-10 10:00:00+00', '[]'),
    '{"scenario":"main_sequence","role":"western_coverage"}'::jsonb
),
(
    'O18', 'SURVEY_2018',
    ST_Multi(ST_MakeEnvelope(570400, 6200000, 571000, 6200100, 25832)),
    tstzrange('2018-01-10 10:00:00+00', '2018-01-10 10:00:00+00', '[]'),
    '{"scenario":"main_sequence","role":"eastern_coverage"}'::jsonb
),
(
    'O20', 'SURVEY_2020',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2020-01-10 10:00:00+00', '2020-01-10 10:00:00+00', '[]'),
    '{"scenario":"main_sequence","role":"full_coverage"}'::jsonb
);

/*---------------- 2.3 Pairwise-chain, but no 3-way support -----------------*/

/*
  A=[0,4], B=[3,7], C=[6,10].
  A intersects B with positive area; B intersects C with positive area;
  A and C are disjoint. Therefore A intersection B intersection C is empty.
  This catches algorithms that incorrectly infer a multiway support merely
  from a chain of pairwise overlaps.
*/
INSERT INTO stcmp_experiment.observation
    (observation_id, group_id, geom, temporal_support, properties)
VALUES
(
    'CHAIN_A', 'CHAIN_2021',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 570400, 6200100, 25832)),
    tstzrange('2021-01-10 10:00:00+00', '2021-01-10 10:00:00+00', '[]'),
    '{"scenario":"spatial_chain"}'::jsonb
),
(
    'CHAIN_B', 'CHAIN_2022',
    ST_Multi(ST_MakeEnvelope(570300, 6200000, 570700, 6200100, 25832)),
    tstzrange('2022-01-10 10:00:00+00', '2022-01-10 10:00:00+00', '[]'),
    '{"scenario":"spatial_chain"}'::jsonb
),
(
    'CHAIN_C', 'CHAIN_2023',
    ST_Multi(ST_MakeEnvelope(570600, 6200000, 571000, 6200100, 25832)),
    tstzrange('2023-01-10 10:00:00+00', '2023-01-10 10:00:00+00', '[]'),
    '{"scenario":"spatial_chain"}'::jsonb
);

/*---------------------- 2.4 Boundary-only contact --------------------------*/

/*
  BOUND_LEFT and BOUND_RIGHT share only the vertical boundary x=570200.
  ST_Intersects is TRUE, but the polygonal intersection has area 0.
*/
INSERT INTO stcmp_experiment.observation
    (observation_id, group_id, geom, temporal_support, properties)
VALUES
(
    'BOUND_LEFT', 'BOUNDARY_2021',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 570200, 6200100, 25832)),
    tstzrange('2021-02-10 10:00:00+00', '2021-02-10 10:00:00+00', '[]'),
    '{"scenario":"boundary_contact"}'::jsonb
),
(
    'BOUND_RIGHT', 'BOUNDARY_2022',
    ST_Multi(ST_MakeEnvelope(570200, 6200000, 570400, 6200100, 25832)),
    tstzrange('2022-02-10 10:00:00+00', '2022-02-10 10:00:00+00', '[]'),
    '{"scenario":"boundary_contact"}'::jsonb
);

/*--------------------- 2.5 Small positive-area overlap ---------------------*/

/*
  SLIVER_A: x=570000..570500.
  SLIVER_B: x=570499..570900.
  Their overlap is 1 m wide by 100 m high = 100 m^2.
  This tests p_min_common_area and protection against tiny sliver results.
*/
INSERT INTO stcmp_experiment.observation
    (observation_id, group_id, geom, temporal_support, properties)
VALUES
(
    'SLIVER_A', 'SLIVER_2021',
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 570500, 6200100, 25832)),
    tstzrange('2021-03-10 10:00:00+00', '2021-03-10 10:00:00+00', '[]'),
    '{"scenario":"small_overlap"}'::jsonb
),
(
    'SLIVER_B', 'SLIVER_2022',
    ST_Multi(ST_MakeEnvelope(570499, 6200000, 570900, 6200100, 25832)),
    tstzrange('2022-03-10 10:00:00+00', '2022-03-10 10:00:00+00', '[]'),
    '{"scenario":"small_overlap"}'::jsonb
);

/*---------------------- 2.6 Footprints outside A --------------------------*/

/*
  WEST_OUTSIDE spans x=569800..570200. After clipping to A, it becomes
  x=570000..570200 (200 m by 100 m = 20,000 m^2).
  EAST_OUTSIDE spans x=570900..571200. After clipping to A, it becomes
  x=570900..571000 (100 m by 100 m = 10,000 m^2).
*/
INSERT INTO stcmp_experiment.observation
    (observation_id, group_id, geom, temporal_support, properties)
VALUES
(
    'WEST_OUTSIDE', 'PARTIAL_2021',
    ST_Multi(ST_MakeEnvelope(569800, 6200000, 570200, 6200100, 25832)),
    tstzrange('2021-04-10 10:00:00+00', '2021-04-10 10:00:00+00', '[]'),
    '{"scenario":"partial_coverage","expected_clipped_area_m2":20000}'::jsonb
),
(
    'EAST_OUTSIDE', 'PARTIAL_2021',
    ST_Multi(ST_MakeEnvelope(570900, 6200000, 571200, 6200100, 25832)),
    tstzrange('2021-04-20 10:00:00+00', '2021-04-20 10:00:00+00', '[]'),
    '{"scenario":"partial_coverage","expected_clipped_area_m2":10000}'::jsonb
);

/*----------------- 2.7 Temporal semantics: instant/interval ---------------*/

/*
  All temporal-fixture observations have the same full study-area geometry.
  This isolates temporal ordering and temporal-distance semantics from
  spatial filtering. They are intentionally ungrouped (group_id NULL), so
  they are usable by the general time-based variant.

  Cases:
    T_II_1 / T_II_2: instant vs instant; elapsed = 2 days 3 hours.
    T_I_BEFORE / T_INTERVAL_1: instant before interval; gap = 1 day.
    T_INTERVAL_1 / T_I_AT_START: instant at included lower bound (overlap).
    T_INTERVAL_1 / T_I_INSIDE: instant lies inside interval (overlap).
    T_INTERVAL_1 / T_I_AT_END: instant at exclusive upper bound; gap = 0.
    T_RANGE_1 / T_RANGE_2: disjoint intervals; gap = 1 day.
    T_TOUCH_1 / T_TOUCH_2: touching intervals; gap = 0.
    T_OVERLAP_1 / T_OVERLAP_2: overlapping intervals.
    T_OUTER / T_INNER: one interval contains another; starts differ.
    T_EQUAL_START_1 / T_EQUAL_START_2: equal interval start times; strict start
      ordering must reject ordering these observations relative to one another.
    T_DUP_INSTANT_1 / T_DUP_INSTANT_2: identical instant supports.
    T_UNKNOWN: unknown temporal support; usable for coverage inspection only.
*/
INSERT INTO stcmp_experiment.observation
    (observation_id, group_id, geom, temporal_support, properties)
VALUES
(
    'T_II_1', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-01-01 10:00:00+00', '2024-01-01 10:00:00+00', '[]'),
    '{"scenario":"temporal_edge_cases","case":"instant_instant_first"}'::jsonb
),
(
    'T_II_2', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-01-03 13:00:00+00', '2024-01-03 13:00:00+00', '[]'),
    '{"scenario":"temporal_edge_cases","case":"instant_instant_second"}'::jsonb
),
(
    'T_I_BEFORE', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-02-01 08:00:00+00', '2024-02-01 08:00:00+00', '[]'),
    '{"scenario":"temporal_edge_cases","case":"instant_before_interval"}'::jsonb
),
(
    'T_INTERVAL_1', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-02-02 08:00:00+00', '2024-02-04 08:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"interval_for_mixed_tests"}'::jsonb
),
(
    'T_I_AT_START', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-02-02 08:00:00+00', '2024-02-02 08:00:00+00', '[]'),
    '{"scenario":"temporal_edge_cases","case":"instant_at_inclusive_interval_start"}'::jsonb
),
(
    'T_I_INSIDE', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-02-03 08:00:00+00', '2024-02-03 08:00:00+00', '[]'),
    '{"scenario":"temporal_edge_cases","case":"instant_inside_interval"}'::jsonb
),
(
    'T_I_AT_END', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-02-04 08:00:00+00', '2024-02-04 08:00:00+00', '[]'),
    '{"scenario":"temporal_edge_cases","case":"instant_at_exclusive_interval_end"}'::jsonb
),
(
    'T_RANGE_1', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-03-01 00:00:00+00', '2024-03-03 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"disjoint_interval_first"}'::jsonb
),
(
    'T_RANGE_2', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-03-04 00:00:00+00', '2024-03-06 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"disjoint_interval_second"}'::jsonb
),
(
    'T_TOUCH_1', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-04-01 00:00:00+00', '2024-04-02 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"touching_interval_first"}'::jsonb
),
(
    'T_TOUCH_2', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-04-02 00:00:00+00', '2024-04-04 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"touching_interval_second"}'::jsonb
),
(
    'T_OVERLAP_1', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-05-01 00:00:00+00', '2024-05-04 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"overlapping_interval_first"}'::jsonb
),
(
    'T_OVERLAP_2', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-05-03 00:00:00+00', '2024-05-06 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"overlapping_interval_second"}'::jsonb
),
(
    'T_OUTER', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-06-01 00:00:00+00', '2024-06-10 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"containing_interval"}'::jsonb
),
(
    'T_INNER', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-06-03 00:00:00+00', '2024-06-05 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"contained_interval"}'::jsonb
),
(
    'T_EQUAL_START_1', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-07-01 00:00:00+00', '2024-07-03 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"equal_start_first"}'::jsonb
),
(
    'T_EQUAL_START_2', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-07-01 00:00:00+00', '2024-07-02 00:00:00+00', '[)'),
    '{"scenario":"temporal_edge_cases","case":"equal_start_second"}'::jsonb
),
(
    'T_DUP_INSTANT_1', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-08-01 10:00:00+00', '2024-08-01 10:00:00+00', '[]'),
    '{"scenario":"temporal_edge_cases","case":"duplicate_instant_first"}'::jsonb
),
(
    'T_DUP_INSTANT_2', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    tstzrange('2024-08-01 10:00:00+00', '2024-08-01 10:00:00+00', '[]'),
    '{"scenario":"temporal_edge_cases","case":"duplicate_instant_second"}'::jsonb
),
(
    'T_UNKNOWN', NULL,
    ST_Multi(ST_MakeEnvelope(570000, 6200000, 571000, 6200100, 25832)),
    NULL,
    '{"scenario":"temporal_edge_cases","case":"unknown_temporal_support"}'::jsonb
);

/*=============================================================================
  STEP 3. CANONICAL VIEW AND SMALL SCENARIO VIEWS
=============================================================================*/

/*
  Canonical source interface:
    observation_id, group_id, group_name, group_period, geom,
    temporal_support, properties.

  A relational user schema can expose the same column names through a view.
  A document adapter should project/expand source documents into this shape.
*/
CREATE VIEW stcmp_experiment.v_observation_source AS
SELECT
    o.observation_id,
    o.group_id,
    g.group_name,
    g.group_period,
    o.geom,
    o.temporal_support,
    o.properties
FROM stcmp_experiment.observation AS o
LEFT JOIN stcmp_experiment.observation_group AS g
    ON g.group_id = o.group_id;

/* View isolating the four main example observations (plus same-group alt). */
CREATE VIEW stcmp_experiment.v_main_sequence AS
SELECT *
FROM stcmp_experiment.v_observation_source
WHERE properties ->> 'scenario' = 'main_sequence';

/* View isolating the pairwise-chain spatial case. */
CREATE VIEW stcmp_experiment.v_spatial_chain AS
SELECT *
FROM stcmp_experiment.v_observation_source
WHERE properties ->> 'scenario' = 'spatial_chain';

/* View isolating boundary-only intersections. */
CREATE VIEW stcmp_experiment.v_boundary_contact AS
SELECT *
FROM stcmp_experiment.v_observation_source
WHERE properties ->> 'scenario' = 'boundary_contact';

/* View isolating small positive-area overlap. */
CREATE VIEW stcmp_experiment.v_small_overlap AS
SELECT *
FROM stcmp_experiment.v_observation_source
WHERE properties ->> 'scenario' = 'small_overlap';

/* View isolating footprints partially outside the main study area. */
CREATE VIEW stcmp_experiment.v_partial_coverage AS
SELECT *
FROM stcmp_experiment.v_observation_source
WHERE properties ->> 'scenario' = 'partial_coverage';

/* View isolating instant/interval temporal edge cases. */
CREATE VIEW stcmp_experiment.v_temporal_edge_cases AS
SELECT *
FROM stcmp_experiment.v_observation_source
WHERE properties ->> 'scenario' = 'temporal_edge_cases';

/* Refresh planner statistics after bulk loading. */
ANALYZE stcmp_experiment.observation_group;
ANALYZE stcmp_experiment.observation;
ANALYZE stcmp_experiment.study_area;

/*=============================================================================
  STEP 4. SANITY-CHECK QUERIES WITH KNOWN EXPECTATIONS

  These are verification queries, not the implementation of the proposed
  ST_CoverageProfile or ST_ComparableAreas operators.
=============================================================================*/

/* 4.1 Inventory counts. Expected: 12 groups, 34 observations, 3 study areas. */
SELECT 'groups' AS object_type, count(*) AS row_count
FROM stcmp_experiment.observation_group
UNION ALL
SELECT 'observations', count(*)
FROM stcmp_experiment.observation
UNION ALL
SELECT 'study_areas', count(*)
FROM stcmp_experiment.study_area;

/* 4.2 Main four-way common support.
   Expected geometry: x=570400..570600, y=6200000..6200100.
   Expected area: 20,000 m^2.
*/
SELECT
    ST_AsText(
        ST_Intersection(
            ST_Intersection(
                ST_Intersection(o15.geom, o17.geom),
                o18.geom
            ),
            o20.geom
        )
    ) AS common_support_wkt,
    ST_Area(
        ST_Intersection(
            ST_Intersection(
                ST_Intersection(o15.geom, o17.geom),
                o18.geom
            ),
            o20.geom
        )
    ) AS common_area_m2
FROM stcmp_experiment.observation o15
JOIN stcmp_experiment.observation o17 ON o17.observation_id = 'O17'
JOIN stcmp_experiment.observation o18 ON o18.observation_id = 'O18'
JOIN stcmp_experiment.observation o20 ON o20.observation_id = 'O20'
WHERE o15.observation_id = 'O15';

/* 4.3 Pairwise chain but empty triple intersection.
   Expected: AB area=10,000 m^2; BC area=10,000 m^2; ABC area=0.
*/
WITH x AS (
    SELECT
        a.geom AS ga,
        b.geom AS gb,
        c.geom AS gc
    FROM stcmp_experiment.observation a
    JOIN stcmp_experiment.observation b ON b.observation_id = 'CHAIN_B'
    JOIN stcmp_experiment.observation c ON c.observation_id = 'CHAIN_C'
    WHERE a.observation_id = 'CHAIN_A'
)
SELECT
    ST_Area(ST_Intersection(ga, gb)) AS area_ab_m2,
    ST_Area(ST_Intersection(gb, gc)) AS area_bc_m2,
    ST_Area(ST_Intersection(ST_Intersection(ga, gb), gc)) AS area_abc_m2
FROM x;

/* 4.4 Boundary-only contact.
   Expected: intersects=true; intersection area=0.
*/
SELECT
    ST_Intersects(a.geom, b.geom) AS intersects_including_boundary,
    ST_Area(ST_Intersection(a.geom, b.geom)) AS intersection_area_m2
FROM stcmp_experiment.observation a
JOIN stcmp_experiment.observation b ON b.observation_id = 'BOUND_RIGHT'
WHERE a.observation_id = 'BOUND_LEFT';

/* 4.5 Small positive-area overlap.
   Expected intersection area: 100 m^2.
*/
SELECT
    ST_Area(ST_Intersection(a.geom, b.geom)) AS intersection_area_m2
FROM stcmp_experiment.observation a
JOIN stcmp_experiment.observation b ON b.observation_id = 'SLIVER_B'
WHERE a.observation_id = 'SLIVER_A';

/* 4.6 Partial coverage after clipping to A.
   Expected WEST_OUTSIDE clipped area: 20,000 m^2.
   Expected EAST_OUTSIDE clipped area: 10,000 m^2.
*/
SELECT
    o.observation_id,
    ST_Area(ST_Intersection(o.geom, a.geom)) AS clipped_area_m2,
    ST_AsText(ST_Intersection(o.geom, a.geom)) AS clipped_geom_wkt
FROM stcmp_experiment.observation o
CROSS JOIN stcmp_experiment.study_area a
WHERE a.area_id = 'A'
  AND o.observation_id IN ('WEST_OUTSIDE', 'EAST_OUTSIDE')
ORDER BY o.observation_id;

/* 4.7 Temporal test-case inventory. */
SELECT
    observation_id,
    temporal_support,
    CASE
        WHEN temporal_support IS NULL THEN 'unknown'
        WHEN lower(temporal_support) = upper(temporal_support) THEN 'instant'
        ELSE 'interval'
    END AS support_kind,
    properties ->> 'case' AS test_case
FROM stcmp_experiment.v_temporal_edge_cases
ORDER BY observation_id;

/* 4.8 Verify no invalid geometries or malformed non-NULL temporal supports. */
SELECT
    count(*) FILTER (WHERE NOT ST_IsValid(geom)) AS invalid_geometries,
    count(*) FILTER (WHERE ST_IsEmpty(geom)) AS empty_geometries,
    count(*) FILTER (WHERE temporal_support IS NULL) AS unknown_times
FROM stcmp_experiment.observation;

/* 4.9 Check that known observation supports fall within nominal group periods.
   Expected: zero rows. This is a data-quality check, not a table CHECK,
   because it depends on another relation.
*/
SELECT
    o.observation_id,
    o.group_id,
    o.temporal_support,
    g.group_period
FROM stcmp_experiment.observation AS o
JOIN stcmp_experiment.observation_group AS g USING (group_id)
WHERE o.temporal_support IS NOT NULL
  AND NOT (g.group_period @> o.temporal_support);

/* End of setup script. */
