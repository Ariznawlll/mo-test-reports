#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify checkpoint dump/restore for missing partition and table-option coverage.

Coverage:
  - RANGE partition
  - RANGE COLUMNS partition
  - LIST partition
  - LIST COLUMNS partition
  - LINEAR HASH partition
  - table/column COMMENT and AUTO_INCREMENT table option

Flow:
  1. Create source database/tables.
  2. Trigger checkpoint.
  3. Locate database/table IDs from checkpoint metadata.
  4. Dump each table with --load-script.
  5. Restore into target tenant.
  6. Compare SHOW CREATE TABLE, row counts, and full sorted data.

Usage:
  ./verify_partition_options_dump_restore.sh [options]

Options:
  --host HOST                 MatrixOne MySQL host, default: 127.0.0.1
  --port PORT                 MatrixOne MySQL port, default: 6001
  --source-user USER          Source tenant user, default: dump
  --source-password PASS      Source tenant password, default: 111
  --target-user USER          Target tenant user, default: acc01:test_account
  --target-password PASS      Target tenant password, default: 111
  --db DB                     Test database name, default: ckp_partition_options
  --mo-tool PATH              mo-tool path, default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH             Checkpoint data path
  --out DIR                   Output dir, default: /data4/weilu/verify_partition_options_<timestamp>
  --mysql-bin PATH            mysql client path, default: mysql
  --wait-seconds N            Max wait for checkpoint metadata, default: 300
  --poll-seconds N            Poll interval, default: 5
  --drop-existing             Drop source/target test database first
  --help                      Show this help
USAGE
}

TS="$(date +%Y%m%d_%H%M%S)"

HOST="127.0.0.1"
PORT="6001"
SOURCE_USER="dump"
SOURCE_PASSWORD="111"
TARGET_USER="acc01:test_account"
TARGET_PASSWORD="111"
DB="ckp_partition_options"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_partition_options_${TS}"
MYSQL_BIN="mysql"
WAIT_SECONDS="300"
POLL_SECONDS="5"
DROP_EXISTING="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --source-user) SOURCE_USER="$2"; shift 2 ;;
    --source-password) SOURCE_PASSWORD="$2"; shift 2 ;;
    --target-user) TARGET_USER="$2"; shift 2 ;;
    --target-password) TARGET_PASSWORD="$2"; shift 2 ;;
    --db) DB="$2"; shift 2 ;;
    --mo-tool) MO_TOOL="$2"; shift 2 ;;
    --ckp-data) CKP_DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --drop-existing) DROP_EXISTING="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for n in "$PORT" "$WAIT_SECONDS" "$POLL_SECONDS"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "Numeric option expected, got: $n" >&2
    exit 2
  fi
done

case "$OUT" in
  /data4/*) ;;
  *)
    echo "--out must be under /data4: $OUT" >&2
    exit 2
    ;;
esac

if [[ ! -x "$MO_TOOL" ]]; then
  echo "mo-tool not found or not executable: $MO_TOOL" >&2
  exit 2
fi
if [[ ! -d "$CKP_DATA" ]]; then
  echo "checkpoint data path not found: $CKP_DATA" >&2
  exit 2
fi

LOG_DIR="$OUT/logs"
DUMP_DIR="$OUT/dumps"
COMPARE_DIR="$OUT/compare"
mkdir -p "$LOG_DIR" "$DUMP_DIR" "$COMPARE_DIR"

TABLES=(
  t_range_partition
  t_range_columns_partition
  t_list_partition
  t_list_columns_partition
  t_linear_hash_partition
  t_table_options
)

log() {
  printf '%s\n' "$*"
}

quote_sql_string() {
  printf "%s" "$1" | sed "s/'/''/g"
}

safe_name() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

mysql_exec() {
  local user="$1"
  local password="$2"
  MYSQL_PWD="$password" "$MYSQL_BIN" \
    -h"$HOST" \
    -P"$PORT" \
    -u"$user" \
    --default-character-set=utf8mb4 \
    --show-warnings
}

mysql_query() {
  local user="$1"
  local password="$2"
  local sql="$3"
  MYSQL_PWD="$password" "$MYSQL_BIN" \
    -h"$HOST" \
    -P"$PORT" \
    -u"$user" \
    --default-character-set=utf8mb4 \
    --batch \
    --raw \
    --skip-column-names \
    -e "$sql"
}

ensure_target_account() {
  if [[ "$TARGET_USER" != *:* ]]; then
    return 0
  fi

  local account="${TARGET_USER%%:*}"
  local admin="${TARGET_USER#*:}"
  local admin_sql
  local pass_sql
  admin_sql="$(quote_sql_string "$admin")"
  pass_sql="$(quote_sql_string "$TARGET_PASSWORD")"

  mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" \
    "CREATE ACCOUNT \`$account\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_target_account.log" 2>&1 || true
}

prepare_source() {
  local sql_file="$OUT/create_source.sql"

  cat > "$sql_file" <<SQL
DROP DATABASE IF EXISTS \`$DB\`;
CREATE DATABASE \`$DB\`;
USE \`$DB\`;

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

CREATE TABLE t_linear_hash_partition (
  id INT NOT NULL,
  created_at DATE NOT NULL,
  payload VARCHAR(40)
)
PARTITION BY LINEAR HASH(YEAR(created_at)) PARTITIONS 4
;
INSERT INTO t_linear_hash_partition VALUES
  (1, '2021-01-01', 'linear-2021'),
  (2, '2022-01-01', 'linear-2022'),
  (3, '2023-01-01', 'linear-2023'),
  (4, '2024-01-01', 'linear-2024'),
  (5, '2025-01-01', 'linear-2025');

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

SELECT table_name, table_rows
FROM information_schema.tables
WHERE table_schema = '$DB'
ORDER BY table_name;
SQL

  log "==> Create source partition/table-option fixtures"
  mysql_exec "$SOURCE_USER" "$SOURCE_PASSWORD" < "$sql_file" > "$LOG_DIR/create_source.log" 2>&1
}

trigger_checkpoint() {
  log "==> Trigger checkpoint"
  mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT mo_ctl('dn', 'checkpoint', '');" \
    > "$LOG_DIR/trigger_checkpoint.log" 2>&1
}

wait_db() {
  local deadline=$(( $(date +%s) + WAIT_SECONDS ))
  local db_id=""

  log "==> Wait for $DB in checkpoint metadata"
  while (( $(date +%s) <= deadline )); do
    "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$OUT/databases.txt" 2> "$LOG_DIR/ckp_list_databases.err" || true
    db_id="$(awk -v db="$DB" '$2 == db {print $3; exit}' "$OUT/databases.txt")"
    if [[ -n "$db_id" ]]; then
      echo "$db_id" > "$OUT/db_id.txt"
      awk -v db="$DB" '$2 == db {print $1; exit}' "$OUT/databases.txt" > "$OUT/account_id.txt"
      return 0
    fi
    log "    $DB not found yet; retry after ${POLL_SECONDS}s"
    sleep "$POLL_SECONDS"
  done

  echo "$DB not found in checkpoint within ${WAIT_SECONDS}s" >&2
  return 1
}

dump_tables() {
  local db_id
  local tbl
  local table_id
  local rel_kind
  local dir
  local log_file
  local restore
  local rc

  db_id="$(cat "$OUT/db_id.txt")"
  "$MO_TOOL" ckp list --type=tables --database-id="$db_id" "$CKP_DATA" \
    > "$OUT/tables.txt" 2> "$LOG_DIR/ckp_list_tables.err"

  printf 'table\ttable_id\trel_kind\tdump_status\trestore_sql\n' > "$OUT/dump_summary.tsv"

  for tbl in "${TABLES[@]}"; do
    table_id="$(awk -v t="$tbl" '$3 == t {print $4; exit}' "$OUT/tables.txt")"
    rel_kind="$(awk -v t="$tbl" '$3 == t {print $5; exit}' "$OUT/tables.txt")"
    if [[ -z "$table_id" ]]; then
      printf '%s\tNOT_FOUND\t%s\tSKIP\t-\n' "$tbl" "$rel_kind" >> "$OUT/dump_summary.tsv"
      continue
    fi

    dir="$DUMP_DIR/$(safe_name "${table_id}_${tbl}")"
    log_file="$LOG_DIR/${tbl}.dump.log"
    restore="$dir/restore.sql"
    mkdir -p "$dir"

    log "==> Dump $DB.$tbl table_id=$table_id rel_kind=$rel_kind"
    set +e
    "$MO_TOOL" ckp dump \
      --table-id="$table_id" \
      --header \
      --load-script \
      -o "$dir" \
      "$CKP_DATA" > "$log_file" 2>&1
    rc=$?
    set -e

    printf '%s\t%s\t%s\t%s\t%s\n' "$tbl" "$table_id" "$rel_kind" "$rc" "$restore" >> "$OUT/dump_summary.tsv"
  done
}

restore_target() {
  local tbl
  local table_id
  local rel_kind
  local dump_status
  local restore
  local log_file
  local rc
  local status

  if [[ "$DROP_EXISTING" == "1" ]]; then
    log "==> Drop target database $DB"
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "DROP DATABASE IF EXISTS \`$DB\`;" \
      > "$LOG_DIR/drop_target_db.log" 2>&1 || true
  fi

  printf 'table\tload_status\tlog\n' > "$OUT/load_summary.tsv"
  tail -n +2 "$OUT/dump_summary.tsv" | while IFS=$'\t' read -r tbl table_id rel_kind dump_status restore; do
    log_file="$LOG_DIR/${tbl}.restore.log"
    if [[ "$dump_status" != "0" || ! -f "$restore" ]]; then
      status="SKIP"
    else
      log "==> Load $DB.$tbl into target tenant"
      set +e
      MYSQL_PWD="$TARGET_PASSWORD" "$MYSQL_BIN" \
        -h"$HOST" \
        -P"$PORT" \
        -u"$TARGET_USER" \
        --default-character-set=utf8mb4 \
        < "$restore" > "$log_file" 2>&1
      rc=$?
      set -e
      if [[ "$rc" -eq 0 ]]; then
        status="OK"
      else
        status="FAIL"
      fi
    fi
    printf '%s\t%s\t%s\n' "$tbl" "$status" "$log_file" >> "$OUT/load_summary.tsv"
  done
}

dump_table_data() {
  local user="$1"
  local password="$2"
  local table="$3"
  local out_file="$4"

  MYSQL_PWD="$password" "$MYSQL_BIN" \
    -h"$HOST" \
    -P"$PORT" \
    -u"$user" \
    --default-character-set=utf8mb4 \
    --batch \
    --raw \
    --skip-column-names \
    -e "SELECT * FROM \`$DB\`.\`$table\`;" \
    | LC_ALL=C sort > "$out_file"
}

normalize_schema() {
  sed -E \
    -e "s/AUTO_INCREMENT=[0-9]+//g" \
    -e "s/CREATE TABLE \`$DB\`\.\`/CREATE TABLE \`/Ig" \
    -e 's/[[:space:]]+$//'
}

compare_tables() {
  local tbl
  local load_status
  local source_count
  local target_count
  local count_status
  local schema_status
  local data_status
  local source_schema
  local target_schema
  local schema_diff
  local source_data
  local target_data
  local data_diff

  printf 'table\tload_status\tsource_count\ttarget_count\tcount_status\tschema_status\tdata_status\n' > "$OUT/summary.tsv"

  for tbl in "${TABLES[@]}"; do
    load_status="$(awk -F'\t' -v t="$tbl" '$1 == t {print $2; exit}' "$OUT/load_summary.tsv")"
    [[ -z "$load_status" ]] && load_status="MISSING"

    source_count="$(mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT COUNT(*) FROM \`$DB\`.\`$tbl\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    target_count="$(mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SELECT COUNT(*) FROM \`$DB\`.\`$tbl\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    if [[ "$source_count" == "$target_count" ]]; then
      count_status="OK"
    else
      count_status="DIFF"
    fi

    source_schema="$COMPARE_DIR/${tbl}.source.schema.sql"
    target_schema="$COMPARE_DIR/${tbl}.target.schema.sql"
    schema_diff="$COMPARE_DIR/${tbl}.schema.diff"
    source_data="$COMPARE_DIR/${tbl}.source.data.tsv"
    target_data="$COMPARE_DIR/${tbl}.target.data.tsv"
    data_diff="$COMPARE_DIR/${tbl}.data.diff"

    mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SHOW CREATE TABLE \`$DB\`.\`$tbl\`;" \
      | cut -f2- | normalize_schema > "$source_schema" || true
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SHOW CREATE TABLE \`$DB\`.\`$tbl\`;" \
      | cut -f2- | normalize_schema > "$target_schema" || true
    if diff -u "$source_schema" "$target_schema" > "$schema_diff"; then
      schema_status="OK"
    else
      schema_status="DIFF"
    fi

    if dump_table_data "$SOURCE_USER" "$SOURCE_PASSWORD" "$tbl" "$source_data" \
        && dump_table_data "$TARGET_USER" "$TARGET_PASSWORD" "$tbl" "$target_data" \
        && diff -u "$source_data" "$target_data" > "$data_diff"; then
      data_status="OK"
    else
      data_status="DIFF"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$tbl" "$load_status" "$source_count" "$target_count" "$count_status" "$schema_status" "$data_status" \
      >> "$OUT/summary.tsv"
  done
}

final_check() {
  local failed=0

  log "==> Summary"
  column -t -s $'\t' "$OUT/summary.tsv" || cat "$OUT/summary.tsv"
  log "Artifacts: $OUT"

  if awk -F'\t' 'NR > 1 && ($2 != "OK" || $5 != "OK" || $6 != "OK" || $7 != "OK") {bad=1} END {exit bad ? 0 : 1}' "$OUT/summary.tsv"; then
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "PARTITION_OPTIONS_DUMP_RESTORE_FAIL"
    return 1
  fi

  echo "PARTITION_OPTIONS_DUMP_RESTORE_OK"
}

log "OUT=$OUT"
log "DB=$DB"
log "MO_TOOL=$MO_TOOL"
log "CKP_DATA=$CKP_DATA"

ensure_target_account
prepare_source
trigger_checkpoint
wait_db
dump_tables
restore_target
compare_tables
final_check
