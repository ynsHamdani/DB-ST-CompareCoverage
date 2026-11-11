# Spatiotemporal Comparable Areas in PostgreSQL/PostGIS

This repository contains the PostgreSQL/PostGIS implementation and tests for **ST_CoverageProfile** and **ST_ComparableAreasByTime**, together with a synthetic correctness fixture and a scaling experiment.

## Requirements

- PostgreSQL with PostGIS installed.
- A database in which you can create schemas, functions, tables, and the PostGIS extension.
- `psql`, pgAdmin, or another PostgreSQL client.

The SQL examples use **EPSG:25832** (projected metres). The observations and study areas in the correctness fixture are synthetic.

## Quick start

Run the following scripts, in order, against the **same test database**:

1. **Create the synthetic test data**

   ```bash
   psql -h your_host -p 5432 -U your_user -d your_database -v ON_ERROR_STOP=1 -f correctness_test/st_comparableareas_experiment_setup.sql
   ```

2. **Install and test `ST_CoverageProfile`**

   ```bash
   psql -h your_host -p 5432 -U your_user -d your_database -v ON_ERROR_STOP=1 -f functions_imp_test/st_coverage_profile_implementation_tests.sql
   ```

   The script creates the function and runs its sanity checks. The success message is:
   `ST_CoverageProfile: all 11 sanity tests passed`.

3. **Install and test `ST_ComparableAreasByTime` (v2)**

   ```bash
   psql -h your_host -p 5432 -U your_user -d your_database -v ON_ERROR_STOP=1 -f functions_imp_test/st_comparable_areas_by_time_v2.sql
   ```

   This installs the ordering-mode type and the v2 function, then runs its sanity checks. The success message is:
   `ST_ComparableAreasByTime v2: all 14 sanity tests passed`.

Run each command from the repository root. Replace `your_host`, `your_user`, and `your_database` with your connection details. Alternatively, open each `.sql` file in pgAdmin or DBeaver and execute the complete script in the same database, following the order above.

> **Important:** The first script drops and recreates the schema `stcmp_experiment`. Run it only in a dedicated test database, or remove/adjust the `DROP SCHEMA` statement before using a database that contains data you need to keep.

## Run a query

After the three setup scripts have completed, this example runs the v2 operator against the bundled synthetic fixture:

```sql
SELECT
    r.sequence_length,
    r.observation_sequence,
    r.common_area,
    r.has_valid_extension,
    r.common_support_geom AS geom
FROM stcmp_experiment.st_comparable_areas_by_time(
    p_source                => 'stcmp_experiment.v_main_sequence'::regclass,
    p_observation_id_column => 'observation_id',
    p_geom_column           => 'geom',
    p_time_column           => 'temporal_support',
    p_study_area            => (
        SELECT geom
        FROM stcmp_experiment.study_area
        WHERE area_id = 'A'
    ),
    p_order_mode            => 'nonoverlapping_ordered',
    p_group_column          => 'group_id',
    p_min_sequence_length   => 2,
    p_max_sequence_length   => NULL,
    p_min_common_area       => 0,
    p_min_elapsed           => NULL,
    p_max_elapsed           => INTERVAL '1100 days',
    p_time_window           => NULL
) AS r
ORDER BY r.sequence_length, r.observation_sequence::text;
```

`common_support_geom` is the native PostGIS geometry of the common spatial support. For GIS software, keep it as a geometry column (as `geom` above); do not convert it to WKT if you need to display or spatially process it.

## Run the scaling experiment

Run this only after the two functions above have been installed and tested:

```bash
psql -h your_host -p 5432 -U your_user -d your_database -v ON_ERROR_STOP=1 -f scaling-experiments/st_comparability_scaling_experiment.sql
```

The script creates three deterministic workloads (dense, temporally selective, and spatially selective), with 10, 20, 30, and 40 observations. It performs one warm-up and three measured runs for each workload/size combination, and checks the returned pair/triple counts and common-area totals against independently derived expected results.

To inspect the latest results:

```sql
SELECT
    workload,
    n_obs,
    median_runtime_ms,
    min_runtime_ms,
    max_runtime_ms,
    actual_sequences,
    all_repetitions_correct
FROM stcmp_bench_eval.v_latest_batch_summary
ORDER BY workload, n_obs;
```

For a graph, query one workload at a time, for example:

```sql
SELECT n_obs, median_runtime_ms, min_runtime_ms, max_runtime_ms, actual_sequences
FROM stcmp_bench_eval.v_latest_batch_summary
WHERE workload = 'W1_DENSE'
ORDER BY n_obs;
```

Export the result grid to CSV in pgAdmin/DBeaver, or use `\copy` in `psql` to save it. The benchmark schema `stcmp_bench_eval` is dropped and recreated each time the scaling script runs. The benchmark measures server-side function execution and result aggregation; it excludes client/network transfer and GIS rendering. It is a warm-cache microbenchmark, not a comparison against another implementation.

## Repository contents

```text
correctness_test/
  st_comparableareas_experiment_setup.sql
      Creates the synthetic observations, study areas, groups, and scenario views.

functions_imp_test/
  st_coverage_profile_implementation_tests.sql
      Installs ST_CoverageProfile and runs its implementation tests.
  st_comparable_areas_by_time_v2.sql
      Installs ST_ComparableAreasByTime v2 and runs its sanity tests.

scaling-experiments/
  st_comparability_scaling_experiment.sql
      Builds synthetic workloads, measures runtime, validates results, and
      creates graph-ready summary views.

usage-examples/
  st_comparable_areas_by_time_usage_examples.sql
      Earlier direct-usage examples.

path_lidar_metadata.txt
  Local metadata reference; it is not required to run the SQL scripts.
```

**Note on the usage examples:** `usage-examples/st_comparable_areas_by_time_usage_examples.sql` still refers to the earlier `effective_area` and `effective_support_geom` output columns. These are not part of the current v2 function return type. Use the v2 query in this README, or update those examples to select `common_area` and `common_support_geom` before executing that file.
