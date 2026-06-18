#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify checkpoint dump behavior for views.

Flow:
  1. Prepare base coverage tables in the source tenant.
  2. Create a dedicated <prefix>_views database with views over different table shapes.
  3. Trigger checkpoint and discover view table IDs from checkpoint metadata.
  4. Dump each view with --load-script.
  5. Prepare the same base tables in the target tenant, then load dumped view restore.sql files.
  6. Compare source vs target SHOW CREATE TABLE, row counts, and full query output.

Usage:
  ./verify_views.sh [options]

Options:
  --host HOST                 MatrixOne MySQL host, default: 127.0.0.1
  --port PORT                 MatrixOne MySQL port, default: 6001
  --source-user USER          Source tenant user, default: dump
  --source-password PASS      Source tenant password, default: 111
  --target-user USER          Target tenant user, default: acc01:test_account
  --target-password PASS      Target tenant password, default: 111
  --db-prefix PREFIX          Base database prefix, default: ckp
  --view-db DB                View database name, default: <prefix>_views
  --scale N                   Rows for generated scale tables, default: 10000
  --mo-tool PATH              mo-tool path, default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH             Checkpoint data path
  --out DIR                   Output dir, default: /data4/verify_ckp_views_<timestamp>
  --mysql-bin PATH            mysql client path, default: mysql
  --prepare-script PATH       Coverage prepare script path
  --wait-seconds N            Max wait for checkpoint metadata, default: 600
  --poll-seconds N            Poll interval, default: 10
  --drop-existing             Drop source base/view databases before preparing
  --drop-target-account       Drop and recreate target account before restore
  --skip-prepare              Do not prepare source base data
  --help                      Show this help
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
VIEW_DB=""
SCALE="10000"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/verify_ckp_views_${TS}"
MYSQL_BIN="mysql"
PREPARE_SCRIPT="$SCRIPT_DIR/prepare_ckp_dump_coverage_data.sh"
WAIT_SECONDS="600"
POLL_SECONDS="10"
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
    --view-db) VIEW_DB="$2"; shift 2 ;;
    --scale) SCALE="$2"; shift 2 ;;
    --mo-tool) MO_TOOL="$2"; shift 2 ;;
    --ckp-data) CKP_DATA="$2"; shift 2 ;;
    --out) OUT="$2"; shift 2 ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --prepare-script) PREPARE_SCRIPT="$2"; shift 2 ;;
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --drop-existing) DROP_EXISTING="1"; shift ;;
    --drop-target-account) DROP_TARGET_ACCOUNT="1"; shift ;;
    --skip-prepare) SKIP_PREPARE="1"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

for n in "$PORT" "$SCALE" "$WAIT_SECONDS" "$POLL_SECONDS"; do
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

if [[ -z "$VIEW_DB" ]]; then
  VIEW_DB="${DB_PREFIX}_views"
fi

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

DB_TYPES="${DB_PREFIX}_types"
DB_CONS="${DB_PREFIX}_constraints"
DB_TABLES="${DB_PREFIX}_tables"
DB_MVCC="${DB_PREFIX}_mvcc_perf"
DB_EXT="${DB_PREFIX}_external"

LOG_DIR="$OUT/logs"
DUMP_DIR="$OUT/dumps"
COMPARE_DIR="$OUT/compare"
EXT_FIXTURE_DIR="$OUT/external_fixtures"
EXT_CSV_FILE="$EXT_FIXTURE_DIR/local_ext_people.csv"
mkdir -p "$LOG_DIR" "$DUMP_DIR" "$COMPARE_DIR" "$EXT_FIXTURE_DIR"

SUMMARY="$OUT/view_summary.tsv"
VIEWS_TSV="$OUT/views.tsv"

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

table_exists() {
  local user="$1"
  local password="$2"
  local db="$3"
  local table="$4"
  local exists
  exists="$(mysql_query "$user" "$password" \
    "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='$(quote_sql_string "$db")' AND table_name='$(quote_sql_string "$table")';" \
    2>/dev/null || printf '0')"
  [[ "$exists" == "1" ]]
}

create_external_fixture() {
  local user="$1"
  local password="$2"
  local label="$3"
  local sql_file="$OUT/${label}_external_fixture.sql"
  local csv_sql

  printf '%s\n' \
    '1,alice,10.50,plain' \
    '2,bob,20.00,"comma,value"' \
    '3,charlie,0.00,"quote ""inside"""' \
    > "$EXT_CSV_FILE"

  csv_sql="$(quote_sql_string "$EXT_CSV_FILE")"
  cat > "$sql_file" <<SQL
CREATE DATABASE IF NOT EXISTS \`$DB_EXT\`;
USE \`$DB_EXT\`;

DROP TABLE IF EXISTS ext_csv_local;
CREATE EXTERNAL TABLE ext_csv_local (
  id INT,
  name VARCHAR(50),
  score DECIMAL(10,2),
  note VARCHAR(100)
) INFILE {
  'filepath'='$csv_sql',
  'format'='csv'
};

SELECT 'ext_csv_local rows' AS item, COUNT(*) AS rows FROM ext_csv_local;
SQL

  log "==> Create external table fixture for $label"
  mysql_exec "$user" "$password" < "$sql_file" > "$LOG_DIR/${label}_external_fixture.log" 2>&1
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
    mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "DROP ACCOUNT IF EXISTS \`$account\`;" \
      > "$LOG_DIR/drop_target_account.log" 2>&1 || true
  fi

  log "==> Ensure target account $TARGET_USER"
  mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" \
    "CREATE ACCOUNT \`$account\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_target_account.log" 2>&1 || true
}

prepare_base_data() {
  local user="$1"
  local password="$2"
  local label="$3"
  local args=(
    --host "$HOST"
    --port "$PORT"
    --user "$user"
    --password "$password"
    --db-prefix "$DB_PREFIX"
    --scale "$SCALE"
    --out-dir "$OUT/${label}_prepare_sql"
    --drop-existing
  )

  log "==> Prepare base coverage data for $label"
  "$PREPARE_SCRIPT" "${args[@]}" > "$LOG_DIR/${label}_prepare.log" 2>&1
}

add_view() {
  local name="$1"
  local sql="$2"
  printf '%s\t%s\n' "$name" "$sql" >> "$VIEWS_TSV"
}

build_view_sql() {
  : > "$VIEWS_TSV"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "t_normal" &&
    add_view "v_normal" "CREATE VIEW \`$VIEW_DB\`.\`v_normal\` AS SELECT id, name FROM \`$DB_TABLES\`.\`t_normal\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "t_empty" &&
    add_view "v_empty" "CREATE VIEW \`$VIEW_DB\`.\`v_empty\` AS SELECT * FROM \`$DB_TABLES\`.\`t_empty\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "t_ctas" &&
    add_view "v_ctas" "CREATE VIEW \`$VIEW_DB\`.\`v_ctas\` AS SELECT * FROM \`$DB_TABLES\`.\`t_ctas\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "t_like" &&
    add_view "v_like" "CREATE VIEW \`$VIEW_DB\`.\`v_like\` AS SELECT id, name FROM \`$DB_TABLES\`.\`t_like\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "t_hash_partition" &&
    add_view "v_hash_partition" "CREATE VIEW \`$VIEW_DB\`.\`v_hash_partition\` AS SELECT * FROM \`$DB_TABLES\`.\`t_hash_partition\` WHERE id < 10"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "t_key_partition" &&
    add_view "v_key_partition" "CREATE VIEW \`$VIEW_DB\`.\`v_key_partition\` AS SELECT * FROM \`$DB_TABLES\`.\`t_key_partition\` WHERE tenant_id = 1"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "t_cluster_by" &&
    add_view "v_cluster_by" "CREATE VIEW \`$VIEW_DB\`.\`v_cluster_by\` AS SELECT id, k, payload FROM \`$DB_TABLES\`.\`t_cluster_by\` WHERE k < 5"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "select" &&
    add_view "v_reserved_name" "CREATE VIEW \`$VIEW_DB\`.\`v_reserved_name\` AS SELECT \`from\`, \`space col\`, \`dash-col\` FROM \`$DB_TABLES\`.\`select\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "v_normal" &&
    add_view "v_source_view" "CREATE VIEW \`$VIEW_DB\`.\`v_source_view\` AS SELECT * FROM \`$DB_TABLES\`.\`v_normal\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TABLES" "t_normal" &&
    add_view "v_chain_base" "CREATE VIEW \`$VIEW_DB\`.\`v_chain_base\` AS SELECT id, name FROM \`$DB_TABLES\`.\`t_normal\` WHERE id <= 2" &&
    add_view "v_chain_child" "CREATE VIEW \`$VIEW_DB\`.\`v_chain_child\` AS SELECT * FROM \`$VIEW_DB\`.\`v_chain_base\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_EXT" "ext_csv_local" &&
    add_view "v_external" "CREATE VIEW \`$VIEW_DB\`.\`v_external\` AS SELECT id, name, score, note FROM \`$DB_EXT\`.\`ext_csv_local\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "parent" &&
    add_view "v_parent" "CREATE VIEW \`$VIEW_DB\`.\`v_parent\` AS SELECT id, code, note FROM \`$DB_CONS\`.\`parent\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "t_composite_keys" &&
    add_view "v_composite_keys" "CREATE VIEW \`$VIEW_DB\`.\`v_composite_keys\` AS SELECT c1, c2, c3, c4 FROM \`$DB_CONS\`.\`t_composite_keys\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "t_auto_inc" &&
    add_view "v_auto_inc" "CREATE VIEW \`$VIEW_DB\`.\`v_auto_inc\` AS SELECT id, k, v FROM \`$DB_CONS\`.\`t_auto_inc\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "t_sequence_nextval" &&
    add_view "v_sequence_nextval" "CREATE VIEW \`$VIEW_DB\`.\`v_sequence_nextval\` AS SELECT id, note FROM \`$DB_CONS\`.\`t_sequence_nextval\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "t_sequence_default" &&
    add_view "v_sequence_default" "CREATE VIEW \`$VIEW_DB\`.\`v_sequence_default\` AS SELECT id, note FROM \`$DB_CONS\`.\`t_sequence_default\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "child_restrict" &&
    table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "parent" &&
    add_view "v_fk_join" "CREATE VIEW \`$VIEW_DB\`.\`v_fk_join\` AS SELECT c.id AS child_id, p.code, c.payload FROM \`$DB_CONS\`.\`child_restrict\` c JOIN \`$DB_CONS\`.\`parent\` p ON c.parent_id = p.id"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "t_fulltext" &&
    add_view "v_fulltext_index" "CREATE VIEW \`$VIEW_DB\`.\`v_fulltext_index\` AS SELECT id, doc FROM \`$DB_CONS\`.\`t_fulltext\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_CONS" "t_vector_index" &&
    add_view "v_vector_index" "CREATE VIEW \`$VIEW_DB\`.\`v_vector_index\` AS SELECT id, embedding FROM \`$DB_CONS\`.\`t_vector_index\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TYPES" "t_all_wide" &&
    add_view "v_types_wide" "CREATE VIEW \`$VIEW_DB\`.\`v_types_wide\` AS SELECT id, c_int, c_decimal, c_bool, c_varchar, c_json, HEX(c_blob) AS c_blob_hex FROM \`$DB_TYPES\`.\`t_all_wide\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TYPES" "t_strings" &&
    add_view "v_strings" "CREATE VIEW \`$VIEW_DB\`.\`v_strings\` AS SELECT id, c_char, c_varchar, c_text, c_json FROM \`$DB_TYPES\`.\`t_strings\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TYPES" "t_binary_blob" &&
    add_view "v_binary_blob" "CREATE VIEW \`$VIEW_DB\`.\`v_binary_blob\` AS SELECT id, HEX(c_binary) AS c_binary_hex, HEX(c_varbinary) AS c_varbinary_hex, HEX(c_blob) AS c_blob_hex FROM \`$DB_TYPES\`.\`t_binary_blob\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TYPES" "t_temporal" &&
    add_view "v_temporal" "CREATE VIEW \`$VIEW_DB\`.\`v_temporal\` AS SELECT * FROM \`$DB_TYPES\`.\`t_temporal\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TYPES" "t_vector_vecf32" &&
    add_view "v_vector" "CREATE VIEW \`$VIEW_DB\`.\`v_vector\` AS SELECT id, embedding FROM \`$DB_TYPES\`.\`t_vector_vecf32\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TYPES" "t_enum_set" &&
    add_view "v_enum_set" "CREATE VIEW \`$VIEW_DB\`.\`v_enum_set\` AS SELECT * FROM \`$DB_TYPES\`.\`t_enum_set\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_TYPES" "t_uuid" &&
    add_view "v_uuid" "CREATE VIEW \`$VIEW_DB\`.\`v_uuid\` AS SELECT * FROM \`$DB_TYPES\`.\`t_uuid\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_MVCC" "t_dml_history" &&
    add_view "v_dml_history" "CREATE VIEW \`$VIEW_DB\`.\`v_dml_history\` AS SELECT * FROM \`$DB_MVCC\`.\`t_dml_history\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_MVCC" "t_alter_case" &&
    add_view "v_alter_case" "CREATE VIEW \`$VIEW_DB\`.\`v_alter_case\` AS SELECT * FROM \`$DB_MVCC\`.\`t_alter_case\`"

  table_exists "$SOURCE_USER" "$SOURCE_PASSWORD" "$DB_MVCC" "t_scale_rows" &&
    add_view "v_scale_rows" "CREATE VIEW \`$VIEW_DB\`.\`v_scale_rows\` AS SELECT id, group_id, payload FROM \`$DB_MVCC\`.\`t_scale_rows\` WHERE id < 100"
}

create_source_views() {
  local sql_file="$OUT/create_views.sql"

  build_view_sql
  if [[ ! -s "$VIEWS_TSV" ]]; then
    echo "No view definitions were generated. Base coverage tables may be missing." >&2
    exit 1
  fi

  {
    echo "DROP DATABASE IF EXISTS \`$VIEW_DB\`;"
    echo "CREATE DATABASE \`$VIEW_DB\`;"
    echo "USE \`$VIEW_DB\`;"
    while IFS=$'\t' read -r name sql; do
      echo "DROP VIEW IF EXISTS \`$name\`;"
      echo "$sql;"
    done < "$VIEWS_TSV"
    echo "SHOW FULL TABLES;"
  } > "$sql_file"

  log "==> Create source views in $VIEW_DB"
  mysql_exec "$SOURCE_USER" "$SOURCE_PASSWORD" < "$sql_file" > "$LOG_DIR/create_views.log" 2>&1
}

trigger_checkpoint() {
  log "==> Trigger checkpoint"
  mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT mo_ctl('dn', 'checkpoint', '');" \
    > "$LOG_DIR/trigger_checkpoint.log" 2>&1
}

wait_view_db() {
  local deadline=$(( $(date +%s) + WAIT_SECONDS ))
  local db_id=""

  log "==> Wait for $VIEW_DB in checkpoint metadata"
  while (( $(date +%s) <= deadline )); do
    "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$OUT/databases.txt" 2> "$LOG_DIR/ckp_list_databases.err" || true
    db_id="$(awk -v db="$VIEW_DB" '$2 == db {print $3; exit}' "$OUT/databases.txt")"
    if [[ -n "$db_id" ]]; then
      echo "$db_id" > "$OUT/view_db_id.txt"
      return 0
    fi
    log "    $VIEW_DB not found yet; retry after ${POLL_SECONDS}s"
    sleep "$POLL_SECONDS"
  done

  echo "$VIEW_DB not found in checkpoint within ${WAIT_SECONDS}s" >&2
  return 1
}

dump_views() {
  local db_id
  local name
  local create_sql
  local table_id
  local rel_kind
  local dir
  local log_file
  local restore
  local dump_status
  local has_create_view
  local has_load_data

  db_id="$(cat "$OUT/view_db_id.txt")"
  "$MO_TOOL" ckp list --type=tables --database-id="$db_id" "$CKP_DATA" \
    > "$OUT/view_tables.txt" 2> "$LOG_DIR/ckp_list_view_tables.err"

  printf 'view\tview_id\trel_kind\tdump_status\trestore_sql\thas_create_view\thas_load_data\n' > "$OUT/dump_summary.tsv"

  while IFS=$'\t' read -r name create_sql; do
    table_id="$(awk -v t="$name" '$3 == t {print $4; exit}' "$OUT/view_tables.txt")"
    rel_kind="$(awk -v t="$name" '$3 == t {print $5; exit}' "$OUT/view_tables.txt")"

    if [[ -z "$table_id" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$name" "NOT_FOUND" "$rel_kind" "SKIP" "-" "NO" "NO" >> "$OUT/dump_summary.tsv"
      continue
    fi

    dir="$DUMP_DIR/$(safe_name "${table_id}_${name}")"
    log_file="$LOG_DIR/${name}.dump.log"
    restore="$dir/restore.sql"
    mkdir -p "$dir"

    log "==> Dump view $name table_id=$table_id rel_kind=$rel_kind"
    set +e
    "$MO_TOOL" ckp dump \
      --table-id="$table_id" \
      --load-script \
      -o "$dir" \
      "$CKP_DATA" > "$log_file" 2>&1
    dump_status=$?
    set -e

    has_create_view="NO"
    has_load_data="NO"
    if [[ -f "$restore" ]]; then
      grep -Eqi 'CREATE[[:space:]]+VIEW' "$restore" && has_create_view="YES"
      grep -Eqi 'LOAD[[:space:]]+DATA' "$restore" && has_load_data="YES"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$table_id" "$rel_kind" "$dump_status" "$restore" "$has_create_view" "$has_load_data" \
      >> "$OUT/dump_summary.tsv"
  done < "$VIEWS_TSV"
}

load_views_to_target() {
  local name
  local view_id
  local rel_kind
  local dump_status
  local restore
  local has_create_view
  local has_load_data
  local log_file
  local load_status

  log "==> Drop target view database $VIEW_DB"
  mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "DROP DATABASE IF EXISTS \`$VIEW_DB\`;" \
    > "$LOG_DIR/drop_target_view_db_before_base_prepare.log" 2>&1 || true

  log "==> Prepare target base dependencies"
  prepare_base_data "$TARGET_USER" "$TARGET_PASSWORD" "target"
  create_external_fixture "$TARGET_USER" "$TARGET_PASSWORD" "target"

  printf 'view\tload_status\tlog\n' > "$OUT/load_summary.tsv"
  tail -n +2 "$OUT/dump_summary.tsv" | while IFS=$'\t' read -r name view_id rel_kind dump_status restore has_create_view has_load_data; do
    log_file="$LOG_DIR/${name}.restore.log"
    if [[ "$dump_status" != "0" || ! -f "$restore" ]]; then
      load_status="SKIP"
    else
      log "==> Load view $name into target tenant"
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
        load_status="OK"
      else
        load_status="FAIL"
      fi
    fi
    printf '%s\t%s\t%s\n' "$name" "$load_status" "$log_file" >> "$OUT/load_summary.tsv"
  done
}

dump_view_query() {
  local user="$1"
  local password="$2"
  local view="$3"
  local out_file="$4"

  MYSQL_PWD="$password" "$MYSQL_BIN" \
    -h"$HOST" \
    -P"$PORT" \
    -u"$user" \
    --default-character-set=utf8mb4 \
    --batch \
    --raw \
    --skip-column-names \
    -e "SELECT * FROM \`$VIEW_DB\`.\`$view\`;" \
    | LC_ALL=C sort > "$out_file"
}

normalize_schema() {
  sed -E \
    -e "s/CREATE VIEW \`$VIEW_DB\`\.\`/CREATE VIEW \`/Ig" \
    -e 's/[[:space:]]+$//'
}

compare_views() {
  local name
  local view_id
  local rel_kind
  local dump_status
  local restore
  local has_create_view
  local has_load_data
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

  printf 'view\tview_id\trel_kind\tdump_status\tddl_status\tno_load_data\tload_status\tsource_count\ttarget_count\tcount_status\tschema_status\tdata_status\n' > "$SUMMARY"

  tail -n +2 "$OUT/dump_summary.tsv" | while IFS=$'\t' read -r name view_id rel_kind dump_status restore has_create_view has_load_data; do
    load_status="$(awk -F'\t' -v v="$name" '$1 == v {print $2; exit}' "$OUT/load_summary.tsv")"
    [[ -z "$load_status" ]] && load_status="MISSING"

    source_count="$(mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SELECT COUNT(*) FROM \`$VIEW_DB\`.\`$name\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    target_count="$(mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SELECT COUNT(*) FROM \`$VIEW_DB\`.\`$name\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    if [[ "$source_count" == "$target_count" ]]; then
      count_status="OK"
    else
      count_status="DIFF"
    fi

    source_schema="$COMPARE_DIR/${name}.source.schema.sql"
    target_schema="$COMPARE_DIR/${name}.target.schema.sql"
    schema_diff="$COMPARE_DIR/${name}.schema.diff"
    source_data="$COMPARE_DIR/${name}.source.data.tsv"
    target_data="$COMPARE_DIR/${name}.target.data.tsv"
    data_diff="$COMPARE_DIR/${name}.data.diff"

    mysql_query "$SOURCE_USER" "$SOURCE_PASSWORD" "SHOW CREATE TABLE \`$VIEW_DB\`.\`$name\`;" \
      | cut -f2- | normalize_schema > "$source_schema" || true
    mysql_query "$TARGET_USER" "$TARGET_PASSWORD" "SHOW CREATE TABLE \`$VIEW_DB\`.\`$name\`;" \
      | cut -f2- | normalize_schema > "$target_schema" || true
    if diff -u "$source_schema" "$target_schema" > "$schema_diff"; then
      schema_status="OK"
    else
      schema_status="DIFF"
    fi

    if dump_view_query "$SOURCE_USER" "$SOURCE_PASSWORD" "$name" "$source_data" \
        && dump_view_query "$TARGET_USER" "$TARGET_PASSWORD" "$name" "$target_data" \
        && diff -u "$source_data" "$target_data" > "$data_diff"; then
      data_status="OK"
    else
      data_status="DIFF"
    fi

    ddl_status="FAIL"
    [[ "$has_create_view" == "YES" ]] && ddl_status="OK"

    no_load_data="FAIL"
    [[ "$has_load_data" == "NO" ]] && no_load_data="OK"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$name" "$view_id" "$rel_kind" "$dump_status" "$ddl_status" "$no_load_data" "$load_status" \
      "$source_count" "$target_count" "$count_status" "$schema_status" "$data_status" \
      >> "$SUMMARY"
  done
}

final_check() {
  local failed=0

  log "==> View summary"
  column -t -s $'\t' "$SUMMARY" || cat "$SUMMARY"
  log "Artifacts: $OUT"

  if awk -F'\t' 'NR > 1 && ($2 == "NOT_FOUND" || $4 != "0" || $5 != "OK" || $6 != "OK" || $7 != "OK" || $10 != "OK" || $11 != "OK" || $12 != "OK") {bad=1} END {exit bad ? 0 : 1}' "$SUMMARY"; then
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "CHECKPOINT_VIEW_DUMP_FAIL"
    return 1
  fi

  echo "CHECKPOINT_VIEW_DUMP_OK"
}

log "OUT=$OUT"
log "VIEW_DB=$VIEW_DB"
log "MO_TOOL=$MO_TOOL"
log "CKP_DATA=$CKP_DATA"

ensure_target_account

if [[ "$SKIP_PREPARE" != "1" ]]; then
  prepare_base_data "$SOURCE_USER" "$SOURCE_PASSWORD" "source"
fi

create_external_fixture "$SOURCE_USER" "$SOURCE_PASSWORD" "source"
create_source_views
trigger_checkpoint
wait_view_db
dump_views
load_views_to_target
compare_views
final_check
