# Hive-Partitioned External Tables

Query Parquet data already laid out on S3 or local disk in the Hive
`key=value/` convention — without copying, importing, or maintaining a
separate catalog.

---

## What this is for

You already have Parquet files sitting on S3 (or a local disk) written by
Spark, Hive, Trino, or another engine. The partitioning is encoded in the
directory structure:

```
s3://my-lake/warehouse/sales/
├── year=2023/
│   └── part-0.parquet
├── year=2024/
│   ├── part-0.parquet
│   └── part-1.parquet
└── year=2025/
    └── part-0.parquet
```

You want MatrixOne to treat this as a SQL table, with three properties:

1. **Zero copy** — MatrixOne reads directly from object storage; it never
   writes this data anywhere else.
2. **Virtual partition columns** — `year` lives only in the path, but SQL
   sees it as a regular column usable in `SELECT`, `WHERE`, `GROUP BY`,
   `ORDER BY`, and `JOIN`.
3. **Partition pruning** — `WHERE year = 2024` lists the root directory,
   lists the matching partition directory, and reads only the Parquet files
   inside that matching partition instead of opening files from every
   partition.

A single DDL statement opens this capability for common Hive-style layouts,
from small local test data to large S3-backed fact tables. Very wide or deep
partition trees are protected by safety limits, so highly selective partition
predicates are recommended for large datasets.

---

## Five-minute walkthrough

### 1. Declare the table

```sql
CREATE EXTERNAL TABLE sales (
    order_id  BIGINT,
    amount    DECIMAL(12,2),
    year      INT              -- partition column, must be listed here
) INFILE {
    'filepath'               = '/data/sales/',
    'format'                 = 'parquet',
    'hive_partitioning'      = 'true',
    'hive_partition_columns' = 'year'
};
```

Three things worth noting:

- The partition column is listed in the column definition like any other
  column. Its type determines how the directory value is parsed at query
  time.
- `filepath` points at the **root** of the partition tree, not a glob.
- `hive_partition_columns` enumerates the partition keys **from outer to
  inner**. For `year=.../month=.../day=.../` the value would be
  `'year,month,day'`.
- `hive_partitioning='false'` keeps the existing generic Parquet external
  table behavior. In that mode MatrixOne does not discover `key=value/`
  partitions or synthesize partition columns.

### 2. Query it

```sql
-- Scan everything
SELECT COUNT(*) FROM sales;

-- Partition pruning — only reads /data/sales/year=2024/
SELECT SUM(amount) FROM sales WHERE year = 2024;

-- IN list pruning — reads exactly three partition directories
SELECT year, COUNT(*) FROM sales
 WHERE year IN (2023, 2024, 2025)
 GROUP BY year;

-- Treat the partition column as a first-class column
SELECT year, SUM(amount) AS revenue
  FROM sales
 GROUP BY year
 ORDER BY year;
```

### 3. Point at S3

Swap `INFILE{...}` for `URL s3option{...}` — everything else is identical:

```sql
CREATE EXTERNAL TABLE sales (
    order_id  BIGINT,
    amount    DECIMAL(12,2),
    year      INT
) URL s3option {
    'endpoint'               = 'https://s3.amazonaws.com',
    'region'                 = 'us-west-2',
    'bucket'                 = 'my-lake',
    'access_key_id'          = '...',
    'secret_access_key'      = '...',
    'filepath'               = 'warehouse/sales/',
    'format'                 = 'parquet',
    'hive_partitioning'      = 'true',
    'hive_partition_columns' = 'year'
};
```

S3-compatible stores such as MinIO or Yandex Object Storage work the same
way; set `provider='minio'` and use the appropriate `endpoint`.

---

## Syntax reference

### Options

| Option                   | Type                        | Required | Purpose |
|--------------------------|-----------------------------|----------|---------|
| `hive_partitioning`      | `'true'` or `'false'`       | yes for this feature | Enables partition discovery. `'false'` behaves like any other Parquet external table. |
| `hive_partition_columns` | comma-separated identifiers | yes when enabled | Partition keys, ordered outer-to-inner. |
| `filepath`               | string                      | yes      | The **root directory** of the partition tree. No glob required. |
| `format`                 | `'parquet'`                 | yes      | Only Parquet is supported today. |

### Partition column rules

- Must be declared in the column list. The declared type governs how
  MatrixOne parses the directory value.
- Column names are case-insensitive and are normalized to lowercase
  internally. `hive_partition_columns='YEAR'` and
  `hive_partition_columns='year'` are equivalent.
- Partition columns should be ordinary declared columns. Hidden columns and
  VECTOR columns (`VECF32` / `VECF64`) are rejected.
- Cannot repeat (`'year,year'` is rejected).

### Partition directory name rules

Only path segments in `key=value` form are treated as partition directories.
For a table declared with `hive_partition_columns='year,month'`, MatrixOne
looks for `year=.../` at the first level and `month=.../` below each matching
`year` directory. Other directory names are ignored.

Partition directory names are treated as raw path segment text. MatrixOne
does **not** URL-decode values in this release:

```text
country=US%2FCA/      -- rejected, not decoded to country = 'US/CA'
```

The following names are rejected at query time:

- Any partition directory segment containing `%`.
- A partition key containing characters other than letters, digits, or `_`.
- A key or value equal to `.` or `..`.
- A key or value containing a path separator (`/` or `\`) or a control
  character.

Partition values may be empty (`country=/`) and will be parsed as the empty
string before type conversion. Files and directories whose names start with
`.` or `_` are skipped, so markers such as `_SUCCESS`, `.crc`, and
`_temporary/` do not become data files.

Only files whose names end with `.parquet` (case-insensitive) are read as
data. This covers common codec-suffixed names such as `foo.snappy.parquet`
and `foo.gzip.parquet`, because they still end in `.parquet`. Files with any
other extension found inside a partition directory — CSV sidecars, ORC
files, crc checksums named without a leading dot, files with no extension —
are silently skipped. If you drop non-Parquet data into a partition
directory expecting it to be read, the query will simply not see it.

### Multi-level partitions

The directory tree must match the declared column order exactly:

```
/data/sales/
├── year=2024/
│   ├── month=01/
│   │   └── part-0.parquet
│   └── month=02/
│       └── part-0.parquet
└── year=2025/
    └── month=01/
        └── part-0.parquet
```

```sql
CREATE EXTERNAL TABLE sales (
    order_id BIGINT, amount DECIMAL(12,2),
    year     INT,
    month    INT
) INFILE {
    'filepath'               = '/data/sales/',
    'format'                 = 'parquet',
    'hive_partitioning'      = 'true',
    'hive_partition_columns' = 'year,month'
};
```

The number of `key=value/` levels that MatrixOne discovers is capped by
`len(hive_partition_columns)`. At each level MatrixOne follows only
directories whose key matches the declared column for that level. At the
last declared level, MatrixOne lists files directly in that leaf directory
and reads only files ending in `.parquet`.

That means depth mismatches are conservative:

- **Tree deeper than declared.** Extra subdirectories below the last declared
  partition level are not recursively scanned. A file under
  `year=2024/month=01/region=us/part-0.parquet` is ignored when the table is
  declared with `hive_partition_columns='year,month'`.
- **Tree shallower than declared, or uneven across siblings.** Files that
  appear before all declared partition levels have been matched are ignored
  during discovery. MatrixOne does not synthesize missing partition values.

If a path is skipped because its depth does not match the declaration, it is
not an error and it does not contribute rows. If the actual depth is
intentional, either redeclare `hive_partition_columns` to match the real
layout or point `filepath` at the subtree you want to expose.

---

## How pruning works

### Directory-level pruning (fast path)

For these predicate shapes MatrixOne never opens a Parquet file it is
going to reject:

| Shape                        | Example                                             |
|------------------------------|-----------------------------------------------------|
| Equality                     | `WHERE year = 2024`                                 |
| `IN` list                    | `WHERE year IN (2023, 2024, 2025)`                  |
| AND across partition columns | `WHERE year = 2024 AND month = 1`                   |
| Outer-only predicate         | `WHERE year = 2024` on a `(year, month)` table — reads every month under `year=2024/` |

Pruning happens *before* any Parquet file is opened. On S3 this directly
translates to fewer `ListObjectsV1` and `GetObject` calls. For a single-level
table such as `year=.../`, an equality predicate normally costs:

- `1 List` on the table root to enumerate partition directories.
- `1 List` on the matching partition directory to enumerate Parquet files.
- One file read per matching Parquet file.

For a multi-level table, each constrained level adds one directory-list step,
and the final matching leaf directory is listed to collect files. MatrixOne
uses a conservative list-and-filter strategy rather than constructing target
prefixes directly, so zero-padded integers, case handling, and unsupported
types do not cause false-negative pruning.

### Row-level evaluation (correct but unpruned)

The following predicates are **not** pushed into directory pruning in this
release. They still produce correct results — MatrixOne evaluates them as
ordinary row filters after reading the files — but they fetch the full
dataset:

| Shape                    | Example                                                      |
|--------------------------|--------------------------------------------------------------|
| Range                    | `WHERE year > 2022`, `WHERE year BETWEEN 2020 AND 2024`      |
| OR                       | `WHERE year = 2020 OR year = 2024`                           |
| Negation                 | `WHERE year != 2024`, `WHERE year NOT IN (...)`              |
| Expressions / casts      | `WHERE year + 1 = 2025`, `WHERE CAST(year AS VARCHAR) = '2024'` |
| Partial string match     | `WHERE country LIKE 'U%'`                                    |
| JOIN-side runtime filter | `JOIN date_dim d ON sales.year = d.year`                     |

If you care about S3 cost, rewrite ranges into explicit `IN` lists whenever
the set of interesting partitions is small.

### Partition-column types and pruning

| Partition column type                                             | Directory-level pruning? |
|-------------------------------------------------------------------|-------------------------|
| Integer (`TINYINT` / `SMALLINT` / `INT` / `BIGINT`, signed or unsigned) | Yes. Leading-zero values (`month=01`) match `WHERE month = 1`. |
| `VARCHAR` / `CHAR` / `TEXT`                                       | Yes, on byte-exact equality. `month='01'` is not equal to `month='1'`; uncertain cases are kept and evaluated as row filters. |
| `BOOL`, `FLOAT`, `DOUBLE`, `DECIMAL`                              | Row filter only (normalization is not round-trip safe). |
| `DATE`, `DATETIME`, `TIMESTAMP`, `TIME`                           | Row filter only (format and time-zone normalization vary). |
| `JSON`, `UUID`, `ENUM`, `SET`, `BIT`, `BLOB`, `BINARY`, `DATALINK` | Row filter only. |

Integer and string partition keys benefit the most from pruning. Other
types still produce correct results and can be used as partition columns;
they just do not skip directories in this release.

### `__mo_filepath` filters

Hive-partitioned external tables can also use the external-file virtual column
`__mo_filepath`. MatrixOne applies filters in this order:

1. Partition directory pruning, using eligible partition predicates.
2. `__mo_filepath` filtering on the discovered file list.
3. Row-level SQL filters after reading the remaining files.

Example:

```sql
SELECT COUNT(*)
  FROM sales
 WHERE year = 2024
   AND __mo_filepath LIKE '%part-0007.parquet';
```

The `year = 2024` predicate narrows directory discovery first. The
`__mo_filepath` predicate then removes non-matching files inside the surviving
partition directories. If a query has only a `__mo_filepath` predicate and no
partition predicate, MatrixOne still has to discover partition directories
before it can filter the file list.

---

## Virtual partition columns in practice

Parquet files written by Spark or Hive normally do **not** store the
partition column — it's implicit in the path. MatrixOne synthesizes its
value for every row at read time:

```sql
-- SELECT exposes the partition column
SELECT year, month, amount FROM sales;

-- DESCRIBE lists it like any other column
DESCRIBE sales;

-- Projection returns synthesized partition values.
-- This is not a metadata-only partition listing: MatrixOne still opens
-- matching Parquet files to determine row counts.
SELECT DISTINCT year FROM sales;

-- JOIN against an internal dimension table
SELECT s.amount, d.label
  FROM sales s
  JOIN date_dim d ON s.year = d.d_year
 WHERE s.year IN (2023, 2024);
```

If a Parquet file happens to contain a physical column with the same name
as a partition column, **the path value wins** — the physical column is
ignored. This matches the behavior of Spark, Hive, and Trino.

When a query projects only partition columns or `__mo_filepath`, MatrixOne
does not read physical Parquet data columns. It still opens each matching
Parquet file and reads metadata so it can emit the correct number of SQL rows.
For example, `SELECT DISTINCT year FROM sales` is correct, but it is not a
cheap metadata-only command for listing partition names.

### Schema expectations across files

Hive partitioning does not add schema evolution in this release. All Parquet
files that survive pruning must contain every physical column referenced by
the query. If a projected physical column is missing from one partition's
file, the query fails with a column-not-found error for that file.

This is intentionally different from engines that fill missing evolved
columns with `NULL`. To query mixed-schema datasets reliably, project only
columns that exist in every matched file, or split the dataset into separate
external tables with compatible schemas.

---

## Nulls and `__HIVE_DEFAULT_PARTITION__`

The Hive convention for a null partition value is a special directory
named `__HIVE_DEFAULT_PARTITION__/`. MatrixOne handles it transparently:

| Partition column | Behavior on `year=__HIVE_DEFAULT_PARTITION__/` |
|------------------|------------------------------------------------|
| Nullable         | Rows from that directory carry SQL `NULL` in the partition column. |
| `NOT NULL`       | Query fails with a constraint-violation error that names the offending path. |

The marker is treated as a Hive-wide sentinel for every partition column type,
including `VARCHAR` / `TEXT`. If a real string partition value is literally
`__HIVE_DEFAULT_PARTITION__`, MatrixOne reads it as SQL `NULL` for Hive
compatibility.

```sql
-- Count rows in the null partition
SELECT COUNT(*) FROM events WHERE year IS NULL;

-- Replace null with a sentinel value at query time
SELECT COALESCE(year, -1) AS y, COUNT(*) FROM events GROUP BY y;
```

---

## Complete examples

### Local directory — monthly sales rollup

```sql
CREATE EXTERNAL TABLE sales (
    order_id  BIGINT,
    customer  VARCHAR(100),
    amount    DECIMAL(12,2),
    year      INT,
    month     INT
) INFILE {
    'filepath'               = '/data/sales/',
    'format'                 = 'parquet',
    'hive_partitioning'      = 'true',
    'hive_partition_columns' = 'year,month'
};

SELECT year, month,
       COUNT(*) AS orders,
       SUM(amount) AS revenue
  FROM sales
 WHERE year = 2024
 GROUP BY year, month
 ORDER BY month;
```

### S3 fact table joined with an internal dimension

```sql
CREATE EXTERNAL TABLE catalog_returns (
    cr_item_sk          INT,
    cr_order_number     BIGINT,
    cr_net_loss         DECIMAL(7,2),
    cr_returned_date_sk INT
) URL s3option {
    'endpoint'               = 'https://s3.amazonaws.com',
    'region'                 = 'us-west-2',
    'bucket'                 = 'tpcds-data',
    'filepath'               = 'catalog_returns/',
    'format'                 = 'parquet',
    'hive_partitioning'      = 'true',
    'hive_partition_columns' = 'cr_returned_date_sk'
};

CREATE TABLE date_dim (
    d_date_sk INT PRIMARY KEY,
    d_date    DATE,
    d_year    INT,
    d_month   INT
);

SELECT d.d_year, d.d_month,
       SUM(cr.cr_net_loss) AS total_loss
  FROM catalog_returns cr
  JOIN date_dim d ON cr.cr_returned_date_sk = d.d_date_sk
 WHERE cr.cr_returned_date_sk IN (2451911, 2451912, 2451913)
 GROUP BY d.d_year, d.d_month
 ORDER BY d.d_year, d.d_month;
```

### Event log with a null partition

```sql
CREATE EXTERNAL TABLE events (
    event_id BIGINT,
    user_id  BIGINT,
    ts       DATETIME,
    year     INT
) INFILE {
    'filepath'               = '/data/events/',
    'format'                 = 'parquet',
    'hive_partitioning'      = 'true',
    'hive_partition_columns' = 'year'
};

SELECT COALESCE(year, -1) AS y, COUNT(*) AS cnt
  FROM events
 GROUP BY y
 ORDER BY y;

SELECT * FROM events
 WHERE year IS NOT NULL AND year = 2024;
```

---

## Runnable smoke cases

The examples above use placeholder paths and credentials. The repository also
contains a runnable smoke script that validates the same user-guide patterns
against deterministic Parquet fixtures:

```bash
cd /path/to/matrixone
docs/hive/cases/hive_partition_user_guide_cases.bash
```

The script assumes `mo-service` is already running and reachable through the
MySQL protocol. It reads connection settings from the environment:

```bash
MYSQL_HOST=127.0.0.1 \
MYSQL_PORT=6001 \
MYSQL_USER=root \
MYSQL_PASS=111 \
docs/hive/cases/hive_partition_user_guide_cases.bash
```

### Local disk smoke case

The local case reads the checked-in fixture directory
`test/distributed/resources/hive_partition/` directly from disk. It creates a
multi-level Hive table and a null-partition table:

```sql
CREATE EXTERNAL TABLE local_sales (
    id     INT,
    amount DOUBLE,
    year   INT,
    month  VARCHAR(2)
) INFILE {
    'filepath'               = '<repo>/test/distributed/resources/hive_partition/multi_level/',
    'format'                 = 'parquet',
    'hive_partitioning'      = 'true',
    'hive_partition_columns' = 'year,month'
};

SELECT COUNT(*) FROM local_sales;
SELECT year, COUNT(*) FROM local_sales WHERE year = 2024 GROUP BY year;
SELECT month, COUNT(*) FROM local_sales WHERE month = '01' GROUP BY month;
SELECT COUNT(*) FROM local_sales
 WHERE year = 2024 AND __mo_filepath LIKE '%year=2024%';
```

Expected checks:

- Full scan: `18` rows.
- `year = 2024`: `9` rows.
- `month = '01'`: `6` rows across both years.
- `year = 2024 AND month = '01'`: `3` rows.
- `__mo_filepath` combined with `year = 2024`: `9` rows.
- `__HIVE_DEFAULT_PARTITION__` under `null_part/`: `2` rows where `year IS NULL`.

### MinIO smoke case

The MinIO case uploads the same fixture directory to an S3-compatible bucket
and runs the same query shape through `URL s3option`.

By default, the smoke script uses:

| Setting | Default |
|---------|---------|
| endpoint | `http://127.0.0.1:9000` |
| bucket | `mo-test` |
| prefix | `hive_partition_user_guide` |
| access key | `minioadmin` |
| secret key | `minioadmin` |

If MinIO is not already reachable at that endpoint, the script starts a local
MinIO process using `MINIO_BIN` or the cached binary under
`.tmp/hive_phase7/bin/minio` when present. It then uploads the fixtures with
`mc cp --recursive`.

The MinIO table uses this shape:

```sql
CREATE EXTERNAL TABLE minio_sales (
    id     INT,
    amount DOUBLE,
    year   INT,
    month  VARCHAR(2)
) URL s3option {
    'endpoint'               = 'http://127.0.0.1:9000',
    'access_key_id'          = 'minioadmin',
    'secret_access_key'      = 'minioadmin',
    'bucket'                 = 'mo-test',
    'filepath'               = 'hive_partition_user_guide/multi_level/',
    'region'                 = 'us-east-1',
    'provider'               = 'minio',
    'format'                 = 'parquet',
    'hive_partitioning'      = 'true',
    'hive_partition_columns' = 'year,month'
};

SELECT COUNT(*) FROM minio_sales;
SELECT year, month, COUNT(*)
  FROM minio_sales
 WHERE year = 2024 AND month = '01'
 GROUP BY year, month;
```

Expected checks are identical to the local multi-level case: `18` full-scan
rows, `9` rows under `year=2024`, and `3` rows under
`year=2024/month=01`.

---

## Verifying that pruning is working

`EXPLAIN` is a useful first check because it shows whether the partition
predicate is still attached to the external scan:

```sql
EXPLAIN SELECT * FROM sales WHERE year = 2024;
-- Look for:
--   External Scan on sales
--     Filter Cond: (sales.year = 2024)
```

MatrixOne deliberately keeps partition predicates as ordinary row filters
after using them for directory pruning. That double-filtering is a correctness
safety net, so seeing `Filter Cond: (sales.year = 2024)` does **not** by
itself prove that pruning happened.

`EXPLAIN ANALYZE` gives a better signal because it reports the rows produced
by the external scan:

```sql
EXPLAIN ANALYZE SELECT SUM(amount) FROM sales WHERE year = 2024;
-- inputRows on the External Scan node should equal one partition's row
-- count. If it equals the whole-table count, the predicate is not being
-- pruned — check the row-level-evaluation section above.
```

On S3, the most reliable verification is request tracing. Enable server-side
access logging, or run `mc admin trace` for MinIO, and compare the request
count between a pruned query and a full scan. For a single-level equality
query with one matching file, expect roughly `2 List` plus `1 Get`. If the
matching partition contains multiple Parquet files, `Get` scales with the
number of matched files.

### Watching the server log for a capacity warning

MatrixOne emits a single WARN line per query when partition discovery
crosses 5,000 partitions — well below the 50,000 hard cap, but already
large enough that a missing or ineffective partition predicate is worth
investigating:

```
hive partition discovery: partition count exceeds 5000 (current: 7342, base: /data/sales/); consider adding partition filters
```

Seeing this line is not itself an error — the query still runs — but it is
the cheapest early signal that a query is walking the whole partition tree.
If the workload routinely trips it, either tighten the partition predicate,
narrow `filepath` to a sub-tree, or treat the 10,000-list-call and
50,000-partition ceilings as real risks for this table.

---

## Common pitfalls

### DDL errors

| Error message                                                                 | Cause                                                          |
|-------------------------------------------------------------------------------|----------------------------------------------------------------|
| `hive_partition_columns is required when hive_partitioning is enabled`        | `hive_partitioning='true'` was set but no columns listed.      |
| `hive_partition_columns requires hive_partitioning='true'`                    | Partition columns were specified while Hive partitioning was absent or set to `false`. |
| `hive_partitioning currently only supports format='parquet'`                  | `format='csv'` / `'jsonline'` combined with `hive_partitioning`. |
| `hive_partitioning must be 'true' or 'false'`                                 | The option value must be the literal string `true` or `false`. |
| `partition column 'X' not found in table columns`                             | Partition column missing from the column list.                 |
| `duplicate option key 'hive_partitioning'`                                    | The same key appears twice in the option block.                |
| `partition column 'X' cannot be a VECTOR type`                                | VECTOR types are not supported as partition keys.              |
| `hive_partitioning does not support stage external tables`                    | Stage URIs (`stage://...`) cannot be combined with hive partitioning in this release. |
| `duplicate partition column 'X'`                                              | `hive_partition_columns='year,year'`.                          |

### Query-time errors

| Error message                                                                                              | Meaning                                                                       |
|------------------------------------------------------------------------------------------------------------|-------------------------------------------------------------------------------|
| `hive partition directory name contains '%' which is not supported`                                        | URL-encoded characters in directory names are not handled in this release.    |
| `invalid hive partition key 'X': only letters, digits, and '_' are allowed`                               | A partition directory key contains unsupported characters. Rename the directory or declare a compatible key. |
| `invalid hive partition value 'X': path traversal segment is not allowed`                                  | Partition value `.` or `..` is rejected for path-safety reasons.              |
| `invalid hive partition value 'X': path separator is not allowed`                                          | Partition values containing `/` or `\` are not supported; URL-encoded values are also rejected. |
| `partition value type conversion failed: col=year, value='abc', path=year=abc/data.parquet`                | A directory value cannot be parsed into the declared partition-column type.   |
| `partition column 'month' not found in path ...`                                                           | A file selected for reading does not contain the declared partition segment in its path. Check that `filepath` and `hive_partition_columns` match the real layout. |
| `partition column 'year' is NOT NULL but directory has __HIVE_DEFAULT_PARTITION__ in path ...`             | The table declared a `NOT NULL` partition column, but the data contains the null-marker directory. Either allow nulls or remove/rename the directory. |
| `cannot insert/update/delete from external table`                                                          | External tables are read-only. Use a regular table for writes.                |
| `hive partition discovery exceeded 50000 partitions`                                                       | Safety cap on total discovered partitions. Add a partition predicate.         |
| `hive partition discovery exceeded 10000 List calls`                                                       | Safety cap on directory listings. Deep or very wide trees without predicates trigger this. Add a partition predicate or narrow `filepath`. |

### Tuning and correctness

**My query is slow — is pruning working?**

1. `EXPLAIN` the query and confirm a `Filter Cond` with the partition
   column is present on the external scan.
2. `EXPLAIN ANALYZE` and read `inputRows` on the scan node. If it equals
   the whole-table count, the predicate is hitting the row-level
   evaluation path; rewrite it as equality or `IN`.
3. On S3, diff the `ListObjectsV1` / `GetObject` counts between the
   pruned and full-scan queries.

**Why does a query with only `__mo_filepath` still list many directories?**

`__mo_filepath` filters are applied after Hive partition discovery has built
the candidate file list. Add an eligible partition predicate, such as
`year = 2024` or `year IN (...)`, when you want to reduce directory-listing
work as well as file reads.

**`WHERE dt = '2024-01-01'` still reads every partition — why?**

Date, timestamp, and decimal partition columns are not used for directory
pruning in this release. Either declare the partition column as `INT`
(e.g. `20240101`) or `VARCHAR` with a consistent string form, or accept
the row-level evaluation cost.

**Do I need to worry about `_SUCCESS`, `.crc`, or `_temporary/`?**

No. Files and directories whose names start with `.` or `_` are skipped
automatically — matching the convention used by Hive and Spark.

**A partition directory appeared with a value my query doesn't want.**

Rename it with a leading underscore (`_old_year=2020/`) to hide it, or
filter it out with a SQL predicate. MatrixOne has no per-table partition
blocklist.

**One partition has an older Parquet schema. Will MatrixOne fill missing
columns with NULL?**

No. Schema evolution is outside this release. If a query references a
physical column that is missing from any matched Parquet file, the query
fails. Partition columns are different: they may be absent from Parquet files
because MatrixOne fills them from the path.

---

## Interop with other engines

Data written by Hive, Spark, Trino, or StarRocks in the standard
`key=value/` layout is directly readable by MatrixOne when the partition
directory names follow the raw-segment rules described above. Datasets that
depend on URL-encoded partition values, such as `country=US%2FCA/`, are
rejected in this release.

Conversely, this release does not write back to the dataset — external tables
are read-only. Catalog integrations (Hive Metastore, AWS Glue, Unity Catalog)
are not part of this release either; the table definition lives in MatrixOne's
own catalog via `CREATE EXTERNAL TABLE`.

---

## Current limitations

| Area                                     | Status                                                                 |
|------------------------------------------|------------------------------------------------------------------------|
| Parquet format                           | Supported. CSV / JSONLINE partitioned tables are not.                  |
| Partition pruning on range / OR / casts  | Not pruned; evaluated as row filters (correct results, full I/O).      |
| Pruning on DATE / TIMESTAMP / DECIMAL / FLOAT / BOOL partition columns | Not pruned; evaluated as row filters.                                  |
| URL-encoded directory names              | Rejected at query time with an explicit error.                         |
| Unsafe partition segment names           | Keys must use letters, digits, and `_`; keys and values cannot be `.`, `..`, contain path separators, `%`, or control characters. |
| Schema evolution                         | Not supported. Missing physical columns in matched files fail instead of being filled with `NULL`. |
| Stage URIs (`stage://...`)               | Rejected at DDL.                                                       |
| Writes (`INSERT` / `LOAD DATA` / etc.)    | Rejected; external tables are read-only.                               |
| Partition-count cap                      | Single WARN log above 5,000 discovered partitions; hard error above 50,000. |
| List-call cap                             | Hard error above 10,000 directory listings per query. Very wide full scans can hit this even when the partition count is below 50,000. |
| Partition-depth rule                     | Discovery follows at most `len(hive_partition_columns)` `key=value` levels. Files in deeper subdirectories or shallower uneven paths are skipped unless `filepath` / `hive_partition_columns` are adjusted to match that layout. |
| Data-file extension filter               | Only files ending in `.parquet` (case-insensitive, includes `*.snappy.parquet`) are read inside partition directories. Other files are silently skipped. |
| Distributed execution                    | Partition discovery runs during planning. S3 file reads can fan out across CNs by file; local-path reads require the path to be visible where the scan runs. |
| Catalog integration                      | No Hive Metastore / Glue / Unity Catalog integration; use `CREATE EXTERNAL TABLE` locally. |
