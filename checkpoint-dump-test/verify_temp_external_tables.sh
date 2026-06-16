#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify checkpoint dump behavior for temporary tables and external tables.

This focused script creates only:
  <prefix>_temp       permanent marker + session temporary table
  <prefix>_external   local CSV external table

Then it checks checkpoint list/dump behavior and, when restore.sql is produced,
tries to load it into a normal tenant.

Usage:
  ./verify_temp_external_tables.sh [options]

Options:
  --host HOST                 MatrixOne MySQL host, default: 127.0.0.1
  --port PORT                 MatrixOne MySQL port, default: 6001
  --source-user USER          Source tenant user, default: dump
  --source-password PASS      Source tenant password, default: 111
  --target-user USER          Target tenant user, default: acc01:test_account
  --target-password PASS      Target tenant password, default: 111
  --db-prefix PREFIX          Database prefix, default: ckp
  --mo-tool PATH              mo-tool path, default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH             Checkpoint data path
  --out DIR                   Output dir, default: /data4/weilu/verify_temp_external_<timestamp>
  --mysql-bin PATH            mysql client path, default: mysql
  --hold-seconds N            Keep temporary-table session open for N seconds, default: 180
  --wait-seconds N            Max wait for checkpoint metadata, default: 600
  --poll-seconds N            Poll interval, default: 10
  --checkpoint-sql SQL        SQL used to trigger checkpoint, default: SELECT mo_ctl('dn', 'checkpoint', '');
  --no-auto-checkpoint        Do not trigger checkpoint automatically; print manual prompt instead
  --checkpoint-delay N        Seconds to wait before triggering checkpoint, default: 5
  --wait-for-both-dbs         Wait until both temp and external DBs appear. Default: continue once temp DB appears
  --drop-existing             Drop <prefix>_temp and <prefix>_external before setup
  --keep-target-db            Do not drop target DBs before restore attempts
  --help                      Show this help

If --checkpoint-command is not provided, trigger checkpoint manually in another
terminal while this script is holding the temporary-table session open.
USAGE
}

TS="$(date +%Y%m%d_%H%M%S)"
HOST="127.0.0.1"
PORT="6001"
SOURCE_USER="dump"
SOURCE_PASSWORD="111"
TARGET_USER="acc01:test_account"
TARGET_PASSWORD="111"
DB_PREFIX="ckp"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_temp_external_${TS}"
MYSQL_BIN="mysql"
HOLD_SECONDS="180"
WAIT_SECONDS="600"
POLL_SECONDS="10"
CHECKPOINT_SQL="SELECT mo_ctl('dn', 'checkpoint', '');"
AUTO_CHECKPOINT="1"
CHECKPOINT_DELAY="5"
WAIT_FOR_BOTH_DBS="0"
DROP_EXISTING="0"
KEEP_TARGET_DB="0"

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
    --checkpoint-sql) CHECKPOINT_SQL="$2"; shift 2 ;;
    --no-auto-checkpoint) AUTO_CHECKPOINT="0"; shift ;;
    --checkpoint-delay) CHECKPOINT_DELAY="$2"; shift 2 ;;
    --wait-for-both-dbs) WAIT_FOR_BOTH_DBS="1"; shift ;;
    --drop-existing) DROP_EXISTING="1"; shift ;;
    --keep-target-db) KEEP_TARGET_DB="1"; shift ;;
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
  echo "checkpoint path not found: $CKP_DATA" >&2
  exit 2
fi

DB_TEMP="${DB_PREFIX}_temp"
DB_EXT="${DB_PREFIX}_external"
LOG_DIR="$OUT/logs"
FIXTURE_DIR="$OUT/external_fixtures"
SUMMARY="$OUT/summary.tsv"

mkdir -p "$LOG_DIR" "$FIXTURE_DIR"

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

wait_db_in_checkpoint() {
  local db="$1"
  local out_file="$2"
  local db_id=""
  local deadline=$(( $(date +%s) + WAIT_SECONDS ))

  while (( $(date +%s) <= deadline )); do
    "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$out_file"
    db_id="$(awk -v db="$db" '$2 == db {print $3; exit}' "$out_file")"
    if [[ -n "$db_id" ]]; then
      printf '%s' "$db_id"
      return 0
    fi
    sleep "$POLL_SECONDS"
  done
  return 1
}

dump_one_table() {
  local db="$1"
  local db_id="$2"
  local table="$3"
  local table_id="$4"
  local tag
  local dir
  local log_file
  local rc=0

  tag="$(safe_name "${db}_${table_id}_${table}")"
  dir="$OUT/$tag"
  log_file="$LOG_DIR/${tag}.dump.log"
  mkdir -p "$dir"

  log "==> Dump $db.$table table_id=$table_id"
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

restore_if_possible() {
  local db="$1"
  local dir="$2"
  local tag="$3"
  local restore="$dir/restore.sql"
  local log_file="$LOG_DIR/${tag}.restore.log"

  if [[ ! -f "$restore" ]]; then
    printf 'NO_RESTORE_SQL'
    return 0
  fi

  if [[ "$KEEP_TARGET_DB" != "1" ]]; then
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "DROP DATABASE IF EXISTS \`$db\`;" > /dev/null
  fi

  if MYSQL_PWD="$TARGET_PASSWORD" "$MYSQL_BIN" \
      -h"$HOST" \
      -P"$PORT" \
      -u"$TARGET_USER" \
      --default-character-set=utf8mb4 \
      < "$restore" > "$log_file" 2>&1; then
    printf 'OK'
  else
    printf 'FAIL'
  fi
}

CSV_FILE="$FIXTURE_DIR/local_ext_people.csv"
printf '%s\n' \
  '1,alice,10.50,plain' \
  '2,bob,20.00,"comma,value"' \
  '3,charlie,0.00,"quote ""inside"""' \
  > "$CSV_FILE"
CSV_FILE_SQL="$(printf '%s' "$CSV_FILE" | sed "s/'/''/g")"

log "OUT=$OUT"
log "DB_TEMP=$DB_TEMP"
log "DB_EXT=$DB_EXT"
log "External CSV fixture=$CSV_FILE"

if [[ "$DROP_EXISTING" == "1" ]]; then
  log "==> Drop existing source databases"
  mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "DROP DATABASE IF EXISTS \`$DB_TEMP\`; DROP DATABASE IF EXISTS \`$DB_EXT\`;" > /dev/null
fi

TEMP_SQL="$OUT/create_temp_hold.sql"
cat > "$TEMP_SQL" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_TEMP\`;
USE \`$DB_TEMP\`;

DROP TABLE IF EXISTS temp_case_marker;
CREATE TABLE temp_case_marker (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(120)
);
REPLACE INTO temp_case_marker VALUES
  (1, 'permanent marker for temporary-table checkpoint test');

CREATE TEMPORARY TABLE t_session_only (
  id INT NOT NULL PRIMARY KEY,
  note VARCHAR(30)
);
INSERT INTO t_session_only VALUES (1, 'temporary row');

SELECT 'temp_session_rows' AS item, COUNT(*) AS rows FROM t_session_only;
SELECT 'hold_seconds' AS item, $HOLD_SECONDS AS rows;
SELECT SLEEP($HOLD_SECONDS) AS temp_hold_completed;
SQL

EXT_SQL="$OUT/create_external.sql"
cat > "$EXT_SQL" <<SQL
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

SELECT 'ext_csv_local_rows' AS item, COUNT(*) AS rows FROM ext_csv_local;
SQL

log "==> Create external table"
EXT_SETUP_STATUS="OK"
if ! mysql_exec "$SOURCE_USER" "$SOURCE_PASSWORD" < "$EXT_SQL" > "$LOG_DIR/external_setup.log" 2>&1; then
  EXT_SETUP_STATUS="FAIL"
fi

log "==> Start temporary-table session for ${HOLD_SECONDS}s"
mysql_exec "$SOURCE_USER" "$SOURCE_PASSWORD" < "$TEMP_SQL" > "$LOG_DIR/temp_session.log" 2>&1 &
TEMP_PID=$!
sleep 2

if ! kill -0 "$TEMP_PID" 2>/dev/null; then
  echo "temporary-table session exited too early; see $LOG_DIR/temp_session.log" >&2
  exit 1
fi

if [[ "$AUTO_CHECKPOINT" == "1" ]]; then
  log "==> Trigger checkpoint after ${CHECKPOINT_DELAY}s"
  sleep "$CHECKPOINT_DELAY"
  if ! mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "$CHECKPOINT_SQL" > "$LOG_DIR/checkpoint_command.log" 2>&1; then
    echo "checkpoint SQL failed; see $LOG_DIR/checkpoint_command.log" >&2
    kill "$TEMP_PID" 2>/dev/null || true
    wait "$TEMP_PID" 2>/dev/null || true
    exit 1
  fi
else
  log "==> Trigger checkpoint manually now, while temp session is sleeping."
  log "    Recommended SQL: $CHECKPOINT_SQL"
  log "    Temp session log: $LOG_DIR/temp_session.log"
  log "    Hold window: ${HOLD_SECONDS}s"
fi

log "==> Wait for temp/external databases in checkpoint metadata"
TEMP_DB_ID="NOT_FOUND"
EXT_DB_ID="NOT_FOUND"

DATABASES_WAIT_TXT="$OUT/databases_wait.txt"
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while (( $(date +%s) <= deadline )); do
  "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$DATABASES_WAIT_TXT"

  temp_id="$(awk -v db="$DB_TEMP" '$2 == db {print $3; exit}' "$DATABASES_WAIT_TXT")"
  ext_id="$(awk -v db="$DB_EXT" '$2 == db {print $3; exit}' "$DATABASES_WAIT_TXT")"

  if [[ -n "$temp_id" ]]; then
    TEMP_DB_ID="$temp_id"
  fi
  if [[ -n "$ext_id" ]]; then
    EXT_DB_ID="$ext_id"
  fi

  log "    checkpoint metadata: $DB_TEMP=$TEMP_DB_ID $DB_EXT=$EXT_DB_ID"

  if [[ "$WAIT_FOR_BOTH_DBS" == "1" ]]; then
    if [[ "$TEMP_DB_ID" != "NOT_FOUND" && "$EXT_DB_ID" != "NOT_FOUND" ]]; then
      break
    fi
  elif [[ "$TEMP_DB_ID" != "NOT_FOUND" ]]; then
    break
  fi

  sleep "$POLL_SECONDS"
done

cp "$DATABASES_WAIT_TXT" "$OUT/databases_final.txt"

if kill -0 "$TEMP_PID" 2>/dev/null; then
  wait "$TEMP_PID" || true
fi

printf 'case\tdatabase\tdatabase_id\ttable\ttable_id\tckp_list_status\tdump_status\tcsv_lines\trestore_status\ttarget_count\tnote\n' > "$SUMMARY"

log "==> Evaluate temporary-table checkpoint visibility"
if [[ "$TEMP_DB_ID" == "NOT_FOUND" ]]; then
  printf 'temp\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DB_TEMP" "$TEMP_DB_ID" "-" "-" "DB_NOT_IN_CHECKPOINT" "SKIP" "NA" "SKIP" "NA" \
    "No temp database checkpoint entry found within wait window" >> "$SUMMARY"
else
  TEMP_TABLES_TXT="$OUT/temp_tables.txt"
  "$MO_TOOL" ckp list --type=tables --database-id="$TEMP_DB_ID" "$CKP_DATA" | tee "$TEMP_TABLES_TXT"

  temp_candidates="$(awk '$3 ~ /^__mo_tmp_/ || $3 == "t_session_only" {print $3 "\t" $4}' "$TEMP_TABLES_TXT" || true)"
  marker_id="$(awk '$3 == "temp_case_marker" {print $4; exit}' "$TEMP_TABLES_TXT")"

  if [[ -n "$marker_id" ]]; then
    read -r dump_rc dump_dir dump_log < <(dump_one_table "$DB_TEMP" "$TEMP_DB_ID" "temp_case_marker" "$marker_id")
    csv_lines="NA"
    csv_file="$(find "$dump_dir" -type f -name '*.csv' | head -1 || true)"
    if [[ -n "$csv_file" ]]; then
      csv_lines="$(wc -l < "$csv_file" | tr -d '[:space:]')"
    fi
    restore_status="$(restore_if_possible "$DB_TEMP" "$dump_dir" "${DB_TEMP}_${marker_id}_temp_case_marker")"
    target_count="NA"
    if [[ "$restore_status" == "OK" ]]; then
      target_count="$(mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SELECT COUNT(*) FROM \`$DB_TEMP\`.temp_case_marker;" 2>/dev/null || printf 'QUERY_FAIL')"
    fi
    printf 'temp_marker\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$DB_TEMP" "$TEMP_DB_ID" "temp_case_marker" "$marker_id" "FOUND" "$dump_rc" "$csv_lines" "$restore_status" "$target_count" \
      "Permanent marker confirms checkpoint DB visibility" >> "$SUMMARY"
  fi

  if [[ -z "$temp_candidates" ]]; then
    printf 'temp_session\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$DB_TEMP" "$TEMP_DB_ID" "-" "-" "TEMP_TABLE_NOT_IN_CHECKPOINT" "SKIP" "NA" "SKIP" "NA" \
      "No session temporary table found in checkpoint table list" >> "$SUMMARY"
  else
    while IFS=$'\t' read -r temp_table temp_table_id; do
      [[ -z "$temp_table" ]] && continue
      read -r dump_rc dump_dir dump_log < <(dump_one_table "$DB_TEMP" "$TEMP_DB_ID" "$temp_table" "$temp_table_id")
      csv_lines="NA"
      csv_file="$(find "$dump_dir" -type f -name '*.csv' | head -1 || true)"
      if [[ -n "$csv_file" ]]; then
        csv_lines="$(wc -l < "$csv_file" | tr -d '[:space:]')"
      fi
      restore_status="$(restore_if_possible "$DB_TEMP" "$dump_dir" "${DB_TEMP}_${temp_table_id}_${temp_table}")"
      target_count="NA"
      printf 'temp_session\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$DB_TEMP" "$TEMP_DB_ID" "$temp_table" "$temp_table_id" "FOUND" "$dump_rc" "$csv_lines" "$restore_status" "$target_count" \
        "Temporary table appeared in checkpoint; inspect dump/restore behavior" >> "$SUMMARY"
    done <<< "$temp_candidates"
  fi
fi

log "==> Evaluate external table checkpoint/dump behavior"
if [[ "$EXT_SETUP_STATUS" != "OK" ]]; then
  printf 'external\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DB_EXT" "$EXT_DB_ID" "ext_csv_local" "-" "SETUP_FAIL" "SKIP" "NA" "SKIP" "NA" \
    "CREATE EXTERNAL TABLE failed; see external_setup.log" >> "$SUMMARY"
elif [[ "$EXT_DB_ID" == "NOT_FOUND" ]]; then
  printf 'external\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DB_EXT" "$EXT_DB_ID" "ext_csv_local" "-" "DB_NOT_IN_CHECKPOINT" "SKIP" "NA" "SKIP" "NA" \
    "External database not found in checkpoint within wait window" >> "$SUMMARY"
else
  EXT_TABLES_TXT="$OUT/external_tables.txt"
  "$MO_TOOL" ckp list --type=tables --database-id="$EXT_DB_ID" "$CKP_DATA" | tee "$EXT_TABLES_TXT"
  ext_table_id="$(awk '$3 == "ext_csv_local" {print $4; exit}' "$EXT_TABLES_TXT")"

  if [[ -z "$ext_table_id" ]]; then
    printf 'external\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$DB_EXT" "$EXT_DB_ID" "ext_csv_local" "-" "TABLE_NOT_IN_CHECKPOINT" "SKIP" "NA" "SKIP" "NA" \
      "External table database exists but ext_csv_local is not listed" >> "$SUMMARY"
  else
    source_count="$(mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT COUNT(*) FROM \`$DB_EXT\`.ext_csv_local;" 2>/dev/null || printf 'QUERY_FAIL')"
    read -r dump_rc dump_dir dump_log < <(dump_one_table "$DB_EXT" "$EXT_DB_ID" "ext_csv_local" "$ext_table_id")
    csv_lines="NA"
    csv_file="$(find "$dump_dir" -type f -name '*.csv' | head -1 || true)"
    if [[ -n "$csv_file" ]]; then
      csv_lines="$(wc -l < "$csv_file" | tr -d '[:space:]')"
    fi
    restore_status="$(restore_if_possible "$DB_EXT" "$dump_dir" "${DB_EXT}_${ext_table_id}_ext_csv_local")"
    target_count="NA"
    if [[ "$restore_status" == "OK" ]]; then
      target_count="$(mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SELECT COUNT(*) FROM \`$DB_EXT\`.ext_csv_local;" 2>/dev/null || printf 'QUERY_FAIL')"
    fi
    printf 'external\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$DB_EXT" "$EXT_DB_ID" "ext_csv_local" "$ext_table_id" "FOUND" "$dump_rc" "$csv_lines" "$restore_status" "$target_count" \
      "source_count=$source_count; dump_log=$dump_log" >> "$SUMMARY"
  fi
fi

log "==> Summary"
column -t -s $'\t' "$SUMMARY" || cat "$SUMMARY"
log "Artifacts: $OUT"

log "==> Quick conclusion hints"
log "- temp_session TEMP_TABLE_NOT_IN_CHECKPOINT means checkpoint did not persist/list the session temporary table."
log "- external FOUND with dump_status=0 and restore_status=OK means external table dump/restore path is executable."
log "- Any SETUP_FAIL, DB_NOT_IN_CHECKPOINT, TABLE_NOT_IN_CHECKPOINT, nonzero dump_status, or restore_status=FAIL needs issue analysis."

overall_rc=0

if awk -F'\t' '
  NR > 1 && $1 == "external" {
    if ($6 != "FOUND" || $7 != "0" || $9 != "OK") bad = 1
  }
  END { exit bad ? 0 : 1 }
' "$SUMMARY"; then
  overall_rc=1
fi

if awk -F'\t' '
  NR > 1 && $1 == "temp_marker" {
    seen = 1
    if ($6 != "FOUND" || $7 != "0" || $9 != "OK") bad = 1
  }
  END { exit (!seen || bad) ? 0 : 1 }
' "$SUMMARY"; then
  overall_rc=1
fi

if awk -F'\t' '
  NR > 1 && $1 == "temp_session" && $6 == "FOUND" {
    if ($7 != "0" || $9 != "OK") bad = 1
  }
  END { exit bad ? 0 : 1 }
' "$SUMMARY"; then
  overall_rc=1
fi

if [[ "$overall_rc" -eq 0 ]]; then
  log "PASS: temp/external verification completed without detected dump/restore failures"
else
  log "NEEDS_ANALYSIS: temp/external verification found a failure or unsupported path"
fi

exit "$overall_rc"
