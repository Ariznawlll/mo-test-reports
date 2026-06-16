#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Prepare MatrixOne checkpoint-dump coverage data.

This script creates four focused databases:
  <prefix>_types        data types and boundary values
  <prefix>_constraints  defaults, PK/UK/FK, comments, indexes
  <prefix>_tables       table shapes: empty, view, CTAS, LIKE, partition, special names
  <prefix>_mvcc_perf    DML history, alter/truncate, scale rows, wide table

Usage:
  ./prepare_ckp_dump_coverage_data.sh [options]

Options:
  --host HOST             MySQL host, default: 127.0.0.1
  --port PORT             MySQL port, default: 6001
  --user USER             MySQL user, default: dump
  --password PASSWORD     MySQL password, default: 111
  --db-prefix PREFIX      Database prefix. Default: ckp_cov_<timestamp>
  --scale N               Rows for scale tables. Default: 10000, max generated: 1000000
  --drop-existing         Drop target databases before creating them
  --mysql-bin PATH        mysql client path, default: mysql
  --out-dir DIR           SQL/log output directory, default: /tmp/ckp_dump_coverage_<timestamp>
  --generate-only         Only generate SQL files, do not execute them
  --help                  Show this help

Examples:
  # Safe default: creates timestamped databases.
  ./prepare_ckp_dump_coverage_data.sh --host 127.0.0.1 --port 6001 --user dump --password 111

  # Stable database names for repeated checkpoint dump tests.
  ./prepare_ckp_dump_coverage_data.sh --db-prefix ckp --scale 100000 --drop-existing
USAGE
}

HOST="127.0.0.1"
PORT="6001"
USER="dump"
PASSWORD="111"
MYSQL_BIN="mysql"
TS="$(date +%Y%m%d_%H%M%S)"
DB_PREFIX="ckp_cov_${TS}"
SCALE="10000"
DROP_EXISTING="0"
GENERATE_ONLY="0"
OUT_DIR="/tmp/ckp_dump_coverage_${TS}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --db-prefix) DB_PREFIX="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --drop-existing) DROP_EXISTING="1"; shift ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --out-dir) OUT_DIR="$2"; shift 2 ;;
    --generate-only) GENERATE_ONLY="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

if ! [[ "$SCALE" =~ ^[0-9]+$ ]]; then
  echo "--scale must be a positive integer" >&2
  exit 2
fi
if (( SCALE < 1 )); then
  echo "--scale must be >= 1" >&2
  exit 2
fi
if (( SCALE > 1000000 )); then
  echo "--scale currently supports up to 1000000 rows" >&2
  exit 2
fi

DB_TYPES="${DB_PREFIX}_types"
DB_CONS="${DB_PREFIX}_constraints"
DB_TABLES="${DB_PREFIX}_tables"
DB_MVCC="${DB_PREFIX}_mvcc_perf"
DB_UTIL="${DB_PREFIX}_util"

mkdir -p "$OUT_DIR"

mysql_base_args=(
  -h"$HOST"
  -P"$PORT"
  -u"$USER"
  --default-character-set=utf8mb4
  --show-warnings
  --comments
)

run_sql() {
  local label="$1"
  local file="$2"
  local force="${3:-0}"
  local log="$OUT_DIR/${label}.log"

  echo "==> Running $label: $file"
  if [[ "$force" == "1" ]]; then
    MYSQL_PWD="$PASSWORD" "$MYSQL_BIN" "${mysql_base_args[@]}" --force < "$file" 2>&1 | tee "$log"
  else
    MYSQL_PWD="$PASSWORD" "$MYSQL_BIN" "${mysql_base_args[@]}" < "$file" 2>&1 | tee "$log"
  fi
}

drop_stmt() {
  if [[ "$DROP_EXISTING" == "1" ]]; then
    cat <<SQL
DROP DATABASE IF EXISTS \`$DB_TYPES\`;
DROP DATABASE IF EXISTS \`$DB_CONS\`;
DROP DATABASE IF EXISTS \`$DB_TABLES\`;
DROP DATABASE IF EXISTS \`$DB_MVCC\`;
DROP DATABASE IF EXISTS \`$DB_UTIL\`;
SQL
  fi
}

cat > "$OUT_DIR/00_create_util.sql" <<SQL
$(drop_stmt)

CREATE DATABASE IF NOT EXISTS \`$DB_UTIL\`;
USE \`$DB_UTIL\`;

DROP TABLE IF EXISTS seq_10;
CREATE TABLE seq_10 (n INT NOT NULL PRIMARY KEY);
INSERT INTO seq_10 VALUES (0),(1),(2),(3),(4),(5),(6),(7),(8),(9);

DROP TABLE IF EXISTS seq;
CREATE TABLE seq AS
SELECT n
FROM (
  SELECT
    a.n
    + b.n * 10
    + c.n * 100
    + d.n * 1000
    + e.n * 10000
    + f.n * 100000 AS n
  FROM seq_10 a
  CROSS JOIN seq_10 b
  CROSS JOIN seq_10 c
  CROSS JOIN seq_10 d
  CROSS JOIN seq_10 e
  CROSS JOIN seq_10 f
) s
WHERE n < $SCALE;

SELECT 'util.seq rows' AS item, COUNT(*) AS rows FROM seq;
SQL

cat > "$OUT_DIR/10_types_core.sql" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_TYPES\`;
USE \`$DB_TYPES\`;

DROP TABLE IF EXISTS t_int_signed;
CREATE TABLE t_int_signed (
  id INT NOT NULL PRIMARY KEY,
  c_tiny TINYINT NULL,
  c_small SMALLINT NULL,
  c_int INT NULL,
  c_big BIGINT NULL
);
INSERT INTO t_int_signed VALUES
  (1, -128, -32768, -2147483648, -9223372036854775808),
  (2, 0, 0, 0, 0),
  (3, 127, 32767, 2147483647, 9223372036854775807),
  (4, NULL, NULL, NULL, NULL);

DROP TABLE IF EXISTS t_int_unsigned;
CREATE TABLE t_int_unsigned (
  id INT NOT NULL PRIMARY KEY,
  c_tiny TINYINT UNSIGNED NULL,
  c_small SMALLINT UNSIGNED NULL,
  c_int INT UNSIGNED NULL,
  c_big BIGINT UNSIGNED NULL
);
INSERT INTO t_int_unsigned VALUES
  (1, 0, 0, 0, 0),
  (2, 255, 65535, 4294967295, 18446744073709551615),
  (3, NULL, NULL, NULL, NULL);

DROP TABLE IF EXISTS t_float_decimal;
CREATE TABLE t_float_decimal (
  id INT NOT NULL PRIMARY KEY,
  c_float FLOAT NULL,
  c_double DOUBLE NULL,
  c_dec_5_2 DECIMAL(5,2) NULL,
  c_dec_38_18 DECIMAL(38,18) NULL
);
INSERT INTO t_float_decimal VALUES
  (1, -1.5, -1.5, -999.99, -99999999999999999999.999999999999999999),
  (2, 0, 0, 0.00, 0.000000000000000001),
  (3, 1.2345, 1.234567890123, 999.99, 99999999999999999999.999999999999999999),
  (4, 1.0e-20, 1.0e-200, NULL, NULL);

DROP TABLE IF EXISTS t_bool_bit;
CREATE TABLE t_bool_bit (
  id INT NOT NULL PRIMARY KEY,
  c_bool BOOL NULL,
  c_boolean BOOLEAN NULL,
  c_bit1 BIT(1) NULL,
  c_bit8 BIT(8) NULL,
  c_bit64 BIT(64) NULL
);
INSERT INTO t_bool_bit VALUES
  (1, true, false, b'1', b'11111111', b'1111111111111111111111111111111111111111111111111111111111111111'),
  (2, false, true, b'0', b'00000000', b'0'),
  (3, NULL, NULL, NULL, NULL, NULL);

DROP TABLE IF EXISTS t_strings;
CREATE TABLE t_strings (
  id INT NOT NULL PRIMARY KEY,
  c_char CHAR(20) NULL,
  c_varchar VARCHAR(255) NULL,
  c_text TEXT NULL,
  c_json JSON NULL
);
INSERT INTO t_strings VALUES
  (1, '', '', '', '{"kind":"empty"}'),
  (2, 'tail-space   ', CONCAT('comma,double-quote",single-quote'',backslash', CHAR(92)), CONCAT('line1', CHAR(10), 'line2,"quote",''single'''), '{"a":1,"b":[true,false,null],"text":"quote comma"}'),
  (3, CONVERT(UNHEX('E4B8ADE69687') USING utf8mb4), CONCAT('utf8-', CONVERT(UNHEX('E4B8ADE69687') USING utf8mb4)), REPEAT('x', 1024), '{"nested":{"n":123,"s":"text"}}'),
  (4, NULL, NULL, NULL, NULL);

DROP TABLE IF EXISTS t_binary_blob;
CREATE TABLE t_binary_blob (
  id INT NOT NULL PRIMARY KEY,
  c_binary BINARY(8) NULL,
  c_varbinary VARBINARY(32) NULL,
  c_blob BLOB NULL
);
INSERT INTO t_binary_blob VALUES
  (1, UNHEX('0001020304050607'), UNHEX('00FF10AB'), UNHEX(REPEAT('AB', 1024))),
  (2, UNHEX('FFFFFFFFFFFFFFFF'), UNHEX(''), UNHEX('00')),
  (3, NULL, NULL, NULL);

DROP TABLE IF EXISTS t_temporal;
CREATE TABLE t_temporal (
  id INT NOT NULL PRIMARY KEY,
  c_date DATE NULL,
  c_time TIME NULL,
  c_time6 TIME(6) NULL,
  c_datetime DATETIME NULL,
  c_datetime3 DATETIME(3) NULL,
  c_datetime6 DATETIME(6) NULL,
  c_timestamp TIMESTAMP NULL,
  c_timestamp6 TIMESTAMP(6) NULL,
  c_year YEAR NULL
);
INSERT INTO t_temporal VALUES
  (1, '1970-01-01', '00:00:00', '00:00:00.000001', '1970-01-01 00:00:00', '2024-02-29 12:34:56.789', '2024-02-29 12:34:56.789123', '2024-02-29 12:34:56', '2024-02-29 12:34:56.789123', 1901),
  (2, '2024-02-29', '23:59:59', '23:59:59.999999', '2038-01-19 03:14:07', '2000-01-01 00:00:00.123', '2000-01-01 00:00:00.123456', '2038-01-19 03:14:07', '2000-01-01 00:00:00.123456', 2155),
  (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

DROP TABLE IF EXISTS t_defaults;
CREATE TABLE t_defaults (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  c_int INT DEFAULT 7,
  c_str VARCHAR(30) DEFAULT 'abc',
  c_dt DATETIME DEFAULT CURRENT_TIMESTAMP,
  c_null VARCHAR(30) NULL DEFAULT NULL
);
INSERT INTO t_defaults(c_null) VALUES (NULL), ('explicit');
INSERT INTO t_defaults(id, c_int, c_str, c_dt, c_null) VALUES (100, 9, 'manual', '2024-01-01 00:00:00', 'manual-row');

DROP TABLE IF EXISTS t_all_wide;
CREATE TABLE t_all_wide (
  id INT NOT NULL PRIMARY KEY,
  c_tiny TINYINT,
  c_small SMALLINT,
  c_int INT,
  c_big BIGINT,
  c_uint BIGINT UNSIGNED,
  c_float FLOAT,
  c_double DOUBLE,
  c_decimal DECIMAL(20,6),
  c_bool BOOL,
  c_char CHAR(10),
  c_varchar VARCHAR(200),
  c_text TEXT,
  c_blob BLOB,
  c_date DATE,
  c_time TIME(6),
  c_datetime DATETIME(6),
  c_timestamp TIMESTAMP(6),
  c_year YEAR,
  c_json JSON
);
INSERT INTO t_all_wide VALUES
  (1, -1, -2, -3, -4, 4, 1.25, 2.5, 12345.678901, true, 'char', 'varchar,quote"', 'text\nline', UNHEX('00FF'), '2024-02-29', '12:34:56.123456', '2024-02-29 12:34:56.123456', '2024-02-29 12:34:56.123456', 2024, '{"wide":true}'),
  (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema = '$DB_TYPES' ORDER BY table_name;
SQL

cat > "$OUT_DIR/11_types_optional.sql" <<SQL
USE \`$DB_TYPES\`;

DROP TABLE IF EXISTS t_enum_set;
CREATE TABLE t_enum_set (
  id INT NOT NULL PRIMARY KEY,
  c_enum ENUM('red','green','blue') NULL,
  c_set SET('a','b','c') NULL
);
INSERT INTO t_enum_set VALUES
  (1, 'red', 'a'),
  (2, 'green', 'a,b'),
  (3, NULL, NULL),
  (4, 'blue', '');

DROP TABLE IF EXISTS t_uuid;
CREATE TABLE t_uuid (
  id INT NOT NULL PRIMARY KEY,
  c_uuid UUID NULL
);
INSERT INTO t_uuid VALUES
  (1, '00000000-0000-0000-0000-000000000000'),
  (2, '123e4567-e89b-12d3-a456-426614174000'),
  (3, NULL);

DROP TABLE IF EXISTS t_vector_vecf32;
CREATE TABLE t_vector_vecf32 (
  id INT NOT NULL PRIMARY KEY,
  embedding VECF32(3) NULL
);
INSERT INTO t_vector_vecf32 VALUES
  (1, '[1,2,3]'),
  (2, '[0.1,0.2,0.3]'),
  (3, '[0,0,0]'),
  (4, NULL);

DROP TABLE IF EXISTS t_array;
CREATE TABLE t_array (
  id INT NOT NULL PRIMARY KEY,
  tags ARRAY(VARCHAR(20)) NULL
);
INSERT INTO t_array VALUES
  (1, '["a","b"]'),
  (2, '[]'),
  (3, NULL);

DROP TABLE IF EXISTS t_datalink;
CREATE TABLE t_datalink (
  id INT NOT NULL PRIMARY KEY,
  c_link DATALINK NULL
);
INSERT INTO t_datalink VALUES
  (1, NULL);
SQL

cat > "$OUT_DIR/20_constraints.sql" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_CONS\`;
USE \`$DB_CONS\`;

DROP TABLE IF EXISTS child_set_null;
DROP TABLE IF EXISTS child_cascade;
DROP TABLE IF EXISTS child_restrict;
DROP TABLE IF EXISTS parent;

CREATE TABLE parent (
  id INT NOT NULL PRIMARY KEY,
  code VARCHAR(20) NOT NULL UNIQUE,
  note VARCHAR(100) DEFAULT 'parent-default' COMMENT 'parent note'
) COMMENT='parent table comment';
INSERT INTO parent VALUES (1, 'p1', 'parent one'), (2, 'p2', DEFAULT), (3, 'p3', NULL);

CREATE TABLE child_restrict (
  id INT NOT NULL PRIMARY KEY,
  parent_id INT NOT NULL,
  payload VARCHAR(100),
  CONSTRAINT fk_child_restrict_parent FOREIGN KEY(parent_id) REFERENCES parent(id) ON DELETE RESTRICT
);
INSERT INTO child_restrict VALUES (1, 1, 'child one'), (2, 2, 'child two');

CREATE TABLE child_cascade (
  id INT NOT NULL PRIMARY KEY,
  parent_id INT NOT NULL,
  payload VARCHAR(100),
  CONSTRAINT fk_child_cascade_parent FOREIGN KEY(parent_id) REFERENCES parent(id) ON DELETE CASCADE
);
INSERT INTO child_cascade VALUES (1, 1, 'cascade child');

CREATE TABLE child_set_null (
  id INT NOT NULL PRIMARY KEY,
  parent_id INT NULL,
  payload VARCHAR(100),
  CONSTRAINT fk_child_set_null_parent FOREIGN KEY(parent_id) REFERENCES parent(id) ON DELETE SET NULL
);
INSERT INTO child_set_null VALUES (1, 1, 'set null child'), (2, NULL, 'orphan allowed');

DROP TABLE IF EXISTS t_auto_inc;
CREATE TABLE t_auto_inc (
  id BIGINT NOT NULL AUTO_INCREMENT PRIMARY KEY,
  k VARCHAR(20) NOT NULL,
  v INT DEFAULT 7,
  UNIQUE KEY uk_k(k)
) AUTO_INCREMENT = 100 COMMENT='auto increment table';
INSERT INTO t_auto_inc(k) VALUES ('a'), ('b');
INSERT INTO t_auto_inc(id, k, v) VALUES (200, 'manual', 9);

DROP TABLE IF EXISTS t_composite_keys;
CREATE TABLE t_composite_keys (
  c1 INT NOT NULL,
  c2 INT NOT NULL,
  c3 VARCHAR(40) NULL,
  c4 VARCHAR(40) NULL,
  PRIMARY KEY(c1, c2),
  UNIQUE KEY uk_c3_c4(c3, c4),
  KEY idx_c2(c2)
);
INSERT INTO t_composite_keys VALUES
  (1, 1, 'a', 'b'),
  (1, 2, 'a', NULL),
  (2, 1, NULL, NULL);

DROP TABLE IF EXISTS t_identifier_comments;
CREATE TABLE t_identifier_comments (
  \`select\` INT NOT NULL,
  \`a-b\` VARCHAR(20) COMMENT 'dash column',
  \`space col\` VARCHAR(20),
  \`unicode_col\` VARCHAR(20),
  PRIMARY KEY(\`select\`)
) COMMENT='identifier and comment coverage';
INSERT INTO t_identifier_comments VALUES
  (1, 'dash', 'space', CONVERT(UNHEX('E4B8ADE69687') USING utf8mb4)),
  (2, 'quote"', 'comma,value', 'plain');

CREATE INDEX idx_parent_note ON parent(note);
CREATE INDEX idx_identifier_ab ON t_identifier_comments(\`a-b\`);

SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema = '$DB_CONS' ORDER BY table_name;
SQL

cat > "$OUT_DIR/21_indexes_optional.sql" <<SQL
USE \`$DB_CONS\`;

DROP TABLE IF EXISTS t_fulltext;
CREATE TABLE t_fulltext (
  id BIGINT NOT NULL PRIMARY KEY,
  doc TEXT,
  FULLTEXT idx_doc(doc)
);
INSERT INTO t_fulltext VALUES (1, 'hello matrixone'), (2, 'checkpoint dump fulltext');

DROP TABLE IF EXISTS t_vector_index;
CREATE TABLE t_vector_index (
  id BIGINT NOT NULL PRIMARY KEY,
  embedding VECF32(3),
  KEY idx_vec_ivf USING ivfflat (embedding) lists = 1 op_type 'vector_l2_ops'
);
INSERT INTO t_vector_index VALUES (1, '[1,0,0]'), (2, '[0,1,0]'), (3, '[0,0,1]');
SQL

cat > "$OUT_DIR/30_tables.sql" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_TABLES\`;
USE \`$DB_TABLES\`;

DROP TABLE IF EXISTS t_normal;
CREATE TABLE t_normal (
  id INT NOT NULL PRIMARY KEY,
  name VARCHAR(50),
  created_at DATETIME DEFAULT CURRENT_TIMESTAMP
);
INSERT INTO t_normal(id, name) VALUES (1, 'normal'), (2, 'comma,value'), (3, 'quote"');

DROP TABLE IF EXISTS t_empty;
CREATE TABLE t_empty (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(20)
);

DROP VIEW IF EXISTS v_normal;
CREATE VIEW v_normal AS SELECT id, name FROM t_normal WHERE id <= 2;

DROP TABLE IF EXISTS t_ctas;
CREATE TABLE t_ctas AS SELECT id, name FROM t_normal;

DROP TABLE IF EXISTS t_like;
CREATE TABLE t_like LIKE t_normal;
INSERT INTO t_like(id, name) VALUES (10, 'like-row');

DROP TABLE IF EXISTS t_hash_partition;
CREATE TABLE t_hash_partition (
  id INT NOT NULL,
  payload VARCHAR(30),
  PRIMARY KEY(id)
) PARTITION BY HASH(id) PARTITIONS 4;
INSERT INTO t_hash_partition
SELECT n, CONCAT('hash-', n) FROM \`$DB_UTIL\`.seq WHERE n < LEAST($SCALE, 1000);

DROP TABLE IF EXISTS t_key_partition;
CREATE TABLE t_key_partition (
  id INT NOT NULL,
  tenant_id INT NOT NULL,
  payload VARCHAR(30),
  PRIMARY KEY(id, tenant_id)
) PARTITION BY KEY(id, tenant_id) PARTITIONS 4;
INSERT INTO t_key_partition
SELECT n, n % 8, CONCAT('key-', n) FROM \`$DB_UTIL\`.seq WHERE n < LEAST($SCALE, 1000);

DROP TABLE IF EXISTS t_cluster_by;
CREATE TABLE t_cluster_by (
  id INT NOT NULL,
  k INT,
  payload VARCHAR(30)
) CLUSTER BY k;
INSERT INTO t_cluster_by
SELECT n, n % 16, CONCAT('cluster-', n) FROM \`$DB_UTIL\`.seq WHERE n < LEAST($SCALE, 1000);

DROP TABLE IF EXISTS \`select\`;
CREATE TABLE \`select\` (
  \`from\` INT NOT NULL PRIMARY KEY,
  \`space col\` VARCHAR(50),
  \`dash-col\` VARCHAR(50)
);
INSERT INTO \`select\` VALUES (1, 'space value', 'dash value');

CREATE TEMPORARY TABLE t_tmp_checkpoint_visibility (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(30)
);
INSERT INTO t_tmp_checkpoint_visibility VALUES (1, 'temporary row');

SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = '$DB_TABLES' ORDER BY table_name;
SQL

cat > "$OUT_DIR/40_mvcc_perf.sql" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_MVCC\`;
USE \`$DB_MVCC\`;

DROP TABLE IF EXISTS t_dml_history;
CREATE TABLE t_dml_history (
  id INT NOT NULL PRIMARY KEY,
  status VARCHAR(20),
  amount DECIMAL(18,2),
  updated_at DATETIME
);
INSERT INTO t_dml_history VALUES
  (1, 'inserted', 10.00, '2024-01-01 00:00:00'),
  (2, 'to-update', 20.00, '2024-01-01 00:00:00'),
  (3, 'to-delete', 30.00, '2024-01-01 00:00:00');
UPDATE t_dml_history SET status='updated', amount=22.22, updated_at='2024-01-02 00:00:00' WHERE id=2;
DELETE FROM t_dml_history WHERE id=3;
INSERT INTO t_dml_history VALUES (4, 'after-delete', 40.00, '2024-01-03 00:00:00');

DROP TABLE IF EXISTS t_truncate_case;
CREATE TABLE t_truncate_case (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(20)
);
INSERT INTO t_truncate_case VALUES (1, 'before'), (2, 'before');
TRUNCATE TABLE t_truncate_case;
INSERT INTO t_truncate_case VALUES (3, 'after');

DROP TABLE IF EXISTS t_alter_case;
CREATE TABLE t_alter_case (
  id INT NOT NULL PRIMARY KEY,
  c1 INT DEFAULT 1
);
INSERT INTO t_alter_case VALUES (1, 1);
ALTER TABLE t_alter_case ADD COLUMN c2 VARCHAR(50) DEFAULT 'added';
INSERT INTO t_alter_case(id, c1) VALUES (2, 2);
UPDATE t_alter_case SET c2='updated-added' WHERE id=1;

DROP TABLE IF EXISTS t_scale_rows;
CREATE TABLE t_scale_rows (
  id INT NOT NULL PRIMARY KEY,
  group_id INT NOT NULL,
  payload VARCHAR(200),
  amount DECIMAL(18,4),
  created_at DATETIME
);
INSERT INTO t_scale_rows
SELECT
  n,
  n % 128,
  CASE
    WHEN n % 10 = 0 THEN CONCAT('csv-special,",comma,', CHAR(10), 'line-', n)
    WHEN n % 10 = 1 THEN CONCAT('single-quote-', '''', '-row-', n)
    ELSE CONCAT('payload-', n)
  END,
  n / 100.0,
  DATE_ADD('2024-01-01 00:00:00', INTERVAL (n % 86400) SECOND)
FROM \`$DB_UTIL\`.seq;

DROP TABLE IF EXISTS t_wide_32_cols;
CREATE TABLE t_wide_32_cols (
  id INT NOT NULL PRIMARY KEY,
  c01 INT, c02 INT, c03 INT, c04 INT, c05 INT, c06 INT, c07 INT, c08 INT,
  c09 VARCHAR(40), c10 VARCHAR(40), c11 VARCHAR(40), c12 VARCHAR(40),
  c13 DECIMAL(18,2), c14 DECIMAL(18,2), c15 DOUBLE, c16 FLOAT,
  c17 DATE, c18 DATETIME, c19 TIME, c20 BOOL,
  c21 TEXT, c22 TEXT, c23 VARCHAR(200), c24 VARCHAR(200),
  c25 BIGINT, c26 BIGINT, c27 SMALLINT, c28 TINYINT,
  c29 JSON, c30 BLOB, c31 CHAR(20), c32 VARBINARY(32)
);
INSERT INTO t_wide_32_cols
SELECT
  n,
  n+1, n+2, n+3, n+4, n+5, n+6, n+7, n+8,
  CONCAT('c09-', n), CONCAT('c10-', n), CONCAT('c11-', n), CONCAT('c12-', n),
  n / 10.0, n / 100.0, n / 3.0, n / 7.0,
  DATE_ADD('2024-01-01', INTERVAL (n % 365) DAY),
  DATE_ADD('2024-01-01 00:00:00', INTERVAL (n % 86400) SECOND),
  '12:34:56',
  n % 2,
  REPEAT('x', 100),
  CONCAT('line1', CHAR(10), 'line2-', n),
  CONCAT('varchar-23-', n),
  CONCAT('varchar-24-', n),
  n * 1000,
  n * 100000,
  n % 32767,
  n % 127,
  CONCAT('{"id":', n, ',"group":', n % 128, '}'),
  UNHEX('ABCD'),
  'char-31',
  UNHEX('00010203')
FROM \`$DB_UTIL\`.seq;

SELECT table_name, table_rows FROM information_schema.tables WHERE table_schema = '$DB_MVCC' ORDER BY table_name;
SELECT 't_scale_rows count' AS item, COUNT(*) AS rows FROM t_scale_rows;
SQL

cat > "$OUT_DIR/90_summary.sql" <<SQL
SELECT 'database' AS kind, '$DB_TYPES' AS name
UNION ALL SELECT 'database', '$DB_CONS'
UNION ALL SELECT 'database', '$DB_TABLES'
UNION ALL SELECT 'database', '$DB_MVCC';

SELECT table_schema, table_name, table_type
FROM information_schema.tables
WHERE table_schema IN ('$DB_TYPES', '$DB_CONS', '$DB_TABLES', '$DB_MVCC')
ORDER BY table_schema, table_name;
SQL

cat > "$OUT_DIR/README.next_steps.txt" <<TXT
Generated SQL files in: $OUT_DIR

Created databases:
  $DB_TYPES
  $DB_CONS
  $DB_TABLES
  $DB_MVCC

Suggested checkpoint-dump test flow on 129:
  1. Run this script and confirm SQL completion.
  2. Stop writes to these databases.
  3. Wait for or trigger a checkpoint according to the MO environment.
  4. Use mo-tool ckp list --type=databases to get database IDs.
  5. Dump each database:
       ./mo-tool ckp dump --database-id=<DB_ID> --output-dir=<OUT>/<DB> --header --load-script --jobs=4 -o <OUT>/<DB> <mo-data/shared>
     Or dump each table:
       ./mo-tool ckp dump --table-id=<TABLE_ID> --header --load-script -o <OUT>/<DB>/<TABLE> <mo-data/shared>
  6. Restore into a clean normal tenant.
  7. Compare:
       - table list
       - row counts
       - SHOW CREATE TABLE
       - sampled checksums for scale tables

Scale rows requested: $SCALE
TXT

echo "Generated SQL files under $OUT_DIR"

if [[ "$GENERATE_ONLY" == "1" ]]; then
  echo "Generate-only mode. Nothing executed."
  exit 0
fi

run_sql "00_create_util" "$OUT_DIR/00_create_util.sql" 0
run_sql "10_types_core" "$OUT_DIR/10_types_core.sql" 0
run_sql "11_types_optional" "$OUT_DIR/11_types_optional.sql" 1
run_sql "20_constraints" "$OUT_DIR/20_constraints.sql" 0
run_sql "21_indexes_optional" "$OUT_DIR/21_indexes_optional.sql" 1
run_sql "30_tables" "$OUT_DIR/30_tables.sql" 1
run_sql "40_mvcc_perf" "$OUT_DIR/40_mvcc_perf.sql" 0
run_sql "90_summary" "$OUT_DIR/90_summary.sql" 0

cat "$OUT_DIR/README.next_steps.txt"
