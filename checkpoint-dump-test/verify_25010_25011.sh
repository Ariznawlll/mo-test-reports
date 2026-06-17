#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify MatrixOne checkpoint dump fixes for:
  #25010 external table database/table visibility and dump/restore
  #25011 temporary table should not be dumped/restored with __mo_tmp internal name

Usage:
  ./verify_25010_25011.sh [options]

Options:
  --host HOST                 MatrixOne MySQL host, default: 127.0.0.1
  --port PORT                 MatrixOne MySQL port, default: 6001
  --source-user USER          Source tenant user, default: dump
  --source-password PASS      Source tenant password, default: 111
  --target-user USER          Target tenant user, default: acc01:test_account
  --target-password PASS      Target tenant password, default: 111
  --db-prefix PREFIX          Database prefix, default: ckp25010
  --mo-tool PATH              mo-tool path, default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH             Checkpoint data path
  --out DIR                   Output dir, default: /data4/weilu/verify_25010_25011_<timestamp>
  --mysql-bin PATH            mysql client path, default: mysql
  --hold-seconds N            Keep temp-table session open, default: 240
  --wait-seconds N            Max wait for checkpoint metadata, default: 180
  --poll-seconds N            Poll interval, default: 5
  --checkpoint-delay N        Seconds before triggering checkpoint, default: 5
  --drop-existing             Drop source test databases before setup
  --help                      Show this help

Exit code:
  0: both issue checks pass
  1: at least one issue check fails
USAGE
}

TS="$(date +%Y%m%d_%H%M%S)"
HOST="127.0.0.1"
PORT="6001"
SOURCE_USER="dump"
SOURCE_PASSWORD="111"
TARGET_USER="acc01:test_account"
TARGET_PASSWORD="111"
DB_PREFIX="ckp25010"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_25010_25011_${TS}"
MYSQL_BIN="mysql"
HOLD_SECONDS="240"
WAIT_SECONDS="180"
POLL_SECONDS="5"
CHECKPOINT_DELAY="5"
DROP_EXISTING="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --source-user) SOURCE_USER="$2"; shift 2 ;;
    --source-password) SOURCE_PASSWORD="$2"; shift 2 ;;
    --target-user) TARGET_USER="$2"; shift 2 ;;
    --target-password) TARGET_PASSWORD="$2"; shift 2 ;;
    --db-prefix) DB_PREFIX="$2"; shift 2 ;;
    --mo-tool) MO_TOOL="$2"; shift 2 ;;
    --ckp-data) CKP_DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --hold-seconds) HOLD_SECONDS="$2"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --checkpoint-delay) CHECKPOINT_DELAY="$2"; shift 2 ;;
    --drop-existing) DROP_EXISTING="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for n in "$PORT" "$HOLD_SECONDS" "$WAIT_SECONDS" "$POLL_SECONDS" "$CHECKPOINT_DELAY"; do
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
  echo "checkpoint data path not found: $CKP_DATA" >&2
  exit 2
fi

DB_TEMP="${DB_PREFIX}_temp"
DB_EXT="${DB_PREFIX}_external"
LOG_DIR="$OUT/logs"
FIXTURE_DIR="$OUT/external_fixtures"
DUMP_DIR="$OUT/dumps"
SUMMARY="$OUT/summary.tsv"
DETAIL="$OUT/detail.txt"
mkdir -p "$LOG_DIR" "$FIXTURE_DIR" "$DUMP_DIR"

log() {
  printf '%s\n' "$*" >&2
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

safe_name() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

sql_escape_path() {
  printf '%s' "$1" | sed "s/'/''/g"
}

dump_table() {
  local db="$1"
  local table="$2"
  local table_id="$3"
  local tag
  local dir
  local log_file
  local rc

  tag="$(safe_name "${db}_${table_id}_${table}")"
  dir="$DUMP_DIR/$tag"
  log_file="$LOG_DIR/${tag}.dump.log"
  mkdir -p "$dir"

  set +e
  "$MO_TOOL" ckp dump \
    --table-id="$table_id" \
    --header \
    --load-script \
    -o "$dir" \
    "$CKP_DATA" > "$log_file" 2>&1
  rc=$?
  set -e

  printf '%s\t%s\t%s\n' "$rc" "$dir" "$log_file"
}

restore_sql() {
  local db="$1"
  local restore="$2"
  local log_file="$3"
  local rc

  mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "DROP DATABASE IF EXISTS \`$db\`;" > /dev/null 2>&1 || true

  set +e
  MYSQL_PWD="$TARGET_PASSWORD" "$MYSQL_BIN" \
    -h"$HOST" \
    -P"$PORT" \
    -u"$TARGET_USER" \
    --default-character-set=utf8mb4 \
    < "$restore" > "$log_file" 2>&1
  rc=$?
  set -e

  return "$rc"
}

record() {
  local issue="$1"
  local case_name="$2"
  local status="$3"
  local detail="$4"
  printf '%s\t%s\t%s\t%s\n' "$issue" "$case_name" "$status" "$detail" >> "$SUMMARY"
}

TEMP_PID=""
cleanup() {
  if [[ -n "$TEMP_PID" ]] && kill -0 "$TEMP_PID" 2>/dev/null; then
    kill "$TEMP_PID" 2>/dev/null || true
    wait "$TEMP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

printf 'issue\tcase\tstatus\tdetail\n' > "$SUMMARY"
{
  echo "OUT=$OUT"
  echo "DB_TEMP=$DB_TEMP"
  echo "DB_EXT=$DB_EXT"
  echo "MO_TOOL=$MO_TOOL"
  echo "CKP_DATA=$CKP_DATA"
} > "$DETAIL"

log "OUT=$OUT"
log "DB_TEMP=$DB_TEMP"
log "DB_EXT=$DB_EXT"

"$MO_TOOL" ckp list --help >/dev/null
"$MO_TOOL" ckp dump --help >/dev/null

CSV_FILE="$FIXTURE_DIR/local_ext_people.csv"
printf '%s\n' \
  '1,alice,10.50,plain' \
  '2,bob,20.00,"comma,value"' \
  '3,charlie,0.00,"quote ""inside"""' \
  > "$CSV_FILE"
CSV_FILE_SQL="$(sql_escape_path "$CSV_FILE")"

if [[ "$DROP_EXISTING" == "1" ]]; then
  log "==> Drop existing source test databases"
  mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "DROP DATABASE IF EXISTS \`$DB_TEMP\`; DROP DATABASE IF EXISTS \`$DB_EXT\`;" > "$LOG_DIR/drop_source.log" 2>&1 || true
fi

log "==> Create external table fixture for #25010"
cat > "$OUT/create_external.sql" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_EXT\`;
USE \`$DB_EXT\`;
DROP TABLE IF EXISTS ext_csv_local;
CREATE EXTERNAL TABLE ext_csv_local (
  id INT,
  name VARCHAR(50),
  score DECIMAL(10,2),
  note VARCHAR(100)
) INFILE {
  'filepath'='$CSV_FILE_SQL',
  'format'='csv'
};
SELECT COUNT(*) FROM ext_csv_local;
SQL

EXT_SETUP_STATUS="OK"
if ! mysql_exec "$SOURCE_USER" "$SOURCE_PASSWORD" < "$OUT/create_external.sql" > "$LOG_DIR/external_setup.log" 2>&1; then
  EXT_SETUP_STATUS="FAIL"
fi
EXT_SOURCE_COUNT="$(mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT COUNT(*) FROM \`$DB_EXT\`.ext_csv_local;" 2>/dev/null || printf 'QUERY_FAIL')"

log "==> Start temp table session for #25011"
cat > "$OUT/create_temp_hold.sql" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_TEMP\`;
USE \`$DB_TEMP\`;
DROP TABLE IF EXISTS temp_case_marker;
CREATE TABLE temp_case_marker (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(120)
);
REPLACE INTO temp_case_marker VALUES (1, 'permanent marker for temp table checkpoint test');
CREATE TEMPORARY TABLE t_session_only (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(30)
);
INSERT INTO t_session_only VALUES (1, 'temporary row');
SELECT COUNT(*) FROM temp_case_marker;
SELECT COUNT(*) FROM t_session_only;
SELECT SLEEP($HOLD_SECONDS);
SQL

mysql_exec "$SOURCE_USER" "$SOURCE_PASSWORD" < "$OUT/create_temp_hold.sql" > "$LOG_DIR/temp_session.log" 2>&1 &
TEMP_PID=$!
sleep 2
if ! kill -0 "$TEMP_PID" 2>/dev/null; then
  record "#25011" "temp_session_setup" "FAIL" "temporary-table session exited early; see $LOG_DIR/temp_session.log"
  log "temporary-table session exited early"
  column -t -s $'\t' "$SUMMARY" || cat "$SUMMARY"
  exit 1
fi

log "==> Trigger checkpoint after ${CHECKPOINT_DELAY}s"
sleep "$CHECKPOINT_DELAY"
if mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT mo_ctl('dn', 'checkpoint', '');" > "$LOG_DIR/trigger_checkpoint.log" 2>&1; then
  record "setup" "trigger_checkpoint" "OK" "$LOG_DIR/trigger_checkpoint.log"
else
  record "setup" "trigger_checkpoint" "FAIL" "$LOG_DIR/trigger_checkpoint.log"
  column -t -s $'\t' "$SUMMARY" || cat "$SUMMARY"
  exit 1
fi

log "==> Wait checkpoint metadata"
TEMP_DB_ID="NOT_FOUND"
EXT_DB_ID="NOT_FOUND"
DATABASES_TXT="$OUT/databases.txt"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while (( $(date +%s) <= deadline )); do
  "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$DATABASES_TXT" 2> "$LOG_DIR/ckp_list_databases.err" || true
  temp_id="$(awk -v db="$DB_TEMP" '$2 == db {print $3; exit}' "$DATABASES_TXT")"
  ext_id="$(awk -v db="$DB_EXT" '$2 == db {print $3; exit}' "$DATABASES_TXT")"
  [[ -n "$temp_id" ]] && TEMP_DB_ID="$temp_id"
  [[ -n "$ext_id" ]] && EXT_DB_ID="$ext_id"
  log "    metadata: $DB_TEMP=$TEMP_DB_ID $DB_EXT=$EXT_DB_ID"
  if [[ "$TEMP_DB_ID" != "NOT_FOUND" && "$EXT_DB_ID" != "NOT_FOUND" ]]; then
    break
  fi
  sleep "$POLL_SECONDS"
done

log "==> Verify #25010 external table checkpoint visibility and restore"
if [[ "$EXT_SETUP_STATUS" != "OK" ]]; then
  record "#25010" "external_setup" "FAIL" "CREATE EXTERNAL TABLE failed; see $LOG_DIR/external_setup.log"
elif [[ "$EXT_SOURCE_COUNT" != "3" ]]; then
  record "#25010" "external_source_count" "FAIL" "expected source count 3, got $EXT_SOURCE_COUNT"
elif [[ "$EXT_DB_ID" == "NOT_FOUND" ]]; then
  record "#25010" "external_db_in_ckp_list" "FAIL" "$DB_EXT not found in checkpoint database metadata"
else
  record "#25010" "external_db_in_ckp_list" "OK" "$DB_EXT database_id=$EXT_DB_ID"
  EXT_TABLES_TXT="$OUT/external_tables.txt"
  "$MO_TOOL" ckp list --type=tables --database-id="$EXT_DB_ID" "$CKP_DATA" > "$EXT_TABLES_TXT" 2> "$LOG_DIR/ckp_list_external_tables.err" || true
  EXT_TABLE_ID="$(awk '$3 == "ext_csv_local" {print $4; exit}' "$EXT_TABLES_TXT")"
  if [[ -z "$EXT_TABLE_ID" ]]; then
    record "#25010" "external_table_in_ckp_list" "FAIL" "ext_csv_local not found; see $EXT_TABLES_TXT"
  else
    record "#25010" "external_table_in_ckp_list" "OK" "table_id=$EXT_TABLE_ID"
    IFS=$'\t' read -r dump_rc dump_dir dump_log < <(dump_table "$DB_EXT" "ext_csv_local" "$EXT_TABLE_ID")
    if [[ "$dump_rc" != "0" ]]; then
      record "#25010" "external_dump" "FAIL" "dump rc=$dump_rc; log=$dump_log"
    elif [[ ! -f "$dump_dir/restore.sql" ]]; then
      record "#25010" "external_dump" "FAIL" "restore.sql not generated under $dump_dir"
    else
      record "#25010" "external_dump" "OK" "$dump_dir"
      restore_log="$LOG_DIR/${DB_EXT}_${EXT_TABLE_ID}_ext_csv_local.restore.log"
      if restore_sql "$DB_EXT" "$dump_dir/restore.sql" "$restore_log"; then
        target_count="$(mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SELECT COUNT(*) FROM \`$DB_EXT\`.ext_csv_local;" 2>/dev/null || printf 'QUERY_FAIL')"
        if [[ "$target_count" == "$EXT_SOURCE_COUNT" ]]; then
          record "#25010" "external_restore_count" "OK" "source=$EXT_SOURCE_COUNT target=$target_count"
        else
          record "#25010" "external_restore_count" "FAIL" "source=$EXT_SOURCE_COUNT target=$target_count; log=$restore_log"
        fi
      else
        record "#25010" "external_restore" "FAIL" "restore failed; log=$restore_log"
      fi
    fi
  fi
fi

log "==> Verify #25011 temp table uses user-visible name"
if [[ "$TEMP_DB_ID" == "NOT_FOUND" ]]; then
  record "#25011" "temp_db_in_ckp_list" "FAIL" "$DB_TEMP not found in checkpoint database metadata"
else
  record "#25011" "temp_db_in_ckp_list" "OK" "$DB_TEMP database_id=$TEMP_DB_ID"
  TEMP_TABLES_TXT="$OUT/temp_tables.txt"
  "$MO_TOOL" ckp list --type=tables --database-id="$TEMP_DB_ID" "$CKP_DATA" > "$TEMP_TABLES_TXT" 2> "$LOG_DIR/ckp_list_temp_tables.err" || true
  INTERNAL_TEMP_NAMES="$(awk '$3 ~ /^__mo_tmp_/ {print $3}' "$TEMP_TABLES_TXT" | paste -sd ',' -)"
  USER_TEMP_ID="$(awk '$3 == "t_session_only" {print $4; exit}' "$TEMP_TABLES_TXT")"

  if [[ -n "$INTERNAL_TEMP_NAMES" ]]; then
    record "#25011" "no_internal_temp_name" "FAIL" "found internal temp name(s): $INTERNAL_TEMP_NAMES"
  else
    record "#25011" "no_internal_temp_name" "OK" "no __mo_tmp table names in checkpoint list"
  fi

  if [[ -z "$USER_TEMP_ID" ]]; then
    record "#25011" "user_temp_name_in_ckp_list" "FAIL" "t_session_only not found; see $TEMP_TABLES_TXT"
  else
    record "#25011" "user_temp_name_in_ckp_list" "OK" "table_id=$USER_TEMP_ID"
    IFS=$'\t' read -r dump_rc dump_dir dump_log < <(dump_table "$DB_TEMP" "t_session_only" "$USER_TEMP_ID")
    if [[ "$dump_rc" != "0" ]]; then
      record "#25011" "temp_dump" "FAIL" "dump rc=$dump_rc; log=$dump_log"
    elif [[ ! -f "$dump_dir/restore.sql" ]]; then
      record "#25011" "temp_dump" "FAIL" "restore.sql not generated under $dump_dir"
    else
      if grep -q '__mo_tmp_' "$dump_dir/restore.sql"; then
        record "#25011" "restore_sql_name" "FAIL" "restore.sql still contains __mo_tmp_; file=$dump_dir/restore.sql"
      elif grep -q 't_session_only' "$dump_dir/restore.sql"; then
        record "#25011" "restore_sql_name" "OK" "restore.sql uses t_session_only"
      else
        record "#25011" "restore_sql_name" "FAIL" "restore.sql does not contain t_session_only; file=$dump_dir/restore.sql"
      fi

      restore_log="$LOG_DIR/${DB_TEMP}_${USER_TEMP_ID}_t_session_only.restore.log"
      if restore_sql "$DB_TEMP" "$dump_dir/restore.sql" "$restore_log"; then
        target_count="$(mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SELECT COUNT(*) FROM \`$DB_TEMP\`.t_session_only;" 2>/dev/null || printf 'QUERY_FAIL')"
        if [[ "$target_count" == "1" ]]; then
          record "#25011" "temp_restore_count" "OK" "target=$target_count"
        else
          record "#25011" "temp_restore_count" "FAIL" "target=$target_count; log=$restore_log"
        fi
      else
        record "#25011" "temp_restore" "FAIL" "restore failed; log=$restore_log"
      fi
    fi
  fi
fi

log "==> Summary"
if command -v column >/dev/null 2>&1; then
  column -t -s $'\t' "$SUMMARY"
else
  cat "$SUMMARY"
fi
log "Artifacts: $OUT"

if awk -F'\t' 'NR > 1 && $3 == "FAIL" {bad=1} END {exit bad ? 0 : 1}' "$SUMMARY"; then
  log "VERIFY_FAIL: #25010/#25011 still has failing checks"
  exit 1
fi

log "VERIFY_PASS: #25010 and #25011 checks passed"
