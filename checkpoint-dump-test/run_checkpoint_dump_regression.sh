#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Run checkpoint dump end-to-end regression.

Flow:
  1. Prepare checkpoint-dump coverage data in the source tenant.
  2. Trigger a checkpoint.
  3. Discover database/table IDs from mo-tool ckp list.
  4. Dump every regular coverage table with --header --load-script.
  5. Load restore.sql files into a normal tenant.
  6. Compare source vs target schema, row counts, CSV row counts, and full data
     for tables whose row count is under --data-compare-max-rows.
  7. Temporary/external cases are skipped by default because they have known bugs.

Usage:
  ./run_checkpoint_dump_regression.sh [options]

Options:
  --host HOST                     MatrixOne MySQL host. Default: 127.0.0.1
  --port PORT                     MatrixOne MySQL port. Default: 6001
  --source-user USER              Source tenant user. Default: dump
  --source-password PASS          Source tenant password. Default: 111
  --target-user USER              Target tenant user. Default: acc01:test_account
  --target-password PASS          Target tenant password. Default: 111
  --db-prefix PREFIX              Coverage database prefix. Default: ckp
  --scale N                       Coverage scale rows. Default: 10000
  --mo-tool PATH                  mo-tool path. Default: ./mo-tool
  --ckp-data PATH                 Checkpoint data path. Default: ./mo-data/shared
  --out DIR                       Output dir. Default: /data4/checkpoint_dump_regression_<timestamp>
  --mysql-bin PATH                mysql client path. Default: mysql
  --prepare-script PATH           Coverage prepare script path.
  --temp-external-script PATH     Temporary/external focused verifier path.
  --wait-seconds N                Max wait for checkpoint metadata. Default: 600
  --poll-seconds N                Poll interval. Default: 10
  --data-compare-max-rows N       Full data compare threshold. Default: 20000
  --drop-existing                 Drop coverage databases before preparing data.
  --drop-target-account           Drop and recreate target account before restore.
  --skip-prepare                  Do not prepare data.
  --skip-temp-external            Do not run temporary/external verifier. Default: skipped.
  --include-temp-external         Prepare and run temporary/external verifier.
  --help                          Show this help.
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
DB_PREFIX="ckp"
SCALE="10000"
MO_TOOL="./mo-tool"
CKP_DATA="./mo-data/shared"
OUT="/data4/checkpoint_dump_regression_${TS}"
MYSQL_BIN="mysql"
PREPARE_SCRIPT="$SCRIPT_DIR/prepare_ckp_dump_coverage_data.sh"
TEMP_EXTERNAL_SCRIPT="$SCRIPT_DIR/verify_temp_external_tables.sh"
WAIT_SECONDS="600"
POLL_SECONDS="10"
DATA_COMPARE_MAX_ROWS="20000"
DROP_EXISTING="0"
DROP_TARGET_ACCOUNT="0"
SKIP_PREPARE="0"
SKIP_TEMP_EXTERNAL="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --source-user) SOURCE_USER="$2"; shift 2 ;;
    --source-password) SOURCE_PASSWORD="$2"; shift 2 ;;
    --target-user) TARGET_USER="$2"; shift 2 ;;
    --target-password) TARGET_PASSWORD="$2"; shift 2 ;;
    --db-prefix) DB_PREFIX="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --mo-tool) MO_TOOL="$2"; shift 2 ;;
    --ckp-data) CKP_DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --prepare-script) PREPARE_SCRIPT="$2"; shift 2 ;;
    --temp-external-script) TEMP_EXTERNAL_SCRIPT="$2"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --data-compare-max-rows) DATA_COMPARE_MAX_ROWS="$2"; shift 2 ;;
    --drop-existing) DROP_EXISTING="1"; shift ;;
    --drop-target-account) DROP_TARGET_ACCOUNT="1"; shift ;;
    --skip-prepare) SKIP_PREPARE="1"; shift ;;
    --skip-temp-external) SKIP_TEMP_EXTERNAL="1"; shift ;;
    --include-temp-external) SKIP_TEMP_EXTERNAL="0"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for n in "$PORT" "$SCALE" "$WAIT_SECONDS" "$POLL_SECONDS" "$DATA_COMPARE_MAX_ROWS"; do
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    echo "Numeric option expected, got: $n" >&2
    exit 2
  fi
done

case "$OUT" in
  /data4/*) ;;
  *)
    echo "--out must be under /data4 so checkpoint dump artifacts stay on the data disk: $OUT" >&2
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
if [[ "$SKIP_PREPARE" != "1" && ! -x "$PREPARE_SCRIPT" ]]; then
  echo "prepare script not found or not executable: $PREPARE_SCRIPT" >&2
  exit 2
fi
if [[ "$SKIP_TEMP_EXTERNAL" != "1" && ! -x "$TEMP_EXTERNAL_SCRIPT" ]]; then
  echo "temp/external script not found or not executable: $TEMP_EXTERNAL_SCRIPT" >&2
  exit 2
fi

CORE_DBS=(
  "${DB_PREFIX}_types"
  "${DB_PREFIX}_constraints"
  "${DB_PREFIX}_tables"
  "${DB_PREFIX}_mvcc_perf"
)

LOG_DIR="$OUT/logs"
DUMP_DIR="$OUT/dumps"
COMPARE_DIR="$OUT/compare"
mkdir -p "$LOG_DIR" "$DUMP_DIR" "$COMPARE_DIR"

SUMMARY="$OUT/summary.tsv"
MANIFEST="$OUT/table_manifest.tsv"
RESTORE_SUMMARY="$OUT/restore_summary.tsv"
COMPARE_SUMMARY="$OUT/compare_summary.tsv"

log() {
  printf '%s\n' "$*"
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

quote_sql_string() {
  printf "%s" "$1" | sed "s/'/''/g"
}

safe_name() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

contains_nul() {
  local file="$1"
  perl -0777 -ne 'exit(index($_, "\0") >= 0 ? 0 : 1)' "$file"
}

normalize_schema() {
  local db="$1"
  sed -E \
    -e "s/CREATE TABLE \`$db\`\.\`/CREATE TABLE \`/g" \
    -e 's/AUTO_INCREMENT=[0-9]+//g' \
    -e 's/[[:space:]]+$//'
}

dump_table_data() {
  local user="$1"
  local password="$2"
  local db="$3"
  local table="$4"
  local out_file="$5"

  MYSQL_PWD="$password" "$MYSQL_BIN" \
    -h"$HOST" \
    -P"$PORT" \
    -u"$user" \
    --default-character-set=utf8mb4 \
    --binary-mode=1 \
    --batch \
    --raw \
    --skip-column-names \
    -e "SELECT * FROM \`$db\`.\`$table\`;" \
    | LC_ALL=C sort > "$out_file"
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

  if [[ "$DROP_TARGET_ACCOUNT" == "1" ]]; then
    log "==> Drop target account $account"
    mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "DROP ACCOUNT IF EXISTS \`$account\`;" > "$LOG_DIR/drop_target_account.log" 2>&1 || true
  fi

  log "==> Ensure target account $TARGET_USER"
  mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" \
    "CREATE ACCOUNT \`$account\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_target_account.log" 2>&1 || true
}

trigger_checkpoint() {
  log "==> Trigger checkpoint"
  mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT mo_ctl('dn', 'checkpoint', '');" \
    2>&1 | tee "$LOG_DIR/trigger_checkpoint.log"
}

wait_core_databases() {
  local db
  local all_found
  local deadline=$(( $(date +%s) + WAIT_SECONDS ))

  log "==> Wait for coverage databases in checkpoint metadata"
  while (( $(date +%s) <= deadline )); do
    "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$OUT/databases.txt" 2> "$LOG_DIR/ckp_list_databases.err" || true
    all_found="1"
    for db in "${CORE_DBS[@]}"; do
      if ! awk -v db="$db" '$2 == db {found=1} END {exit found ? 0 : 1}' "$OUT/databases.txt"; then
        all_found="0"
      fi
    done
    if [[ "$all_found" == "1" ]]; then
      return 0
    fi
    log "    checkpoint metadata is not ready yet; retry after ${POLL_SECONDS}s"
    sleep "$POLL_SECONDS"
  done

  echo "coverage databases not found in checkpoint within ${WAIT_SECONDS}s" >&2
  return 1
}

prepare_data() {
  if [[ "$SKIP_PREPARE" == "1" ]]; then
    log "==> Skip prepare"
    return 0
  fi

  local args=(
    --host "$HOST"
    --port "$PORT"
    --user "$SOURCE_USER"
    --password "$SOURCE_PASSWORD"
    --db-prefix "$DB_PREFIX"
    --scale "$SCALE"
    --out-dir "$OUT/prepare_sql"
  )
  if [[ "$DROP_EXISTING" == "1" ]]; then
    args+=(--drop-existing)
  fi
  if [[ "$SKIP_TEMP_EXTERNAL" != "1" ]]; then
    args+=(--include-temp-external)
  fi

  log "==> Prepare checkpoint dump coverage data"
  "$PREPARE_SCRIPT" "${args[@]}" 2>&1 | tee "$LOG_DIR/prepare.log"
}

collect_table_manifest() {
  local db
  local db_id
  local table_file

  printf 'db\tdb_id\ttable\ttable_id\n' > "$MANIFEST"
  for db in "${CORE_DBS[@]}"; do
    db_id="$(awk -v db="$db" '$2 == db {print $3; exit}' "$OUT/databases.txt")"
    if [[ -z "$db_id" ]]; then
      echo "database ID not found for $db" >&2
      return 1
    fi

    table_file="$OUT/${db}_tables.txt"
    "$MO_TOOL" ckp list --type=tables --database-id="$db_id" "$CKP_DATA" \
      > "$table_file" 2> "$LOG_DIR/${db}_ckp_list_tables.err"

    awk -v db="$db" -v db_id="$db_id" \
      'NR > 1 && $5 == "r" && $3 !~ /^__mo_tmp_/ && $3 !~ /(^|_)tmp_checkpoint_visibility$/ {print db "\t" db_id "\t" $3 "\t" $4}' \
      "$table_file" >> "$MANIFEST"
  done
}

dump_tables() {
  local db
  local db_id
  local table
  local table_id
  local tag
  local table_dir
  local log_file
  local restore
  local csv_file
  local csv_lines
  local restore_status
  local dump_status
  local source_count
  local expected_csv_lines

  printf 'db\ttable\ttable_id\tdump_status\tsource_count\tcsv_lines\texpected_csv_lines\trestore_sql\tnul_status\n' > "$SUMMARY"

  tail -n +2 "$MANIFEST" | sort -t $'\t' -k1,1 -k4,4n | while IFS=$'\t' read -r db db_id table table_id; do
    tag="$(safe_name "${db}_${table_id}_${table}")"
    table_dir="$DUMP_DIR/$tag"
    log_file="$LOG_DIR/${tag}.dump.log"
    restore="$table_dir/restore.sql"
    mkdir -p "$table_dir"

    log "==> Dump $db.$table table_id=$table_id"
    set +e
    "$MO_TOOL" ckp dump \
      --table-id="$table_id" \
      --header \
      --load-script \
      -o "$table_dir" \
      "$CKP_DATA" > "$log_file" 2>&1
    dump_status=$?
    set -e

    source_count="$(mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT COUNT(*) FROM \`$db\`.\`$table\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    csv_file="$(find "$table_dir" -type f -name "${table}_${table_id}.csv" -print -quit)"
    csv_lines="NA"
    expected_csv_lines="NA"
    if [[ -n "$csv_file" ]]; then
      csv_lines="$(wc -l < "$csv_file" | tr -d ' ')"
      if [[ "$source_count" =~ ^[0-9]+$ ]]; then
        expected_csv_lines=$((source_count + 1))
      fi
    fi

    restore_status="MISSING"
    if [[ -f "$restore" ]]; then
      if contains_nul "$restore"; then
        restore_status="NUL_FOUND"
      else
        restore_status="OK"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$db" "$table" "$table_id" "$dump_status" "$source_count" "$csv_lines" \
      "$expected_csv_lines" "$restore" "$restore_status" >> "$SUMMARY"
  done
}

load_restores() {
  local db
  local db_id
  local table
  local table_id
  local tag
  local restore
  local log_file
  local status

  printf 'db\ttable\ttable_id\tload_status\tlog\n' > "$RESTORE_SUMMARY"

  for db in "${CORE_DBS[@]}"; do
    log "==> Drop target database $db"
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "DROP DATABASE IF EXISTS \`$db\`;" \
      > "$LOG_DIR/drop_target_${db}.log" 2>&1 || true
  done

  tail -n +2 "$MANIFEST" | sort -t $'\t' -k1,1 -k4,4n | while IFS=$'\t' read -r db db_id table table_id; do
    tag="$(safe_name "${db}_${table_id}_${table}")"
    restore="$DUMP_DIR/$tag/restore.sql"
    log_file="$LOG_DIR/${tag}.restore.log"

    if [[ ! -f "$restore" ]]; then
      status="MISSING_RESTORE_SQL"
    else
      log "==> Load $db.$table into target tenant"
      set +e
      MYSQL_PWD="$TARGET_PASSWORD" "$MYSQL_BIN" \
        -h"$HOST" \
        -P"$PORT" \
        -u"$TARGET_USER" \
        --default-character-set=utf8mb4 \
        --binary-mode=1 \
        < "$restore" > "$log_file" 2>&1
      rc=$?
      set -e
      if [[ "$rc" -eq 0 ]]; then
        status="OK"
      else
        status="FAIL"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$db" "$table" "$table_id" "$status" "$log_file" >> "$RESTORE_SUMMARY"
  done
}

compare_restored_tables() {
  local db
  local db_id
  local table
  local table_id
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

  printf 'db\ttable\ttable_id\tsource_count\ttarget_count\tcount_status\tschema_status\tdata_status\n' > "$COMPARE_SUMMARY"

  tail -n +2 "$MANIFEST" | sort -t $'\t' -k1,1 -k4,4n | while IFS=$'\t' read -r db db_id table table_id; do
    tag="$(safe_name "${db}_${table_id}_${table}")"
    source_schema="$COMPARE_DIR/${tag}.source.schema.sql"
    target_schema="$COMPARE_DIR/${tag}.target.schema.sql"
    schema_diff="$COMPARE_DIR/${tag}.schema.diff"
    source_data="$COMPARE_DIR/${tag}.source.data.tsv"
    target_data="$COMPARE_DIR/${tag}.target.data.tsv"
    data_diff="$COMPARE_DIR/${tag}.data.diff"

    source_count="$(mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT COUNT(*) FROM \`$db\`.\`$table\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    target_count="$(mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SELECT COUNT(*) FROM \`$db\`.\`$table\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    if [[ "$source_count" == "$target_count" ]]; then
      count_status="OK"
    else
      count_status="DIFF"
    fi

    mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SHOW CREATE TABLE \`$db\`.\`$table\`;" \
      | cut -f2- | normalize_schema "$db" > "$source_schema" || true
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SHOW CREATE TABLE \`$db\`.\`$table\`;" \
      | cut -f2- | normalize_schema "$db" > "$target_schema" || true
    if diff -u "$source_schema" "$target_schema" > "$schema_diff"; then
      schema_status="OK"
    else
      schema_status="DIFF"
    fi

    data_status="SKIP"
    if [[ "$source_count" =~ ^[0-9]+$ && "$source_count" -le "$DATA_COMPARE_MAX_ROWS" ]]; then
      if dump_table_data "$SOURCE_USER" "$SOURCE_PASSWORD" "$db" "$table" "$source_data" \
          && dump_table_data "$TARGET_USER" "$TARGET_PASSWORD" "$db" "$table" "$target_data" \
          && diff -u "$source_data" "$target_data" > "$data_diff"; then
        data_status="OK"
      else
        data_status="DIFF"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$db" "$table" "$table_id" "$source_count" "$target_count" "$count_status" "$schema_status" "$data_status" \
      >> "$COMPARE_SUMMARY"
  done
}

run_temp_external() {
  if [[ "$SKIP_TEMP_EXTERNAL" == "1" ]]; then
    log "==> Skip temporary/external verifier"
    return 0
  fi

  log "==> Run temporary/external checkpoint dump verifier"
  set +e
  "$TEMP_EXTERNAL_SCRIPT" \
    --host "$HOST" \
    --port "$PORT" \
    --source-user "$SOURCE_USER" \
    --source-password "$SOURCE_PASSWORD" \
    --target-user "$TARGET_USER" \
    --target-password "$TARGET_PASSWORD" \
    --db-prefix "$DB_PREFIX" \
    --mo-tool "$MO_TOOL" \
    --ckp-data "$CKP_DATA" \
    --out "$OUT/temp_external" \
    --mysql-bin "$MYSQL_BIN" \
    --drop-existing \
    --hold-seconds 180 \
    --wait-seconds "$WAIT_SECONDS" \
    --poll-seconds "$POLL_SECONDS" \
    > "$LOG_DIR/temp_external.log" 2>&1
  rc=$?
  set -e
  echo "$rc" > "$OUT/temp_external_exit_status.txt"
  return "$rc"
}

final_check() {
  local failed=0

  log "==> Summary files"
  log "summary: $SUMMARY"
  log "restore: $RESTORE_SUMMARY"
  log "compare: $COMPARE_SUMMARY"

  # csv_lines is informational only: quoted CSV fields can legally contain
  # newlines, so wc -l is not a reliable record-count check.
  if awk -F '\t' 'NR > 1 && ($4 != "0" || $9 != "OK") {bad=1} END {exit bad ? 0 : 1}' "$SUMMARY"; then
    echo "checkpoint dump summary has failures" >&2
    failed=1
  fi

  if awk -F '\t' 'NR > 1 && $4 != "OK" {bad=1} END {exit bad ? 0 : 1}' "$RESTORE_SUMMARY"; then
    echo "restore summary has failures" >&2
    failed=1
  fi

  if awk -F '\t' 'NR > 1 && ($6 != "OK" || $7 != "OK" || ($8 != "OK" && $8 != "SKIP")) {bad=1} END {exit bad ? 0 : 1}' "$COMPARE_SUMMARY"; then
    echo "compare summary has failures" >&2
    failed=1
  fi

  if [[ "$SKIP_TEMP_EXTERNAL" != "1" ]]; then
    local temp_rc
    temp_rc="$(cat "$OUT/temp_external_exit_status.txt" 2>/dev/null || printf '1')"
    if [[ "$temp_rc" != "0" ]]; then
      echo "temporary/external verifier failed; see $LOG_DIR/temp_external.log and $OUT/temp_external" >&2
      failed=1
    fi
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "CHECKPOINT_DUMP_REGRESSION_FAIL"
    return 1
  fi

  echo "CHECKPOINT_DUMP_REGRESSION_OK"
}

log "OUT=$OUT"
log "MO_TOOL=$MO_TOOL"
log "CKP_DATA=$CKP_DATA"
log "DB_PREFIX=$DB_PREFIX"

ensure_target_account
prepare_data
trigger_checkpoint
wait_core_databases
collect_table_manifest
dump_tables
load_restores
compare_restored_tables
run_temp_external || true
final_check
