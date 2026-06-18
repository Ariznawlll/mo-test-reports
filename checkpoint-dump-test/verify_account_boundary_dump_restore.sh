#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify checkpoint dump account boundary behavior.

Purpose:
  ckp dump reads checkpoint data by account_id/database_id/table_id from
  mo-data/shared. It is not isolated by the SQL login tenant. This test verifies
  that IDs select the intended tenant data and that restore into another tenant
  creates ordinary database/table data without preserving source account
  identity or permissions.

Coverage:
  - two source tenants create the same database/table names with different data
  - ckp list exposes account_id/database_id/table_id metadata
  - dump by table-id from tenant A and restore into tenant C
  - dump by account-id + database-id from tenant B and restore into tenant C
  - compare schema, row counts, and full sorted data
  - verify tenant A/B data does not get mixed

Usage:
  ./verify_account_boundary_dump_restore.sh [options]

Options:
  --host HOST                 MatrixOne MySQL host, default: 127.0.0.1
  --port PORT                 MatrixOne MySQL port, default: 6001
  --sys-user USER             Sys/admin user, default: dump
  --sys-password PASS         Sys/admin password, default: 111
  --account-a NAME            Source tenant A account, default: ckpbounda
  --account-b NAME            Source tenant B account, default: ckpboundb
  --account-c NAME            Restore target tenant C account, default: ckpboundc
  --account-admin USER        Account admin user, default: test_account
  --account-password PASS     Account admin password, default: 111
  --db-prefix PREFIX          DB prefix, default: ckp_boundary_<timestamp>
  --mo-tool PATH              mo-tool path, default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH             Checkpoint data path
  --out DIR                   Output dir, default: /data4/weilu/verify_account_boundary_<timestamp>
  --mysql-bin PATH            mysql client path, default: mysql
  --wait-seconds N            Max wait for checkpoint metadata, default: 300
  --poll-seconds N            Poll interval, default: 5
  --drop-existing             Drop/recreate dedicated test accounts first
  --help                      Show this help
USAGE
}

TS="$(date +%Y%m%d_%H%M%S)"

HOST="127.0.0.1"
PORT="6001"
SYS_USER="dump"
SYS_PASSWORD="111"
ACCOUNT_A="ckpbounda"
ACCOUNT_B="ckpboundb"
ACCOUNT_C="ckpboundc"
ACCOUNT_ADMIN="test_account"
ACCOUNT_PASSWORD="111"
DB_PREFIX="ckp_boundary_${TS}"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_account_boundary_${TS}"
MYSQL_BIN="mysql"
WAIT_SECONDS="300"
POLL_SECONDS="5"
DROP_EXISTING="0"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --sys-user) SYS_USER="$2"; shift 2 ;;
    --sys-password) SYS_PASSWORD="$2"; shift 2 ;;
    --account-a) ACCOUNT_A="$2"; shift 2 ;;
    --account-b) ACCOUNT_B="$2"; shift 2 ;;
    --account-c) ACCOUNT_C="$2"; shift 2 ;;
    --account-admin) ACCOUNT_ADMIN="$2"; shift 2 ;;
    --account-password) ACCOUNT_PASSWORD="$2"; shift 2 ;;
    --db-prefix) DB_PREFIX="$2"; shift 2 ;;
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

USER_A="${ACCOUNT_A}:${ACCOUNT_ADMIN}"
USER_B="${ACCOUNT_B}:${ACCOUNT_ADMIN}"
USER_C="${ACCOUNT_C}:${ACCOUNT_ADMIN}"
DB_SAME="${DB_PREFIX}_same"
DB_MARK_A="${DB_PREFIX}_acct_a_marker"
DB_MARK_B="${DB_PREFIX}_acct_b_marker"
TABLE_NAME="t_boundary"

LOG_DIR="$OUT/logs"
DUMP_DIR="$OUT/dumps"
COMPARE_DIR="$OUT/compare"
mkdir -p "$LOG_DIR" "$DUMP_DIR" "$COMPARE_DIR"

METADATA_SUMMARY="$OUT/metadata_summary.tsv"
DUMP_SUMMARY="$OUT/dump_summary.tsv"
RESTORE_SUMMARY="$OUT/restore_summary.tsv"
COMPARE_SUMMARY="$OUT/compare_summary.tsv"

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
    -e "SELECT * FROM \`$db\`.\`$table\` ORDER BY id;" \
    > "$out_file"
}

create_accounts() {
  local admin_sql
  local pass_sql
  admin_sql="$(quote_sql_string "$ACCOUNT_ADMIN")"
  pass_sql="$(quote_sql_string "$ACCOUNT_PASSWORD")"

  if [[ "$DROP_EXISTING" == "1" ]]; then
    log "==> Drop dedicated boundary test accounts"
    mysql_query "$SYS_USER" "$SYS_PASSWORD" "DROP ACCOUNT IF EXISTS \`$ACCOUNT_C\`;" > "$LOG_DIR/drop_account_c.log" 2>&1 || true
    mysql_query "$SYS_USER" "$SYS_PASSWORD" "DROP ACCOUNT IF EXISTS \`$ACCOUNT_B\`;" > "$LOG_DIR/drop_account_b.log" 2>&1 || true
    mysql_query "$SYS_USER" "$SYS_PASSWORD" "DROP ACCOUNT IF EXISTS \`$ACCOUNT_A\`;" > "$LOG_DIR/drop_account_a.log" 2>&1 || true
  fi

  log "==> Ensure boundary test accounts"
  mysql_query "$SYS_USER" "$SYS_PASSWORD" \
    "CREATE ACCOUNT \`$ACCOUNT_A\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_account_a.log" 2>&1 || true
  mysql_query "$SYS_USER" "$SYS_PASSWORD" \
    "CREATE ACCOUNT \`$ACCOUNT_B\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_account_b.log" 2>&1 || true
  mysql_query "$SYS_USER" "$SYS_PASSWORD" \
    "CREATE ACCOUNT \`$ACCOUNT_C\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_account_c.log" 2>&1 || true
}

prepare_source_account() {
  local user="$1"
  local marker_db="$2"
  local tenant_tag="$3"
  local row_prefix="$4"
  local sql_file="$OUT/prepare_${tenant_tag}.sql"

  cat > "$sql_file" <<SQL
DROP DATABASE IF EXISTS \`$marker_db\`;
CREATE DATABASE \`$marker_db\`;
USE \`$marker_db\`;
CREATE TABLE marker (
  id INT NOT NULL PRIMARY KEY,
  account_tag VARCHAR(40) NOT NULL
);
INSERT INTO marker VALUES (1, '$tenant_tag');

DROP DATABASE IF EXISTS \`$DB_SAME\`;
CREATE DATABASE \`$DB_SAME\`;
USE \`$DB_SAME\`;
CREATE TABLE \`$TABLE_NAME\` (
  id INT NOT NULL PRIMARY KEY,
  tenant_tag VARCHAR(40) NOT NULL,
  payload VARCHAR(80) NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  created_at DATETIME NOT NULL
) COMMENT='same database/table name in different tenants';
INSERT INTO \`$TABLE_NAME\` VALUES
  (1, '$tenant_tag', '${row_prefix}-row-1', 10.10, '2024-01-01 00:00:00'),
  (2, '$tenant_tag', '${row_prefix}-row-2', 20.20, '2024-01-02 00:00:00'),
  (3, '$tenant_tag', '${row_prefix}-row-3', 30.30, '2024-01-03 00:00:00');
SQL

  log "==> Prepare source data for $tenant_tag"
  mysql_exec "$user" "$ACCOUNT_PASSWORD" < "$sql_file" > "$LOG_DIR/prepare_${tenant_tag}.log" 2>&1
}

prepare_sources() {
  prepare_source_account "$USER_A" "$DB_MARK_A" "tenant_a" "A"
  prepare_source_account "$USER_B" "$DB_MARK_B" "tenant_b" "B"
  log "==> Clean target account database"
  mysql_query "$USER_C" "$ACCOUNT_PASSWORD" "DROP DATABASE IF EXISTS \`$DB_SAME\`;" > "$LOG_DIR/clean_target.log" 2>&1 || true
}

trigger_checkpoint() {
  log "==> Trigger checkpoint"
  mysql_query "$SYS_USER" "$SYS_PASSWORD" "SELECT mo_ctl('dn', 'checkpoint', '');" \
    > "$LOG_DIR/trigger_checkpoint.log" 2>&1
}

write_metadata_summary() {
  local account_a_id
  local account_b_id
  local db_a_id
  local db_b_id
  local table_a_id
  local table_b_id

  account_a_id="$(awk -v db="$DB_MARK_A" '$2 == db {print $1; exit}' "$OUT/databases.txt" 2>/dev/null || true)"
  account_b_id="$(awk -v db="$DB_MARK_B" '$2 == db {print $1; exit}' "$OUT/databases.txt" 2>/dev/null || true)"
  db_a_id="$(awk -v acct="$account_a_id" -v db="$DB_SAME" '$1 == acct && $2 == db {print $3; exit}' "$OUT/databases.txt" 2>/dev/null || true)"
  db_b_id="$(awk -v acct="$account_b_id" -v db="$DB_SAME" '$1 == acct && $2 == db {print $3; exit}' "$OUT/databases.txt" 2>/dev/null || true)"

  table_a_id=""
  table_b_id=""
  if [[ -n "$db_a_id" ]]; then
    "$MO_TOOL" ckp list --type=tables --database-id="$db_a_id" "$CKP_DATA" \
      > "$OUT/${DB_SAME}_tenant_a_tables.txt" 2> "$LOG_DIR/${DB_SAME}_tenant_a_tables.err" || true
    table_a_id="$(awk -v table="$TABLE_NAME" '$3 == table {print $4; exit}' "$OUT/${DB_SAME}_tenant_a_tables.txt" 2>/dev/null || true)"
  fi
  if [[ -n "$db_b_id" ]]; then
    "$MO_TOOL" ckp list --type=tables --database-id="$db_b_id" "$CKP_DATA" \
      > "$OUT/${DB_SAME}_tenant_b_tables.txt" 2> "$LOG_DIR/${DB_SAME}_tenant_b_tables.err" || true
    table_b_id="$(awk -v table="$TABLE_NAME" '$3 == table {print $4; exit}' "$OUT/${DB_SAME}_tenant_b_tables.txt" 2>/dev/null || true)"
  fi

  printf 'tenant\taccount_name\taccount_id\tmarker_db\tsame_db\tdb_id\ttable\ttable_id\tstatus\n' > "$METADATA_SUMMARY"
  if [[ -n "$account_a_id" && -n "$db_a_id" && -n "$table_a_id" ]]; then
    printf 'A\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tFOUND\n' "$ACCOUNT_A" "$account_a_id" "$DB_MARK_A" "$DB_SAME" "$db_a_id" "$TABLE_NAME" "$table_a_id" >> "$METADATA_SUMMARY"
  else
    printf 'A\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tNOT_FOUND\n' "$ACCOUNT_A" "${account_a_id:--}" "$DB_MARK_A" "$DB_SAME" "${db_a_id:--}" "$TABLE_NAME" "${table_a_id:--}" >> "$METADATA_SUMMARY"
  fi
  if [[ -n "$account_b_id" && -n "$db_b_id" && -n "$table_b_id" ]]; then
    printf 'B\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tFOUND\n' "$ACCOUNT_B" "$account_b_id" "$DB_MARK_B" "$DB_SAME" "$db_b_id" "$TABLE_NAME" "$table_b_id" >> "$METADATA_SUMMARY"
  else
    printf 'B\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tNOT_FOUND\n' "$ACCOUNT_B" "${account_b_id:--}" "$DB_MARK_B" "$DB_SAME" "${db_b_id:--}" "$TABLE_NAME" "${table_b_id:--}" >> "$METADATA_SUMMARY"
  fi
}

wait_metadata() {
  local deadline=$(( $(date +%s) + WAIT_SECONDS ))

  log "==> Wait for boundary databases/tables in checkpoint metadata"
  while (( $(date +%s) <= deadline )); do
    "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$OUT/databases.txt" 2> "$LOG_DIR/ckp_list_databases.err" || true
    write_metadata_summary
    if awk -F'\t' 'NR > 1 && $9 != "FOUND" {bad=1} END {exit bad ? 1 : 0}' "$METADATA_SUMMARY"; then
      return 0
    fi
    log "    boundary metadata is not ready yet; retry after ${POLL_SECONDS}s"
    sleep "$POLL_SECONDS"
  done

  echo "boundary databases/tables not found in checkpoint within ${WAIT_SECONDS}s" >&2
  return 1
}

metadata_field() {
  local tenant="$1"
  local field="$2"
  local idx
  case "$field" in
    account_id) idx=3 ;;
    db_id) idx=6 ;;
    table_id) idx=8 ;;
    *) echo "unknown metadata field: $field" >&2; return 2 ;;
  esac
  awk -F'\t' -v tenant="$tenant" -v idx="$idx" '$1 == tenant {print $idx; exit}' "$METADATA_SUMMARY"
}

dump_cases() {
  local a_table_id
  local b_account_id
  local b_db_id
  local status

  a_table_id="$(metadata_field A table_id)"
  b_account_id="$(metadata_field B account_id)"
  b_db_id="$(metadata_field B db_id)"

  printf 'case\ttenant\tdump_mode\tdump_status\trestore_sql\n' > "$DUMP_SUMMARY"

  log "==> Dump tenant A by table-id=$a_table_id"
  mkdir -p "$DUMP_DIR/a_table_id"
  set +e
  "$MO_TOOL" ckp dump \
    --table-id="$a_table_id" \
    --header \
    --load-script \
    -o "$DUMP_DIR/a_table_id" \
    "$CKP_DATA" > "$LOG_DIR/a_table_id.dump.log" 2>&1
  status=$?
  set -e
  printf 'a_table_id\tA\ttable-id\t%s\t%s\n' "$status" "$DUMP_DIR/a_table_id/restore.sql" >> "$DUMP_SUMMARY"

  log "==> Dump tenant B by account-id=$b_account_id database-id=$b_db_id"
  mkdir -p "$DUMP_DIR/b_database_id"
  set +e
  "$MO_TOOL" ckp dump \
    --account-id="$b_account_id" \
    --database-id="$b_db_id" \
    --header \
    --load-script \
    --jobs=4 \
    -o "$DUMP_DIR/b_database_id" \
    "$CKP_DATA" > "$LOG_DIR/b_database_id.dump.log" 2>&1
  status=$?
  set -e
  printf 'b_database_id\tB\taccount-id+database-id\t%s\t%s\n' "$status" "$DUMP_DIR/b_database_id/restore.sql" >> "$DUMP_SUMMARY"
}

restore_case() {
  local case_name="$1"
  local tenant="$2"
  local restore="$3"
  local log_file="$LOG_DIR/${case_name}.restore.log"
  local status
  local rc

  mysql_query "$USER_C" "$ACCOUNT_PASSWORD" "DROP DATABASE IF EXISTS \`$DB_SAME\`;" \
    > "$LOG_DIR/${case_name}.drop_target.log" 2>&1 || true

  if [[ ! -f "$restore" ]]; then
    status="MISSING_RESTORE_SQL"
  else
    log "==> Restore $case_name into target tenant C"
    set +e
    MYSQL_PWD="$ACCOUNT_PASSWORD" "$MYSQL_BIN" \
      -h"$HOST" \
      -P"$PORT" \
      -u"$USER_C" \
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

  printf '%s\t%s\t%s\t%s\n' "$case_name" "$tenant" "$status" "$log_file" >> "$RESTORE_SUMMARY"
}

restore_cases() {
  printf 'case\ttenant\tload_status\tlog\n' > "$RESTORE_SUMMARY"
  restore_case "a_table_id" "A" "$DUMP_DIR/a_table_id/restore.sql"
  compare_case "a_table_id" "$USER_A" "tenant_a"
  restore_case "b_database_id" "B" "$DUMP_DIR/b_database_id/restore.sql"
  compare_case "b_database_id" "$USER_B" "tenant_b"
}

compare_case() {
  local case_name="$1"
  local source_user="$2"
  local expected_tag="$3"
  local source_count
  local target_count
  local count_status
  local schema_status
  local data_status
  local isolation_status
  local source_schema="$COMPARE_DIR/${case_name}.source.schema.sql"
  local target_schema="$COMPARE_DIR/${case_name}.target.schema.sql"
  local schema_diff="$COMPARE_DIR/${case_name}.schema.diff"
  local source_data="$COMPARE_DIR/${case_name}.source.data.tsv"
  local target_data="$COMPARE_DIR/${case_name}.target.data.tsv"
  local data_diff="$COMPARE_DIR/${case_name}.data.diff"
  local wrong_rows

  source_count="$(mysql_query "$source_user" "$ACCOUNT_PASSWORD" "SELECT COUNT(*) FROM \`$DB_SAME\`.\`$TABLE_NAME\`;" 2>/dev/null || printf 'QUERY_FAIL')"
  target_count="$(mysql_query "$USER_C" "$ACCOUNT_PASSWORD" "SELECT COUNT(*) FROM \`$DB_SAME\`.\`$TABLE_NAME\`;" 2>/dev/null || printf 'QUERY_FAIL')"
  if [[ "$source_count" == "$target_count" ]]; then
    count_status="OK"
  else
    count_status="DIFF"
  fi

  mysql_query "$source_user" "$ACCOUNT_PASSWORD" "SHOW CREATE TABLE \`$DB_SAME\`.\`$TABLE_NAME\`;" \
    | cut -f2- | normalize_schema "$DB_SAME" > "$source_schema" || true
  mysql_query "$USER_C" "$ACCOUNT_PASSWORD" "SHOW CREATE TABLE \`$DB_SAME\`.\`$TABLE_NAME\`;" \
    | cut -f2- | normalize_schema "$DB_SAME" > "$target_schema" || true
  if diff -u "$source_schema" "$target_schema" > "$schema_diff"; then
    schema_status="OK"
  else
    schema_status="DIFF"
  fi

  if dump_table_data "$source_user" "$ACCOUNT_PASSWORD" "$DB_SAME" "$TABLE_NAME" "$source_data" \
      && dump_table_data "$USER_C" "$ACCOUNT_PASSWORD" "$DB_SAME" "$TABLE_NAME" "$target_data" \
      && diff -u "$source_data" "$target_data" > "$data_diff"; then
    data_status="OK"
  else
    data_status="DIFF"
  fi

  wrong_rows="$(mysql_query "$USER_C" "$ACCOUNT_PASSWORD" "SELECT COUNT(*) FROM \`$DB_SAME\`.\`$TABLE_NAME\` WHERE tenant_tag <> '$expected_tag';" 2>/dev/null || printf 'QUERY_FAIL')"
  if [[ "$wrong_rows" == "0" ]]; then
    isolation_status="OK"
  else
    isolation_status="DIFF"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$case_name" "$source_count" "$target_count" "$count_status" "$schema_status" "$data_status" "$isolation_status" "$expected_tag" \
    >> "$COMPARE_SUMMARY"
}

init_compare_summary() {
  printf 'case\tsource_count\ttarget_count\tcount_status\tschema_status\tdata_status\tisolation_status\texpected_tag\n' > "$COMPARE_SUMMARY"
}

final_check() {
  local failed=0

  log "==> Account boundary metadata summary"
  column -t -s $'\t' "$METADATA_SUMMARY" || cat "$METADATA_SUMMARY"
  log "==> Account boundary dump summary"
  column -t -s $'\t' "$DUMP_SUMMARY" || cat "$DUMP_SUMMARY"
  log "==> Account boundary restore summary"
  column -t -s $'\t' "$RESTORE_SUMMARY" || cat "$RESTORE_SUMMARY"
  log "==> Account boundary compare summary"
  column -t -s $'\t' "$COMPARE_SUMMARY" || cat "$COMPARE_SUMMARY"
  log "Artifacts: $OUT"

  if awk -F'\t' 'NR > 1 && $9 != "FOUND" {bad=1} END {exit bad ? 0 : 1}' "$METADATA_SUMMARY"; then
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && $4 != "0" {bad=1} END {exit bad ? 0 : 1}' "$DUMP_SUMMARY"; then
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && $3 != "OK" {bad=1} END {exit bad ? 0 : 1}' "$RESTORE_SUMMARY"; then
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && ($4 != "OK" || $5 != "OK" || $6 != "OK" || $7 != "OK") {bad=1} END {exit bad ? 0 : 1}' "$COMPARE_SUMMARY"; then
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "ACCOUNT_BOUNDARY_DUMP_RESTORE_FAIL"
    return 1
  fi

  echo "ACCOUNT_BOUNDARY_DUMP_RESTORE_OK"
}

log "OUT=$OUT"
log "DB_PREFIX=$DB_PREFIX"
log "ACCOUNT_A=$USER_A"
log "ACCOUNT_B=$USER_B"
log "ACCOUNT_C=$USER_C"
log "MO_TOOL=$MO_TOOL"
log "CKP_DATA=$CKP_DATA"

create_accounts
prepare_sources
trigger_checkpoint
wait_metadata
dump_cases
init_compare_summary
restore_cases
final_check
