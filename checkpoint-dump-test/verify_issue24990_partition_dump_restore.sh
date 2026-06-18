#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
One-click verification for issue #24990:
partition tables should dump data correctly and preserve restore DDL.

What this script does:
  1. Optionally prepare ckp_* coverage data if ckp_tables is missing
  2. Query source row counts from the dump tenant
  3. Wait until ckp_tables appears in checkpoint metadata
  4. Dump t_empty / t_hash_partition / t_key_partition with --load-script
  5. Check CSV row counts and restore.sql DDL
  6. Load restore.sql into a normal tenant
  7. Compare source vs target schema, row count, and full table data

Usage:
  ./verify_issue24990_partition_dump_restore.sh [options]

Options:
  --host HOST                 MatrixOne MySQL host, default: 127.0.0.1
  --port PORT                 MatrixOne MySQL port, default: 6001
  --source-user USER          Source tenant user, default: dump
  --source-password PASS      Source tenant password, default: 111
  --target-user USER          Target tenant user, default: acc01:test_account
  --target-password PASS      Target tenant password, default: 111
  --db-name NAME              Source/target database name, default: ckp_tables
  --mo-tool PATH              mo-tool path, default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH             Checkpoint data path
  --out DIR                   Output dir, default: /data4/weilu/verify_24990_<timestamp>
  --mysql-bin PATH            mysql client path, default: mysql
  --prepare-if-missing        Run prepare_ckp_dump_coverage_data.sh if ckp_tables is missing
  --prepare-script PATH       prepare script path, default: same dir as this script
  --prepare-scale N           Scale passed to prepare script, default: 10000
  --wait-seconds N            Max wait for ckp_tables to appear in checkpoint, default: 600
  --poll-seconds N            Poll interval while waiting, default: 10
  --keep-target-db            Do not drop target DB before restore
  --help                      Show this help

Example:
  ./verify_issue24990_partition_dump_restore.sh \
    --host 127.0.0.1 \
    --port 6001 \
    --source-user dump \
    --source-password 111 \
    --target-user 'acc01:test_account' \
    --target-password 111
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TS="$(date +%Y%m%d_%H%M%S)"

HOST="127.0.0.1"
PORT="6001"
SOURCE_USER="dump"
SOURCE_PASSWORD="111"
TARGET_USER="acc01:test_account"
TARGET_PASSWORD="111"
DB_NAME="ckp_tables"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_24990_${TS}"
MYSQL_BIN="mysql"
PREPARE_IF_MISSING="0"
PREPARE_SCRIPT="$SCRIPT_DIR/prepare_ckp_dump_coverage_data.sh"
PREPARE_SCALE="10000"
WAIT_SECONDS="600"
POLL_SECONDS="10"
KEEP_TARGET_DB="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --source-user) SOURCE_USER="$2"; shift 2 ;;
    --source-password) SOURCE_PASSWORD="$2"; shift 2 ;;
    --target-user) TARGET_USER="$2"; shift 2 ;;
    --target-password) TARGET_PASSWORD="$2"; shift 2 ;;
    --db-name) DB_NAME="$2"; shift 2 ;;
    --mo-tool) MO_TOOL="$2"; shift 2 ;;
    --ckp-data) CKP_DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --prepare-if-missing) PREPARE_IF_MISSING="1"; shift ;;
    --prepare-script) PREPARE_SCRIPT="$2"; shift 2 ;;
    --prepare-scale) PREPARE_SCALE="$2"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --keep-target-db) KEEP_TARGET_DB="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for n in "$PORT" "$PREPARE_SCALE" "$WAIT_SECONDS" "$POLL_SECONDS"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "Numeric option expected, got: $n" >&2
    exit 2
  fi
done

if [[ ! -x "$MO_TOOL" ]]; then
  echo "mo-tool not found or not executable: $MO_TOOL" >&2
  exit 2
fi
if [[ ! -d "$CKP_DATA" ]]; then
  echo "checkpoint path not found: $CKP_DATA" >&2
  exit 2
fi
if [[ "$PREPARE_IF_MISSING" == "1" && ! -x "$PREPARE_SCRIPT" ]]; then
  echo "prepare script not found or not executable: $PREPARE_SCRIPT" >&2
  exit 2
fi

mkdir -p "$OUT"
LOG_DIR="$OUT/logs"
mkdir -p "$LOG_DIR"

TABLES=(t_empty t_hash_partition t_key_partition)

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

log() {
  printf '%s\n' "$*"
}

table_select_sql() {
  local table="$1"
  case "$table" in
    t_empty)
      printf 'SELECT id, note FROM `%s`.`%s` ORDER BY id' "$DB_NAME" "$table"
      ;;
    t_hash_partition)
      printf 'SELECT id, payload FROM `%s`.`%s` ORDER BY id' "$DB_NAME" "$table"
      ;;
    t_key_partition)
      printf 'SELECT id, tenant_id, payload FROM `%s`.`%s` ORDER BY id, tenant_id' "$DB_NAME" "$table"
      ;;
    *)
      echo "unsupported table: $table" >&2
      exit 2
      ;;
  esac
}

assert_restore_patterns() {
  local table="$1"
  local restore="$2"
  case "$table" in
    t_empty)
      rg -q 'PRIMARY KEY \(`id`\)' "$restore"
      ;;
    t_hash_partition)
      rg -q 'PRIMARY KEY \(`id`\)' "$restore"
      rg -qi 'partition by hash \(`id`\) partitions 4' "$restore"
      ;;
    t_key_partition)
      rg -q 'PRIMARY KEY \(`id`, `tenant_id`\)' "$restore"
      rg -qi 'partition by key algorithm = 2 \(`id`, `tenant_id`\) partitions 4' "$restore"
      ;;
  esac
}

source_db_exists="$(mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT COUNT(*) FROM mo_catalog.mo_database WHERE datname = '$DB_NAME';" | tr -d '[:space:]')"
if [[ "$source_db_exists" != "1" ]]; then
  if [[ "$PREPARE_IF_MISSING" == "1" ]]; then
    log "==> Source database $DB_NAME not found, running prepare script"
    "$PREPARE_SCRIPT" \
      --host "$HOST" \
      --port "$PORT" \
      --user "$SOURCE_USER" \
      --password "$SOURCE_PASSWORD" \
      --db-prefix ckp \
      --scale "$PREPARE_SCALE" \
      --drop-existing \
      2>&1 | tee "$LOG_DIR/prepare.log"
  else
    echo "source database $DB_NAME not found; rerun with --prepare-if-missing or prepare data first" >&2
    exit 1
  fi
fi

log "==> Query source row counts"
SOURCE_COUNTS="$OUT/source_counts.tsv"
{
  printf 'table\tsource_count\n'
  for table in "${TABLES[@]}"; do
    count="$(mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT COUNT(*) FROM \`$DB_NAME\`.\`$table\`;")"
    printf '%s\t%s\n' "$table" "$count"
  done
} | tee "$SOURCE_COUNTS"

log "==> Wait for $DB_NAME in checkpoint metadata"
DATABASES_TXT="$OUT/databases.txt"
TABLES_TXT="$OUT/tables.txt"
DB_ID=""
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while (( $(date +%s) <= deadline )); do
  "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$DATABASES_TXT"
  DB_ID="$(awk -v db="$DB_NAME" '$2 == db {print $3; exit}' "$DATABASES_TXT")"
  if [[ -n "$DB_ID" ]]; then
    break
  fi
  sleep "$POLL_SECONDS"
done

if [[ -z "$DB_ID" ]]; then
  echo "database $DB_NAME not found in checkpoint within ${WAIT_SECONDS}s" >&2
  exit 1
fi
log "DB_ID=$DB_ID"

"$MO_TOOL" ckp list --type=tables --database-id="$DB_ID" "$CKP_DATA" | tee "$TABLES_TXT"

EMPTY_ID="$(awk '$3=="t_empty"{print $4}' "$TABLES_TXT")"
HASH_ID="$(awk '$3=="t_hash_partition"{print $4}' "$TABLES_TXT")"
KEY_ID="$(awk '$3=="t_key_partition"{print $4}' "$TABLES_TXT")"

if [[ -z "$EMPTY_ID" || -z "$HASH_ID" || -z "$KEY_ID" ]]; then
  echo "failed to resolve table ids from checkpoint metadata" >&2
  exit 1
fi

declare -A TABLE_IDS=(
  [t_empty]="$EMPTY_ID"
  [t_hash_partition]="$HASH_ID"
  [t_key_partition]="$KEY_ID"
)

SUMMARY="$OUT/summary.tsv"
printf 'table\ttable_id\tsource_count\tcsv_lines\texpected_csv_lines\trestore_check\tload_status\ttarget_count\tschema_status\tdata_status\n' > "$SUMMARY"

if [[ "$KEEP_TARGET_DB" != "1" ]]; then
  log "==> Drop target database on normal tenant"
  mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "DROP DATABASE IF EXISTS \`$DB_NAME\`;"
fi

overall_rc=0

for table in "${TABLES[@]}"; do
  table_id="${TABLE_IDS[$table]}"
  table_dir="$OUT/${table_id}_${table}"
  log_file="$OUT/${table_id}_${table}.log"
  mkdir -p "$table_dir"

  log "==> Dump $table table_id=$table_id"
  "$MO_TOOL" ckp dump \
    --table-id="$table_id" \
    --header \
    --load-script \
    -o "$table_dir" \
    "$CKP_DATA" 2>&1 | tee "$log_file"

  restore="$table_dir/restore.sql"
  csv_file="$(find "$table_dir" -type f -name '*.csv' | head -1)"
  if [[ ! -f "$restore" || -z "$csv_file" ]]; then
    echo "missing restore.sql or csv for $table" >&2
    exit 1
  fi

  source_count="$(awk -v t="$table" '$1 == t {print $2}' "$SOURCE_COUNTS")"
  csv_lines="$(wc -l < "$csv_file" | tr -d '[:space:]')"
  expected_csv_lines=$(( source_count + 1 ))

  restore_check="OK"
  if ! assert_restore_patterns "$table" "$restore"; then
    restore_check="FAIL"
    overall_rc=1
  fi

  if [[ "$csv_lines" != "$expected_csv_lines" ]]; then
    overall_rc=1
  fi

  load_log="$LOG_DIR/load_${table}.log"
  load_status="OK"
  if ! MYSQL_PWD="$TARGET_PASSWORD" "$MYSQL_BIN" \
      -h"$HOST" \
      -P"$PORT" \
      -u"$TARGET_USER" \
      --default-character-set=utf8mb4 \
      < "$restore" > "$load_log" 2>&1; then
    load_status="FAIL"
    overall_rc=1
  fi

  target_count="NA"
  schema_status="SKIP"
  data_status="SKIP"

  if [[ "$load_status" == "OK" ]]; then
    target_count="$(mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SELECT COUNT(*) FROM \`$DB_NAME\`.\`$table\`;")"
    if [[ "$target_count" != "$source_count" ]]; then
      overall_rc=1
    fi

    source_schema="$OUT/source_schema_${table}.txt"
    target_schema="$OUT/target_schema_${table}.txt"
    mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SHOW CREATE TABLE \`$DB_NAME\`.\`$table\`;" > "$source_schema"
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SHOW CREATE TABLE \`$DB_NAME\`.\`$table\`;" > "$target_schema"
    if diff -u "$source_schema" "$target_schema" > "$OUT/${table}.schema.diff"; then
      schema_status="OK"
    else
      schema_status="DIFF"
      overall_rc=1
    fi

    source_data="$OUT/source_data_${table}.tsv"
    target_data="$OUT/target_data_${table}.tsv"
    mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "$(table_select_sql "$table")" > "$source_data"
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "$(table_select_sql "$table")" > "$target_data"
    if diff -u "$source_data" "$target_data" > "$OUT/${table}.data.diff"; then
      data_status="OK"
    else
      data_status="DIFF"
      overall_rc=1
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$table" \
    "$table_id" \
    "$source_count" \
    "$csv_lines" \
    "$expected_csv_lines" \
    "$restore_check" \
    "$load_status" \
    "$target_count" \
    "$schema_status" \
    "$data_status" \
    >> "$SUMMARY"
done

log "==> Summary"
column -t -s $'\t' "$SUMMARY" || cat "$SUMMARY"

if [[ "$overall_rc" -eq 0 ]]; then
  log "PASS: issue #24990 verification passed"
else
  log "FAIL: issue #24990 verification found differences"
fi

log "Artifacts: $OUT"
exit "$overall_rc"
