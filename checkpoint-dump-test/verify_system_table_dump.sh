#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify MatrixOne checkpoint dump for system databases/tables.

This script follows the current system-table validation scope:
  - dump system tables only
  - do not restore system tables
  - compare source COUNT(*) before dump with dumped CSV data row count
  - record source COUNT(*) after dump to detect source drift
  - compare source SHOW CREATE TABLE with mo-tool generated restore.sql DDL after normalization

Usage:
  ./verify_system_table_dump.sh [options]

Options:
  --host HOST             MatrixOne MySQL host. Default: 127.0.0.1
  --port PORT             MatrixOne MySQL port. Default: 6001
  --user USER             SQL user used to query source system tables. Default: dump
  --password PASS         SQL password. Default: 111
  --account-id ID         Checkpoint account id to inspect. Default: 0
  --system-dbs LIST       Space/comma separated system databases.
                          Default: mo_catalog mysql system system_metrics mo_task mo_debug information_schema
  --mo-tool PATH          mo-tool path. Default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH         Checkpoint data path
  --out DIR               Output dir. Default: /data4/weilu/verify_system_table_dump_<timestamp>
  --mysql-bin PATH        mysql client path. Default: mysql
  --jobs N                Reserved for future database-level dump tests. Default: 4
  --strict-schema         Treat schema diff as final failure. Default: enabled
  --no-strict-schema      Record schema diff but do not fail final status on schema diff
  --help                  Show this help
USAGE
}

TS="$(date +%Y%m%d_%H%M%S)"

HOST="127.0.0.1"
PORT="6001"
USER="dump"
PASSWORD="111"
ACCOUNT_ID="0"
SYSTEM_DBS="mo_catalog mysql system system_metrics mo_task mo_debug information_schema"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_system_table_dump_${TS}"
MYSQL_BIN="mysql"
JOBS="4"
STRICT_SCHEMA="1"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --account-id) ACCOUNT_ID="$2"; shift 2 ;;
    --system-dbs) SYSTEM_DBS="$2"; shift 2 ;;
    --mo-tool) MO_TOOL="$2"; shift 2 ;;
    --ckp-data) CKP_DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --jobs) JOBS="$2"; shift 2 ;;
    --strict-schema) STRICT_SCHEMA="1"; shift ;;
    --no-strict-schema) STRICT_SCHEMA="0"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for n in "$PORT" "$ACCOUNT_ID" "$JOBS"; do
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

SYSTEM_DBS="${SYSTEM_DBS//,/ }"

LOG_DIR="$OUT/logs"
DUMP_DIR="$OUT/dumps"
SCHEMA_DIR="$OUT/schema"
mkdir -p "$LOG_DIR" "$DUMP_DIR" "$SCHEMA_DIR"

DATABASE_SUMMARY="$OUT/system_database_summary.tsv"
MANIFEST="$OUT/system_table_manifest.tsv"
SUMMARY="$OUT/system_table_dump_summary.tsv"

log() {
  printf '%s\n' "$*"
}

safe_name() {
  printf '%s' "$1" | sed 's/[^A-Za-z0-9_.-]/_/g'
}

mysql_query() {
  local sql="$1"
  MYSQL_PWD="$PASSWORD" "$MYSQL_BIN" \
    -h"$HOST" \
    -P"$PORT" \
    -u"$USER" \
    --default-character-set=utf8mb4 \
    --batch \
    --raw \
    --skip-column-names \
    -e "$sql"
}

contains_nul() {
  local file="$1"
  perl -0777 -ne 'exit(index($_, "\0") >= 0 ? 0 : 1)' "$file"
}

normalize_schema() {
  local db="$1"
  NORM_DB="$db" perl -pe '
    BEGIN {
      $db = quotemeta($ENV{"NORM_DB"});
    }
    s/CREATE TABLE `$db`\.`/CREATE TABLE `/g;
    s/[ \t]+$//;
    if (/^;$/) {
      $_ = "";
      next;
    }
    s/[ \t]+/ /g;
    s/[ \t]*,[ \t]*/,/g;
    s/[ \t]*\([ \t]*/(/g;
    s/[ \t]*\)[ \t]*/)/g;
  '
}

extract_restore_ddl() {
  local restore="$1"
  local db="$2"
  local table="$3"
  awk -v db="$db" -v table="$table" '
    BEGIN { capture = 0 }
    $0 == "CREATE TABLE `" db "`.`" table "` (" { capture = 1 }
    capture { print }
    capture && $0 == ";" { exit }
  ' "$restore"
}

csv_line_count() {
  local csv="$1"
  wc -l < "$csv" | tr -d ' '
}

csv_record_count() {
  local csv="$1"
  python3 - "$csv" <<'PY'
import csv
import sys

path = sys.argv[1]
with open(path, newline="") as f:
    reader = csv.reader(f)
    count = sum(1 for _ in reader)
print(count)
PY
}

list_databases() {
  log "==> List checkpoint databases"
  "$MO_TOOL" ckp list --type=databases "$CKP_DATA" \
    | tee "$OUT/databases.txt"

  printf 'account_id\tdatabase\tdatabase_id\tstatus\n' > "$DATABASE_SUMMARY"
  : > "$MANIFEST"
  printf 'account_id\tdatabase\tdatabase_id\ttable\ttable_id\trel_kind\n' > "$MANIFEST"

  local db
  local db_id
  local tables_file
  local db_status
  for db in $SYSTEM_DBS; do
    db_id="$(awk -v aid="$ACCOUNT_ID" -v db="$db" '$1 == aid && $2 == db {print $3; exit}' "$OUT/databases.txt")"
    if [[ -z "$db_id" ]]; then
      printf '%s\t%s\t-\tNOT_FOUND\n' "$ACCOUNT_ID" "$db" >> "$DATABASE_SUMMARY"
      continue
    fi

    tables_file="$OUT/${db}_tables.txt"
    log "==> List checkpoint tables for account_id=$ACCOUNT_ID $db db_id=$db_id"
    if "$MO_TOOL" ckp list --type=tables --database-id="$db_id" "$CKP_DATA" \
        | tee "$tables_file"; then
      awk -v aid="$ACCOUNT_ID" -v db="$db" -v dbid="$db_id" '
        NR > 1 && $1 == aid && $2 == db && $5 == "r" {
          printf "%s\t%s\t%s\t%s\t%s\t%s\n", $1, $2, dbid, $3, $4, $5
        }
      ' "$tables_file" >> "$MANIFEST"
      db_status="FOUND"
    else
      db_status="LIST_TABLES_FAIL"
    fi
    printf '%s\t%s\t%s\t%s\n' "$ACCOUNT_ID" "$db" "$db_id" "$db_status" >> "$DATABASE_SUMMARY"
  done
}

dump_and_compare_tables() {
  printf 'database\tdatabase_id\ttable\ttable_id\tdump_status\tsource_count_before\tsource_count_after\tcsv_physical_lines\tcsv_records\tcsv_data_rows\tcount_status\tschema_status\tnul_status\tcsv_file\trestore_sql\tdump_log\tschema_diff\tnote\n' > "$SUMMARY"

  tail -n +2 "$MANIFEST" | while IFS=$'\t' read -r account_id db db_id table table_id rel_kind; do
    local tag
    local table_dir
    local dump_log
    local restore
    local csv_file
    local dump_status
    local source_count_before
    local source_count_after
    local csv_lines
    local csv_records
    local csv_data_rows
    local count_status
    local schema_status
    local nul_status
    local source_schema
    local restore_schema
    local schema_diff
    local note

    tag="$(safe_name "${db}_${table_id}_${table}")"
    table_dir="$DUMP_DIR/$tag"
    dump_log="$LOG_DIR/${tag}.dump.log"
    restore="$table_dir/restore.sql"
    source_schema="$SCHEMA_DIR/${tag}.source.sql"
    restore_schema="$SCHEMA_DIR/${tag}.restore.sql"
    schema_diff="$SCHEMA_DIR/${tag}.schema.diff"
    mkdir -p "$table_dir"

    source_count_before="$(mysql_query "SELECT COUNT(*) FROM \`$db\`.\`$table\`;" 2>/dev/null || printf 'SQL_COUNT_FAIL')"

    log "==> Dump system table $db.$table table_id=$table_id"
    set +e
    "$MO_TOOL" ckp dump \
      --table-id="$table_id" \
      --header \
      --load-script \
      -o "$table_dir" \
      "$CKP_DATA" > "$dump_log" 2>&1
    dump_status=$?
    set -e

    source_count_after="$(mysql_query "SELECT COUNT(*) FROM \`$db\`.\`$table\`;" 2>/dev/null || printf 'SQL_COUNT_FAIL')"

    csv_file="$(find "$table_dir" -type f -name "${table}_${table_id}.csv" -print -quit)"
    csv_lines="NA"
    csv_records="NA"
    csv_data_rows="NA"
    if [[ -n "$csv_file" ]]; then
      csv_lines="$(csv_line_count "$csv_file")"
      csv_records="$(csv_record_count "$csv_file" 2>/dev/null || printf 'CSV_PARSE_FAIL')"
      if [[ "$csv_records" =~ ^[0-9]+$ ]] && [[ "$csv_records" -gt 0 ]]; then
        csv_data_rows=$((csv_records - 1))
      fi
    fi

    count_status="NA"
    if [[ "$dump_status" -ne 0 ]]; then
      count_status="DUMP_FAIL"
    elif [[ -z "$csv_file" ]]; then
      count_status="CSV_MISSING"
    elif ! [[ "$source_count_before" =~ ^[0-9]+$ ]]; then
      count_status="$source_count_before"
    elif [[ "$csv_data_rows" == "$source_count_before" ]]; then
      count_status="OK"
    elif [[ "$source_count_after" =~ ^[0-9]+$ && "$source_count_after" != "$source_count_before" ]]; then
      count_status="SOURCE_DRIFT"
    else
      count_status="DIFF"
    fi

    nul_status="NA"
    if [[ -f "$restore" ]]; then
      if contains_nul "$restore"; then
        nul_status="NUL_FOUND"
      else
        nul_status="OK"
      fi
    else
      nul_status="MISSING_RESTORE_SQL"
    fi

    schema_status="NA"
    note=""
    : > "$source_schema"
    : > "$restore_schema"
    : > "$schema_diff"
    if [[ "$dump_status" -ne 0 ]]; then
      schema_status="DUMP_FAIL"
    elif [[ ! -f "$restore" ]]; then
      schema_status="MISSING_RESTORE_SQL"
    elif [[ "$nul_status" == "NUL_FOUND" ]]; then
      schema_status="NUL_FOUND"
    else
      if mysql_query "SHOW CREATE TABLE \`$db\`.\`$table\`;" 2>/dev/null \
          | cut -f2- \
          | normalize_schema "$db" > "$source_schema"; then
        extract_restore_ddl "$restore" "$db" "$table" \
          | normalize_schema "$db" > "$restore_schema"
        if [[ ! -s "$restore_schema" ]]; then
          schema_status="RESTORE_DDL_NOT_FOUND"
        elif diff -u "$source_schema" "$restore_schema" > "$schema_diff"; then
          schema_status="OK"
        else
          schema_status="DIFF"
        fi
      else
        schema_status="SQL_SCHEMA_FAIL"
      fi
    fi

    if [[ "$rel_kind" != "r" ]]; then
      note="non-table rel_kind=$rel_kind"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$db" "$db_id" "$table" "$table_id" "$dump_status" "$source_count_before" "$source_count_after" "$csv_lines" "$csv_records" "$csv_data_rows" \
      "$count_status" "$schema_status" "$nul_status" "${csv_file:-NA}" "${restore:-NA}" "$dump_log" "$schema_diff" "$note" \
      >> "$SUMMARY"
  done
}

print_summary() {
  log "==> System database summary"
  column -t -s $'\t' "$DATABASE_SUMMARY" || cat "$DATABASE_SUMMARY"

  log "==> System table dump summary"
  column -t -s $'\t' "$SUMMARY" || cat "$SUMMARY"

  log "Artifacts: $OUT"

  local fail_count
  if [[ "$STRICT_SCHEMA" == "1" ]]; then
    fail_count="$(awk -F'\t' 'NR > 1 && ($5 != "0" || $11 != "OK" || $12 != "OK" || $13 != "OK") {count++} END {print count+0}' "$SUMMARY")"
  else
    fail_count="$(awk -F'\t' 'NR > 1 && ($5 != "0" || $11 != "OK" || $13 != "OK") {count++} END {print count+0}' "$SUMMARY")"
  fi

  local table_count
  table_count="$(awk 'NR > 1 {count++} END {print count+0}' "$SUMMARY")"
  if [[ "$table_count" -eq 0 ]]; then
    log "SYSTEM_TABLE_DUMP_NEEDS_ANALYSIS: no system tables selected for account_id=$ACCOUNT_ID"
    exit 1
  fi
  if [[ "$fail_count" -eq 0 ]]; then
    log "SYSTEM_TABLE_DUMP_OK"
  else
    log "SYSTEM_TABLE_DUMP_NEEDS_ANALYSIS: $fail_count table checks failed"
    exit 1
  fi
}

log "OUT=$OUT"
log "ACCOUNT_ID=$ACCOUNT_ID"
log "SYSTEM_DBS=$SYSTEM_DBS"
log "MO_TOOL=$MO_TOOL"
log "CKP_DATA=$CKP_DATA"
list_databases
dump_and_compare_tables
print_summary
