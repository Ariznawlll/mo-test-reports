#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify checkpoint dump database-level restore for MatrixOne coverage databases.

This script fills the gap between large benchmark database dumps and the
table-id based coverage regression. It prepares the same ckp_* coverage data,
then dumps each coverage database with --database-id --load-script, restores the
database-level restore.sql into a normal tenant, and compares table list, row
counts, schemas, and data for small tables.

Usage:
  ./verify_database_level_dump_restore.sh [options]

Options:
  --host HOST                  MatrixOne MySQL host. Default: 127.0.0.1
  --port PORT                  MatrixOne MySQL port. Default: 6001
  --source-user USER           Source tenant user. Default: dump
  --source-password PASS       Source tenant password. Default: 111
  --target-user USER           Target tenant user. Default: acc01:test_account
  --target-password PASS       Target tenant password. Default: 111
  --db-prefix PREFIX           Coverage database prefix. Default: ckp
  --scale N                    Coverage scale rows. Default: 10000
  --jobs N                     mo-tool database dump jobs. Default: 4
  --mo-tool PATH               mo-tool path. Default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH              Checkpoint data path
  --out DIR                    Output dir. Default: /data4/weilu/verify_db_level_<timestamp>
  --mysql-bin PATH             mysql client path. Default: mysql
  --prepare-script PATH        Coverage prepare script path
  --wait-seconds N             Max wait for checkpoint metadata. Default: 600
  --poll-seconds N             Poll interval. Default: 10
  --data-compare-max-rows N    Full data compare threshold. Default: 20000
  --drop-existing              Drop coverage databases before preparing data
  --drop-target-account        Drop and recreate target account before restore
  --skip-prepare               Do not prepare data; use existing ckp_* databases
  --help                       Show this help
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
JOBS="4"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_db_level_${TS}"
MYSQL_BIN="mysql"
PREPARE_SCRIPT="$SCRIPT_DIR/prepare_ckp_dump_coverage_data.sh"
WAIT_SECONDS="600"
POLL_SECONDS="10"
DATA_COMPARE_MAX_ROWS="20000"
DROP_EXISTING="0"
DROP_TARGET_ACCOUNT="0"
SKIP_PREPARE="0"

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
    --jobs) JOBS="$2"; shift 2 ;;
    --mo-tool) MO_TOOL="$2"; shift 2 ;;
    --ckp-data) CKP_DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --prepare-script) PREPARE_SCRIPT="$2"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --data-compare-max-rows) DATA_COMPARE_MAX_ROWS="$2"; shift 2 ;;
    --drop-existing) DROP_EXISTING="1"; shift ;;
    --drop-target-account) DROP_TARGET_ACCOUNT="1"; shift ;;
    --skip-prepare) SKIP_PREPARE="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for n in "$PORT" "$SCALE" "$JOBS" "$WAIT_SECONDS" "$POLL_SECONDS" "$DATA_COMPARE_MAX_ROWS"; do
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
if [[ "$SKIP_PREPARE" != "1" && ! -x "$PREPARE_SCRIPT" ]]; then
  echo "prepare script not found or not executable: $PREPARE_SCRIPT" >&2
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

DB_SUMMARY="$OUT/db_dump_summary.tsv"
TABLE_MANIFEST="$OUT/table_manifest.tsv"
TABLE_LIST_SUMMARY="$OUT/table_list_summary.tsv"
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

  log "==> Prepare checkpoint dump coverage data"
  "$PREPARE_SCRIPT" "${args[@]}" 2>&1 | tee "$LOG_DIR/prepare.log"
  if grep -q '^ERROR ' "$LOG_DIR/prepare.log"; then
    echo "prepare script reported SQL errors; stop before checkpoint dump" >&2
    return 1
  fi
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

collect_table_manifest() {
  local db
  local db_id
  local table_file

  printf 'db\tdb_id\ttable\ttable_id\n' > "$TABLE_MANIFEST"
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
      "$table_file" >> "$TABLE_MANIFEST"
  done
}

dump_databases() {
  local db
  local db_id
  local db_dir
  local log_file
  local restore
  local nul_status
  local dump_status
  local manifest_tables

  printf 'db\tdb_id\tdump_status\tmanifest_tables\trestore_sql\tnul_status\tlog\n' > "$DB_SUMMARY"

  for db in "${CORE_DBS[@]}"; do
    db_id="$(awk -v db="$db" '$2 == db {print $3; exit}' "$OUT/databases.txt")"
    db_dir="$DUMP_DIR/$db"
    log_file="$LOG_DIR/${db}.database_dump.log"
    restore="$db_dir/restore.sql"
    mkdir -p "$db_dir"

    log "==> Database-level dump $db db_id=$db_id"
    set +e
    "$MO_TOOL" ckp dump \
      --database-id="$db_id" \
      --header \
      --load-script \
      --jobs="$JOBS" \
      -o "$db_dir" \
      "$CKP_DATA" > "$log_file" 2>&1
    dump_status=$?
    set -e

    manifest_tables="$(awk -F'\t' -v db="$db" 'NR > 1 && $1 == db {n++} END {print n+0}' "$TABLE_MANIFEST")"
    nul_status="MISSING"
    if [[ -f "$restore" ]]; then
      if contains_nul "$restore"; then
        nul_status="NUL_FOUND"
      else
        nul_status="OK"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$db" "$db_id" "$dump_status" "$manifest_tables" "$restore" "$nul_status" "$log_file" >> "$DB_SUMMARY"
  done
}

restore_databases() {
  local db
  local db_id
  local restore
  local log_file
  local status
  local rc

  printf 'db\tdb_id\tload_status\trestore_sql\tlog\n' > "$RESTORE_SUMMARY"

  for db in "${CORE_DBS[@]}"; do
    log "==> Drop target database $db"
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "DROP DATABASE IF EXISTS \`$db\`;" \
      > "$LOG_DIR/drop_target_${db}.log" 2>&1 || true
  done

  for db in "${CORE_DBS[@]}"; do
    db_id="$(awk -v db="$db" '$2 == db {print $3; exit}' "$OUT/databases.txt")"
    restore="$DUMP_DIR/$db/restore.sql"
    log_file="$LOG_DIR/${db}.database_restore.log"

    if [[ ! -f "$restore" ]]; then
      status="MISSING_RESTORE_SQL"
      : > "$log_file"
    else
      log "==> Restore database-level dump $db"
      set +e
      MYSQL_PWD="$TARGET_PASSWORD" "$MYSQL_BIN" \
        -h"$HOST" \
        -P"$PORT" \
        -u"$TARGET_USER" \
        --default-character-set=utf8mb4 \
        --binary-mode=1 \
        --force \
        < "$restore" > "$log_file" 2>&1
      rc=$?
      set -e
      if [[ "$rc" -eq 0 ]] && [[ -f "$log_file" ]] && ! grep -q '^ERROR ' "$log_file"; then
        status="OK"
      else
        status="FAIL"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' "$db" "$db_id" "$status" "$restore" "$log_file" >> "$RESTORE_SUMMARY"
  done
}

compare_table_lists() {
  local db
  local source_file
  local target_file
  local diff_file
  local status

  printf 'db\tsource_tables\ttarget_tables\tstatus\tdiff\n' > "$TABLE_LIST_SUMMARY"

  for db in "${CORE_DBS[@]}"; do
    source_file="$COMPARE_DIR/${db}.source_tables.txt"
    target_file="$COMPARE_DIR/${db}.target_tables.txt"
    diff_file="$COMPARE_DIR/${db}.table_list.diff"

    awk -F'\t' -v db="$db" 'NR > 1 && $1 == db {print $3}' "$TABLE_MANIFEST" | LC_ALL=C sort > "$source_file"
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SHOW FULL TABLES FROM \`$db\`;" \
      | awk -F'\t' '$2 == "BASE TABLE" && $1 !~ /^__mo_tmp_/ && $1 !~ /(^|_)tmp_checkpoint_visibility$/ {print $1}' \
      | LC_ALL=C sort > "$target_file" || true

    if diff -u "$source_file" "$target_file" > "$diff_file"; then
      status="OK"
    else
      status="DIFF"
    fi

    printf '%s\t%s\t%s\t%s\t%s\n' \
      "$db" "$(wc -l < "$source_file" | tr -d ' ')" "$(wc -l < "$target_file" | tr -d ' ')" "$status" "$diff_file" \
      >> "$TABLE_LIST_SUMMARY"
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

  tail -n +2 "$TABLE_MANIFEST" | sort -t $'\t' -k1,1 -k4,4n | while IFS=$'\t' read -r db db_id table table_id; do
    source_schema="$COMPARE_DIR/${db}_${table_id}_${table}.source.schema.sql"
    target_schema="$COMPARE_DIR/${db}_${table_id}_${table}.target.schema.sql"
    schema_diff="$COMPARE_DIR/${db}_${table_id}_${table}.schema.diff"
    source_data="$COMPARE_DIR/${db}_${table_id}_${table}.source.data.tsv"
    target_data="$COMPARE_DIR/${db}_${table_id}_${table}.target.data.tsv"
    data_diff="$COMPARE_DIR/${db}_${table_id}_${table}.data.diff"

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

final_check() {
  local failed=0

  log "==> Database-level summary files"
  log "db dump: $DB_SUMMARY"
  log "restore: $RESTORE_SUMMARY"
  log "table list: $TABLE_LIST_SUMMARY"
  log "compare: $COMPARE_SUMMARY"

  log "==> Database-level dump summary"
  column -t -s $'\t' "$DB_SUMMARY" || cat "$DB_SUMMARY"
  log "==> Database-level restore summary"
  column -t -s $'\t' "$RESTORE_SUMMARY" || cat "$RESTORE_SUMMARY"
  log "==> Database-level table-list summary"
  column -t -s $'\t' "$TABLE_LIST_SUMMARY" || cat "$TABLE_LIST_SUMMARY"
  log "==> Database-level compare summary"
  column -t -s $'\t' "$COMPARE_SUMMARY" || cat "$COMPARE_SUMMARY"

  if awk -F'\t' 'NR > 1 && ($3 != "0" || $6 != "OK") {bad=1} END {exit bad ? 0 : 1}' "$DB_SUMMARY"; then
    echo "database dump summary has failures" >&2
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && $3 != "OK" {bad=1} END {exit bad ? 0 : 1}' "$RESTORE_SUMMARY"; then
    echo "database restore summary has failures" >&2
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && $4 != "OK" {bad=1} END {exit bad ? 0 : 1}' "$TABLE_LIST_SUMMARY"; then
    echo "database table list summary has differences" >&2
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && ($6 != "OK" || $7 != "OK" || ($8 != "OK" && $8 != "SKIP")) {bad=1} END {exit bad ? 0 : 1}' "$COMPARE_SUMMARY"; then
    echo "database compare summary has failures" >&2
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "DATABASE_LEVEL_DUMP_RESTORE_FAIL"
    return 1
  fi

  echo "DATABASE_LEVEL_DUMP_RESTORE_OK"
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
dump_databases
restore_databases
compare_table_lists
compare_restored_tables
final_check
