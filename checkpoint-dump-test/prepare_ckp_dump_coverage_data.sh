#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Prepare MatrixOne checkpoint-dump coverage data.

This script creates four focused databases by default:
  <prefix>_types        data types and boundary values
  <prefix>_constraints  defaults, PK/UK/FK, comments, indexes
  <prefix>_tables       table shapes: empty, view, CTAS, LIKE, partition, special names
  <prefix>_mvcc_perf    DML history, alter/truncate, scale rows, wide table

Temporary-table and external-table cases are currently behind
--include-temp-external because they have known bugs under checkpoint dump.

Usage:
  ./prepare_ckp_dump_coverage_data.sh [options]

Options:
  --host HOST             MySQL host, default: 127.0.0.1
  --port PORT             MySQL port, default: 6001
  --user USER             MySQL user, default: dump
  --password PASSWORD     MySQL password, default: 111
  --db-prefix PREFIX      Database prefix. Default: ckp_cov_<timestamp>
  --scale N               Rows for scale tables. Default: 10000, max generated: 1000000
  --temp-hold-seconds N   Keep the temporary-table session open for N seconds. Default: 0; only with --include-temp-external
  --include-temp-external Include temporary-table and external-table cases
  --drop-existing         Drop target databases before creating them
  --mysql-bin PATH        mysql client path, default: mysql
  --out-dir DIR           SQL/log output directory, default: /data4/ckp_dump_coverage_<timestamp>
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
TEMP_HOLD_SECONDS="0"
INCLUDE_TEMP_EXTERNAL="0"
DROP_EXISTING="0"
GENERATE_ONLY="0"
OUT_DIR="/data4/ckp_dump_coverage_${TS}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --db-prefix) DB_PREFIX="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --temp-hold-seconds) TEMP_HOLD_SECONDS="$2"; shift 2 ;;
    --include-temp-external) INCLUDE_TEMP_EXTERNAL="1"; shift ;;
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
if ! [[ "$TEMP_HOLD_SECONDS" =~ ^[0-9]+$ ]]; then
  echo "--temp-hold-seconds must be a non-negative integer" >&2
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

case "$OUT_DIR" in
  /data4/*) ;;
  *)
    echo "--out-dir must be under /data4 so generated SQL/log files stay on the data disk: $OUT_DIR" >&2
    exit 2
    ;;
esac

DB_TYPES="${DB_PREFIX}_types"
DB_CONS="${DB_PREFIX}_constraints"
DB_TABLES="${DB_PREFIX}_tables"
DB_TEMP="${DB_PREFIX}_temp"
DB_EXT="${DB_PREFIX}_external"
DB_MVCC="${DB_PREFIX}_mvcc_perf"
DB_UTIL="${DB_PREFIX}_util"
EXT_FIXTURE_DIR="$OUT_DIR/external_fixtures"
EXT_CSV_FILE="$EXT_FIXTURE_DIR/local_ext_people.csv"

mkdir -p "$OUT_DIR"
if [[ "$INCLUDE_TEMP_EXTERNAL" == "1" ]]; then
  mkdir -p "$EXT_FIXTURE_DIR"

  printf '%s\n' \
    '1,alice,10.50,plain' \
    '2,bob,20.00,"comma,value"' \
    '3,charlie,0.00,"quote ""inside"""' \
    > "$EXT_CSV_FILE"

  EXT_CSV_FILE_SQL="$(printf "%s" "$EXT_CSV_FILE" | sed "s/'/''/g")"
fi

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

run_probe_sql() {
  local sql="$1"
  MYSQL_PWD="$PASSWORD" "$MYSQL_BIN" "${mysql_base_args[@]}" -e "$sql" >/dev/null 2>&1
}

detect_array_column_type() {
  local probe_db="${DB_PREFIX}_array_probe_$$"
  local candidate
  local candidates=(
    "ARRAY(VARCHAR(20))"
    "ARRAY<varchar(20)>"
    "VARCHAR(20) ARRAY"
    "TEXT ARRAY"
    "ARRAY"
  )

  run_probe_sql "DROP DATABASE IF EXISTS \`$probe_db\`; CREATE DATABASE \`$probe_db\`;" || return 1
  for candidate in "${candidates[@]}"; do
    if run_probe_sql "USE \`$probe_db\`; DROP TABLE IF EXISTS t; CREATE TABLE t (id INT NOT NULL PRIMARY KEY, tags $candidate NULL); INSERT INTO t VALUES (1, '[\"a\",\"b\"]'), (2, '[]'), (3, NULL); DROP TABLE t;"; then
      run_probe_sql "DROP DATABASE IF EXISTS \`$probe_db\`;" || true
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  run_probe_sql "DROP DATABASE IF EXISTS \`$probe_db\`;" || true
  return 1
}

ARRAY_COLUMN_TYPE="ARRAY(VARCHAR(20))"
ARRAY_SETUP_NOTE="native ARRAY syntax selected by default"
if [[ "$GENERATE_ONLY" != "1" ]]; then
  if detected_array_type="$(detect_array_column_type)"; then
    ARRAY_COLUMN_TYPE="$detected_array_type"
    ARRAY_SETUP_NOTE="native ARRAY syntax accepted by current MatrixOne server"
  else
    ARRAY_COLUMN_TYPE="JSON"
    ARRAY_SETUP_NOTE="fallback to JSON because current MatrixOne server rejected ARRAY column syntax candidates"
  fi
fi
echo "t_array column type: $ARRAY_COLUMN_TYPE ($ARRAY_SETUP_NOTE)"

drop_stmt() {
  if [[ "$DROP_EXISTING" == "1" ]]; then
    cat <<SQL
DROP DATABASE IF EXISTS \`$DB_TYPES\`;
DROP DATABASE IF EXISTS \`$DB_CONS\`;
DROP DATABASE IF EXISTS \`$DB_TABLES\`;
DROP DATABASE IF EXISTS \`$DB_TEMP\`;
DROP DATABASE IF EXISTS \`$DB_EXT\`;
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

SELECT 'util.seq rows' AS item, COUNT(*) AS \`rows\` FROM seq;
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
-- YEAR coverage is temporarily disabled due to #25066:
-- LOAD DATA fails with "the value type 22 is not support now".
CREATE TABLE t_temporal (
  id INT NOT NULL PRIMARY KEY,
  c_date DATE NULL,
  c_time TIME NULL,
  c_time6 TIME(6) NULL,
  c_datetime DATETIME NULL,
  c_datetime3 DATETIME(3) NULL,
  c_datetime6 DATETIME(6) NULL,
  c_timestamp TIMESTAMP NULL,
  c_timestamp6 TIMESTAMP(6) NULL
);
INSERT INTO t_temporal VALUES
  (1, '1970-01-01', '00:00:00', '00:00:00.000001', '1970-01-01 00:00:00', '2024-02-29 12:34:56.789', '2024-02-29 12:34:56.789123', '2024-02-29 12:34:56', '2024-02-29 12:34:56.789123'),
  (2, '2024-02-29', '23:59:59', '23:59:59.999999', '2038-01-19 03:14:07', '2000-01-01 00:00:00.123', '2000-01-01 00:00:00.123456', '2038-01-19 03:14:07', '2000-01-01 00:00:00.123456'),
  (3, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

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
-- YEAR coverage is temporarily disabled due to #25066:
-- LOAD DATA fails with "the value type 22 is not support now".
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
  c_json JSON
);
INSERT INTO t_all_wide VALUES
  (1, -1, -2, -3, -4, 4, 1.25, 2.5, 12345.678901, true, 'char', 'varchar,quote"', 'text\nline', UNHEX('00FF'), '2024-02-29', '12:34:56.123456', '2024-02-29 12:34:56.123456', '2024-02-29 12:34:56.123456', '{"wide":true}'),
  (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL);

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
-- t_array column type selected by prepare script: $ARRAY_COLUMN_TYPE
-- $ARRAY_SETUP_NOTE
CREATE TABLE t_array (
  id INT NOT NULL PRIMARY KEY,
  tags $ARRAY_COLUMN_TYPE NULL
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

cat > "$OUT_DIR/22_dependencies_optional.sql" <<SQL
USE \`$DB_CONS\`;

DROP TABLE IF EXISTS t_sequence_default;
DROP TABLE IF EXISTS t_sequence_nextval;
DROP SEQUENCE IF EXISTS seq_default_id;

CREATE SEQUENCE seq_default_id INCREMENT BY 1 START WITH 100 NO CYCLE;

DROP TABLE IF EXISTS t_sequence_nextval;
CREATE TABLE t_sequence_nextval (
  id BIGINT NOT NULL PRIMARY KEY,
  note VARCHAR(50)
);
INSERT INTO t_sequence_nextval VALUES
  (nextval('seq_default_id'), 'nextval-row-1'),
  (nextval('seq_default_id'), 'nextval-row-2');

DROP TABLE IF EXISTS t_sequence_default;
CREATE TABLE t_sequence_default (
  id BIGINT NOT NULL DEFAULT nextval('seq_default_id') PRIMARY KEY,
  note VARCHAR(50)
);
INSERT INTO t_sequence_default(note) VALUES
  ('default-nextval-row-1'),
  ('default-nextval-row-2');
INSERT INTO t_sequence_default(id, note) VALUES
  (999, 'manual-row');

SELECT 't_sequence_nextval' AS table_name, COUNT(*) AS table_rows FROM t_sequence_nextval
UNION ALL
SELECT 't_sequence_default', COUNT(*) FROM t_sequence_default;
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

DROP TABLE IF EXISTS t_range_partition;
CREATE TABLE t_range_partition (
  id INT NOT NULL,
  name VARCHAR(30),
  created_at DATE NOT NULL
)
PARTITION BY RANGE (id) (
  PARTITION p_lt_10 VALUES LESS THAN (10),
  PARTITION p_lt_20 VALUES LESS THAN (20),
  PARTITION p_max VALUES LESS THAN MAXVALUE
);
INSERT INTO t_range_partition VALUES
  (1, 'range-a', '2024-01-01'),
  (9, 'range-b', '2024-01-02'),
  (10, 'range-c', '2024-01-03'),
  (19, 'range-d', '2024-01-04'),
  (20, 'range-e', '2024-01-05');

DROP TABLE IF EXISTS t_range_columns_partition;
CREATE TABLE t_range_columns_partition (
  emp_no INT NOT NULL,
  joined DATE NOT NULL,
  note VARCHAR(40)
)
PARTITION BY RANGE COLUMNS(joined) (
  PARTITION p_2023 VALUES LESS THAN ('2024-01-01'),
  PARTITION p_2024 VALUES LESS THAN ('2025-01-01'),
  PARTITION p_future VALUES LESS THAN MAXVALUE
);
INSERT INTO t_range_columns_partition VALUES
  (1, '2023-12-31', 'before-2024'),
  (2, '2024-01-01', 'start-2024'),
  (3, '2024-12-31', 'end-2024'),
  (4, '2025-01-01', 'future');

DROP TABLE IF EXISTS t_list_partition;
CREATE TABLE t_list_partition (
  id INT NOT NULL,
  region_id INT NOT NULL,
  name VARCHAR(30)
)
PARTITION BY LIST (region_id) (
  PARTITION p_north VALUES IN (1, 2),
  PARTITION p_south VALUES IN (3, 4),
  PARTITION p_other VALUES IN (5, 6)
);
INSERT INTO t_list_partition VALUES
  (1, 1, 'north-a'),
  (2, 2, 'north-b'),
  (3, 3, 'south-a'),
  (4, 4, 'south-b'),
  (5, 5, 'other-a');

DROP TABLE IF EXISTS t_list_columns_partition;
CREATE TABLE t_list_columns_partition (
  id INT NOT NULL,
  category VARCHAR(20) NOT NULL,
  payload VARCHAR(40)
)
PARTITION BY LIST COLUMNS(category) (
  PARTITION p_ab VALUES IN ('a', 'b'),
  PARTITION p_cd VALUES IN ('c', 'd'),
  PARTITION p_ef VALUES IN ('e', 'f')
);
INSERT INTO t_list_columns_partition VALUES
  (1, 'a', 'category-a'),
  (2, 'b', 'category-b'),
  (3, 'c', 'category-c'),
  (4, 'd', 'category-d'),
  (5, 'e', 'category-e');

DROP TABLE IF EXISTS t_linear_hash_partition;
CREATE TABLE t_linear_hash_partition (
  id INT NOT NULL,
  created_at DATE NOT NULL,
  payload VARCHAR(40)
)
PARTITION BY LINEAR HASH(YEAR(created_at)) PARTITIONS 4;
INSERT INTO t_linear_hash_partition VALUES
  (1, '2021-01-01', 'linear-2021'),
  (2, '2022-01-01', 'linear-2022'),
  (3, '2023-01-01', 'linear-2023'),
  (4, '2024-01-01', 'linear-2024'),
  (5, '2025-01-01', 'linear-2025');

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

DROP TABLE IF EXISTS t_table_options;
CREATE TABLE t_table_options (
  id BIGINT NOT NULL AUTO_INCREMENT COMMENT 'auto increment id',
  code VARCHAR(30) NOT NULL COMMENT 'business code',
  note VARCHAR(80) DEFAULT 'default-note' COMMENT 'column default and comment',
  PRIMARY KEY(id),
  UNIQUE KEY uk_code(code)
) AUTO_INCREMENT = 100 COMMENT='table options: comment and auto_increment';
INSERT INTO t_table_options(code, note) VALUES
  ('auto-a', 'first auto row'),
  ('auto-b', 'second auto row');
INSERT INTO t_table_options(id, code, note) VALUES
  (200, 'manual-id', 'manual id row');

SELECT table_name, table_type FROM information_schema.tables WHERE table_schema = '$DB_TABLES' ORDER BY table_name;
SQL

if [[ "$INCLUDE_TEMP_EXTERNAL" == "1" ]]; then
cat > "$OUT_DIR/31_temp_tables.sql" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_TEMP\`;
USE \`$DB_TEMP\`;

DROP TABLE IF EXISTS temp_case_marker;
CREATE TABLE temp_case_marker (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(100)
);
REPLACE INTO temp_case_marker VALUES
  (1, 'rerun with --temp-hold-seconds > 0 and trigger checkpoint during the hold window');

CREATE TEMPORARY TABLE t_session_only (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(30)
);
INSERT INTO t_session_only VALUES (1, 'temporary row');

SELECT 'temp table session rows' AS item, COUNT(*) AS \`rows\` FROM t_session_only;
SELECT 'temp hold seconds' AS item, $TEMP_HOLD_SECONDS AS \`rows\`;
SELECT SLEEP($TEMP_HOLD_SECONDS) AS temp_hold_completed;
SQL

cat > "$OUT_DIR/32_external_tables.sql" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_EXT\`;
USE \`$DB_EXT\`;

DROP TABLE IF EXISTS ext_csv_local;
CREATE EXTERNAL TABLE ext_csv_local (
  id INT,
  name VARCHAR(50),
  score DECIMAL(10,2),
  note VARCHAR(100)
) INFILE {
  'filepath'='$EXT_CSV_FILE_SQL',
  'format'='csv'
};

SELECT 'ext_csv_local rows' AS item, COUNT(*) AS \`rows\` FROM ext_csv_local;
SQL
fi

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
SELECT 't_scale_rows count' AS item, COUNT(*) AS \`rows\` FROM t_scale_rows;
SQL

if [[ "$INCLUDE_TEMP_EXTERNAL" == "1" ]]; then
cat > "$OUT_DIR/90_summary.sql" <<SQL
SELECT 'database' AS kind, '$DB_TYPES' AS name
UNION ALL SELECT 'database', '$DB_CONS'
UNION ALL SELECT 'database', '$DB_TABLES'
UNION ALL SELECT 'database', '$DB_TEMP'
UNION ALL SELECT 'database', '$DB_EXT'
UNION ALL SELECT 'database', '$DB_MVCC';

SELECT table_schema, table_name, table_type
FROM information_schema.tables
WHERE table_schema IN ('$DB_TYPES', '$DB_CONS', '$DB_TABLES', '$DB_TEMP', '$DB_EXT', '$DB_MVCC')
ORDER BY table_schema, table_name;
SQL
else
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
fi

if [[ "$INCLUDE_TEMP_EXTERNAL" == "1" ]]; then
cat > "$OUT_DIR/README.next_steps.txt" <<TXT
Generated SQL files in: $OUT_DIR

Created databases:
  $DB_TYPES
  $DB_CONS
  $DB_TABLES
  $DB_TEMP
  $DB_EXT
  $DB_MVCC

Special fixtures:
  local external CSV: $EXT_CSV_FILE
  temporary-table SQL: $OUT_DIR/31_temp_tables.sql

Suggested checkpoint-dump test flow on 129:
  1. Run this script and confirm SQL completion.
  2. For temporary-table coverage, rerun with --temp-hold-seconds 180 and trigger checkpoint while 31_temp_tables.sql is sleeping.
  3. Stop writes to these databases.
  4. Wait for or trigger a checkpoint according to the MO environment.
  5. Use mo-tool ckp list --type=databases to get database IDs.
  6. Dump each database:
       ./mo-tool ckp dump --database-id=<DB_ID> --output-dir=<OUT>/<DB> --header --load-script --jobs=4 -o <OUT>/<DB> <mo-data/shared>
     Or dump each table:
       ./mo-tool ckp dump --table-id=<TABLE_ID> --header --load-script -o <OUT>/<DB>/<TABLE> <mo-data/shared>
  7. Restore into a clean normal tenant.
  8. Compare:
       - table list
       - row counts
       - SHOW CREATE TABLE
       - sampled checksums for scale tables
       - temp/external behavior against expectation:
         * temporary table: should only be visible if checkpoint was taken during the hold window
         * external table: verify whether ckp list/dump skips it, exports only metadata, or produces a clear error
       - cross-object dependencies:
         * FK child tables restore after parent tables
         * fulltext/vector index metadata is preserved
         * sequence/default dependencies are restorable

Scale rows requested: $SCALE
TXT
else
cat > "$OUT_DIR/README.next_steps.txt" <<TXT
Generated SQL files in: $OUT_DIR

Created databases:
  $DB_TYPES
  $DB_CONS
  $DB_TABLES
  $DB_MVCC

Temporary-table and external-table cases are skipped by default because they
currently have known checkpoint dump bugs. Rerun with --include-temp-external
only when validating those known issues.

Suggested checkpoint-dump test flow on 129:
  1. Run this script and confirm SQL completion.
  2. Stop writes to these databases.
  3. Trigger a checkpoint:
       SELECT mo_ctl('dn', 'checkpoint', '');
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
       - cross-object dependencies:
         * FK child tables restore after parent tables
         * fulltext/vector index metadata is preserved
         * sequence/default dependencies are restorable

Scale rows requested: $SCALE
TXT
fi

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
run_sql "22_dependencies_optional" "$OUT_DIR/22_dependencies_optional.sql" 1
run_sql "30_tables" "$OUT_DIR/30_tables.sql" 1
if [[ "$INCLUDE_TEMP_EXTERNAL" == "1" ]]; then
  run_sql "31_temp_tables" "$OUT_DIR/31_temp_tables.sql" 0
  run_sql "32_external_tables" "$OUT_DIR/32_external_tables.sql" 1
fi
run_sql "40_mvcc_perf" "$OUT_DIR/40_mvcc_perf.sql" 0
run_sql "90_summary" "$OUT_DIR/90_summary.sql" 0

cat "$OUT_DIR/README.next_steps.txt"
