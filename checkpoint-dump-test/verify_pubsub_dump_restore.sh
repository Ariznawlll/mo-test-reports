#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify checkpoint dump/restore for MatrixOne publication/subscription tables.

Coverage:
  - publisher tenant publishes a full database
  - publisher tenant publishes selected tables
  - subscriber tenant subscribes both publications
  - checkpoint dump/restore publisher databases
  - checkpoint dump/restore subscriber databases
  - compare source vs restored target schema, row counts, and full data
  - target restore is expected to create ordinary databases only; publication
    and subscription relationships are not expected to be preserved by ckp dump

Default accounts are dedicated test accounts:
  publisher:  ckppubsrc:test_account
  subscriber: ckppubsub:test_account
  target:     ckppubdst:test_account

Usage:
  ./verify_pubsub_dump_restore.sh [options]

Options:
  --host HOST                 MatrixOne MySQL host, default: 127.0.0.1
  --port PORT                 MatrixOne MySQL port, default: 6001
  --sys-user USER             Sys/admin user used to create accounts and checkpoint, default: dump
  --sys-password PASS         Sys/admin password, default: 111
  --publisher-account NAME    Publisher account, default: ckppubsrc
  --subscriber-account NAME   Subscriber account, default: ckppubsub
  --target-account NAME       Restore target account, default: ckppubdst
  --account-admin USER        Account admin user, default: test_account
  --account-password PASS     Account admin password, default: 111
  --db-prefix PREFIX          DB/publication prefix, default: ckp_pubsub_<timestamp>
  --mo-tool PATH              mo-tool path, default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH             Checkpoint data path
  --out DIR                   Output dir, default: /data4/weilu/verify_pubsub_<timestamp>
  --mysql-bin PATH            mysql client path, default: mysql
  --wait-seconds N            Max wait for checkpoint metadata, default: 300
  --poll-seconds N            Poll interval, default: 5
  --drop-existing             Drop/recreate dedicated test accounts before running
  --help                      Show this help
USAGE
}

TS="$(date +%Y%m%d_%H%M%S)"

HOST="127.0.0.1"
PORT="6001"
SYS_USER="dump"
SYS_PASSWORD="111"
PUBLISHER_ACCOUNT="ckppubsrc"
SUBSCRIBER_ACCOUNT="ckppubsub"
TARGET_ACCOUNT="ckppubdst"
ACCOUNT_ADMIN="test_account"
ACCOUNT_PASSWORD="111"
DB_PREFIX="ckp_pubsub_${TS}"
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_pubsub_${TS}"
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
    --publisher-account) PUBLISHER_ACCOUNT="$2"; shift 2 ;;
    --subscriber-account) SUBSCRIBER_ACCOUNT="$2"; shift 2 ;;
    --target-account) TARGET_ACCOUNT="$2"; shift 2 ;;
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

PUBLISHER_USER="${PUBLISHER_ACCOUNT}:${ACCOUNT_ADMIN}"
SUBSCRIBER_USER="${SUBSCRIBER_ACCOUNT}:${ACCOUNT_ADMIN}"
TARGET_USER="${TARGET_ACCOUNT}:${ACCOUNT_ADMIN}"

DB_PUB_ALL="${DB_PREFIX}_pub_all"
DB_PUB_PART="${DB_PREFIX}_pub_part"
DB_SUB_ALL="${DB_PREFIX}_sub_all"
DB_SUB_PART="${DB_PREFIX}_sub_part"
PUB_ALL="${DB_PREFIX}_pub_all"
PUB_PART="${DB_PREFIX}_pub_part"

LOG_DIR="$OUT/logs"
DUMP_DIR="$OUT/dumps"
COMPARE_DIR="$OUT/compare"
mkdir -p "$LOG_DIR" "$DUMP_DIR" "$COMPARE_DIR"

DATABASES=(
  $'publisher_all\t'"$PUBLISHER_USER"$'\t'"$DB_PUB_ALL"
  $'publisher_part\t'"$PUBLISHER_USER"$'\t'"$DB_PUB_PART"
  $'subscriber_all\t'"$SUBSCRIBER_USER"$'\t'"$DB_SUB_ALL"
  $'subscriber_part\t'"$SUBSCRIBER_USER"$'\t'"$DB_SUB_PART"
)

MANIFEST="$OUT/table_manifest.tsv"
DB_METADATA_SUMMARY="$OUT/db_metadata_summary.tsv"
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
    -e "SELECT * FROM \`$db\`.\`$table\`;" \
    | LC_ALL=C sort > "$out_file"
}

create_accounts() {
  local admin_sql
  local pass_sql
  admin_sql="$(quote_sql_string "$ACCOUNT_ADMIN")"
  pass_sql="$(quote_sql_string "$ACCOUNT_PASSWORD")"

  if [[ "$DROP_EXISTING" == "1" ]]; then
    log "==> Drop dedicated test accounts"
    mysql_query "$SYS_USER" "$SYS_PASSWORD" "DROP ACCOUNT IF EXISTS \`$TARGET_ACCOUNT\`;" > "$LOG_DIR/drop_target_account.log" 2>&1 || true
    mysql_query "$SYS_USER" "$SYS_PASSWORD" "DROP ACCOUNT IF EXISTS \`$SUBSCRIBER_ACCOUNT\`;" > "$LOG_DIR/drop_subscriber_account.log" 2>&1 || true
    mysql_query "$SYS_USER" "$SYS_PASSWORD" "DROP ACCOUNT IF EXISTS \`$PUBLISHER_ACCOUNT\`;" > "$LOG_DIR/drop_publisher_account.log" 2>&1 || true
  fi

  log "==> Ensure publication/subscription test accounts"
  mysql_query "$SYS_USER" "$SYS_PASSWORD" \
    "CREATE ACCOUNT \`$PUBLISHER_ACCOUNT\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_publisher_account.log" 2>&1 || true
  mysql_query "$SYS_USER" "$SYS_PASSWORD" \
    "CREATE ACCOUNT \`$SUBSCRIBER_ACCOUNT\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_subscriber_account.log" 2>&1 || true
  mysql_query "$SYS_USER" "$SYS_PASSWORD" \
    "CREATE ACCOUNT \`$TARGET_ACCOUNT\` ADMIN_NAME '$admin_sql' IDENTIFIED BY '$pass_sql';" \
    > "$LOG_DIR/create_target_account.log" 2>&1 || true
}

prepare_publications() {
  local sql_file="$OUT/create_publications.sql"

  cat > "$sql_file" <<SQL
DROP DATABASE IF EXISTS \`$DB_PUB_ALL\`;
CREATE DATABASE \`$DB_PUB_ALL\`;
USE \`$DB_PUB_ALL\`;

CREATE TABLE t_pk (
  id INT NOT NULL PRIMARY KEY,
  name VARCHAR(50),
  amount DECIMAL(10,2)
);
INSERT INTO t_pk VALUES
  (1, 'pub-all-a', 10.10),
  (2, 'pub-all-b', 20.20),
  (3, 'pub-all-c', 30.30);

CREATE TABLE t_auto (
  id BIGINT NOT NULL AUTO_INCREMENT,
  note VARCHAR(50),
  PRIMARY KEY(id)
) AUTO_INCREMENT = 100 COMMENT='publication auto table';
INSERT INTO t_auto(note) VALUES ('auto-a'), ('auto-b');
INSERT INTO t_auto(id, note) VALUES (200, 'manual-id');

CREATE TABLE t_hash (
  id INT NOT NULL,
  region_id INT NOT NULL,
  payload VARCHAR(50),
  PRIMARY KEY(id)
) PARTITION BY HASH(region_id) PARTITIONS 4;
INSERT INTO t_hash VALUES
  (1, 1, 'hash-a'),
  (2, 2, 'hash-b'),
  (3, 3, 'hash-c'),
  (4, 4, 'hash-d');

DROP DATABASE IF EXISTS \`$DB_PUB_PART\`;
CREATE DATABASE \`$DB_PUB_PART\`;
USE \`$DB_PUB_PART\`;

CREATE TABLE t_pub (
  id INT NOT NULL PRIMARY KEY,
  payload VARCHAR(80)
);
INSERT INTO t_pub VALUES
  (1, 'published-row-1'),
  (2, 'published-row-2');

CREATE TABLE t_extra (
  id INT NOT NULL PRIMARY KEY,
  payload VARCHAR(80)
);
INSERT INTO t_extra VALUES
  (10, 'extra-published-1'),
  (20, 'extra-published-2');

CREATE TABLE t_skip (
  id INT NOT NULL PRIMARY KEY,
  payload VARCHAR(80)
);
INSERT INTO t_skip VALUES
  (100, 'not-published-1'),
  (200, 'not-published-2');

DROP PUBLICATION IF EXISTS \`$PUB_ALL\`;
DROP PUBLICATION IF EXISTS \`$PUB_PART\`;
CREATE PUBLICATION \`$PUB_ALL\` DATABASE \`$DB_PUB_ALL\` ACCOUNT \`$SUBSCRIBER_ACCOUNT\` COMMENT 'checkpoint dump pubsub full db';
CREATE PUBLICATION \`$PUB_PART\` DATABASE \`$DB_PUB_PART\` TABLE t_pub,t_extra ACCOUNT \`$SUBSCRIBER_ACCOUNT\` COMMENT 'checkpoint dump pubsub selected tables';

SHOW PUBLICATIONS;
SQL

  log "==> Create publisher databases and publications"
  mysql_exec "$PUBLISHER_USER" "$ACCOUNT_PASSWORD" < "$sql_file" > "$LOG_DIR/create_publications.log" 2>&1
}

prepare_subscriptions() {
  local sql_file="$OUT/create_subscriptions.sql"

  cat > "$sql_file" <<SQL
DROP DATABASE IF EXISTS \`$DB_SUB_ALL\`;
DROP DATABASE IF EXISTS \`$DB_SUB_PART\`;

CREATE DATABASE \`$DB_SUB_ALL\` FROM \`$PUBLISHER_ACCOUNT\` PUBLICATION \`$PUB_ALL\`;
CREATE DATABASE \`$DB_SUB_PART\` FROM \`$PUBLISHER_ACCOUNT\` PUBLICATION \`$PUB_PART\`;

SHOW SUBSCRIPTIONS ALL;

USE \`$DB_SUB_ALL\`;
SHOW TABLES;
SELECT COUNT(*) AS t_pk_count FROM t_pk;
SELECT COUNT(*) AS t_auto_count FROM t_auto;
SELECT COUNT(*) AS t_hash_count FROM t_hash;

USE \`$DB_SUB_PART\`;
SHOW TABLES;
SELECT COUNT(*) AS t_pub_count FROM t_pub;
SELECT COUNT(*) AS t_extra_count FROM t_extra;
SQL

  log "==> Create subscriber databases from publications"
  mysql_exec "$SUBSCRIBER_USER" "$ACCOUNT_PASSWORD" < "$sql_file" > "$LOG_DIR/create_subscriptions.log" 2>&1
}

capture_pubsub_metadata() {
  log "==> Capture publication/subscription metadata"
  mysql_query "$PUBLISHER_USER" "$ACCOUNT_PASSWORD" "SHOW PUBLICATIONS;" > "$OUT/show_publications.tsv" 2> "$LOG_DIR/show_publications.err" || true
  mysql_query "$SUBSCRIBER_USER" "$ACCOUNT_PASSWORD" "SHOW SUBSCRIPTIONS ALL;" > "$OUT/show_subscriptions_all.tsv" 2> "$LOG_DIR/show_subscriptions_all.err" || true
}

trigger_checkpoint() {
  log "==> Trigger checkpoint"
  mysql_query "$SYS_USER" "$SYS_PASSWORD" "SELECT mo_ctl('dn', 'checkpoint', '');" \
    > "$LOG_DIR/trigger_checkpoint.log" 2>&1
}

write_database_metadata_summary() {
  local item
  local label
  local user
  local db
  local db_id

  printf 'label\tsource_user\tdb\tmetadata_status\tdb_id\n' > "$DB_METADATA_SUMMARY"
  for item in "${DATABASES[@]}"; do
    IFS=$'\t' read -r label user db <<< "$item"
    db_id="$(awk -v db="$db" '$2 == db {print $3; exit}' "$OUT/databases.txt" 2>/dev/null || true)"
    if [[ -n "$db_id" ]]; then
      printf '%s\t%s\t%s\tFOUND\t%s\n' "$label" "$user" "$db" "$db_id" >> "$DB_METADATA_SUMMARY"
    else
      printf '%s\t%s\t%s\tNOT_FOUND\t-\n' "$label" "$user" "$db" >> "$DB_METADATA_SUMMARY"
    fi
  done
}

wait_databases() {
  local deadline=$(( $(date +%s) + WAIT_SECONDS ))
  local all_found
  local item
  local label
  local user
  local db

  log "==> Wait for publisher/subscriber databases in checkpoint metadata"
  while (( $(date +%s) <= deadline )); do
    "$MO_TOOL" ckp list --type=databases "$CKP_DATA" > "$OUT/databases.txt" 2> "$LOG_DIR/ckp_list_databases.err" || true
    write_database_metadata_summary
    all_found="1"
    for item in "${DATABASES[@]}"; do
      IFS=$'\t' read -r label user db <<< "$item"
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

  log "    Not all publisher/subscriber databases were found within ${WAIT_SECONDS}s; continue with FOUND databases"
  write_database_metadata_summary
  return 0
}

collect_table_manifest() {
  local item
  local label
  local source_user
  local db
  local db_id
  local table_file

  printf 'label\tsource_user\tdb\tdb_id\ttable\ttable_id\trel_kind\n' > "$MANIFEST"
  for item in "${DATABASES[@]}"; do
    IFS=$'\t' read -r label source_user db <<< "$item"
    db_id="$(awk -F'\t' -v db="$db" '$3 == db && $4 == "FOUND" {print $5; exit}' "$DB_METADATA_SUMMARY")"
    if [[ -z "$db_id" ]]; then
      log "==> Skip $label $db: database not found in checkpoint metadata"
      continue
    fi

    table_file="$OUT/${db}_tables.txt"
    "$MO_TOOL" ckp list --type=tables --database-id="$db_id" "$CKP_DATA" \
      > "$table_file" 2> "$LOG_DIR/${db}_ckp_list_tables.err"

    awk -v label="$label" -v source_user="$source_user" -v db="$db" -v db_id="$db_id" \
      'NR > 1 && $5 == "r" {print label "\t" source_user "\t" db "\t" db_id "\t" $3 "\t" $4 "\t" $5}' \
      "$table_file" >> "$MANIFEST"
  done
}

dump_tables() {
  local label
  local source_user
  local db
  local db_id
  local table
  local table_id
  local rel_kind
  local tag
  local table_dir
  local log_file
  local restore
  local dump_status
  local source_count

  printf 'label\tdb\ttable\ttable_id\tdump_status\tsource_count\trestore_sql\n' > "$DUMP_SUMMARY"

  tail -n +2 "$MANIFEST" | sort -t $'\t' -k3,3 -k6,6n | while IFS=$'\t' read -r label source_user db db_id table table_id rel_kind; do
    tag="$(safe_name "${label}_${db}_${table_id}_${table}")"
    table_dir="$DUMP_DIR/$tag"
    log_file="$LOG_DIR/${tag}.dump.log"
    restore="$table_dir/restore.sql"
    mkdir -p "$table_dir"

    log "==> Dump $label $db.$table table_id=$table_id"
    set +e
    "$MO_TOOL" ckp dump \
      --table-id="$table_id" \
      --header \
      --load-script \
      -o "$table_dir" \
      "$CKP_DATA" > "$log_file" 2>&1
    dump_status=$?
    set -e

    source_count="$(mysql_query "$source_user" "$ACCOUNT_PASSWORD" "SELECT COUNT(*) FROM \`$db\`.\`$table\`;" 2>/dev/null || printf 'QUERY_FAIL')"

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$db" "$table" "$table_id" "$dump_status" "$source_count" "$restore" >> "$DUMP_SUMMARY"
  done
}

restore_target() {
  local item
  local label
  local source_user
  local db
  local db_id
  local table
  local table_id
  local rel_kind
  local tag
  local restore
  local log_file
  local status
  local rc

  for item in "${DATABASES[@]}"; do
    IFS=$'\t' read -r label source_user db <<< "$item"
    log "==> Drop target database $db"
    mysql_query "$TARGET_USER" "$ACCOUNT_PASSWORD" "DROP DATABASE IF EXISTS \`$db\`;" \
      > "$LOG_DIR/drop_target_${db}.log" 2>&1 || true
  done

  printf 'label\tdb\ttable\ttable_id\tload_status\tlog\n' > "$RESTORE_SUMMARY"
  tail -n +2 "$MANIFEST" | sort -t $'\t' -k3,3 -k6,6n | while IFS=$'\t' read -r label source_user db db_id table table_id rel_kind; do
    tag="$(safe_name "${label}_${db}_${table_id}_${table}")"
    restore="$DUMP_DIR/$tag/restore.sql"
    log_file="$LOG_DIR/${tag}.restore.log"
    if [[ ! -f "$restore" ]]; then
      status="MISSING_RESTORE_SQL"
    else
      log "==> Load $label $db.$table into target tenant"
      set +e
      MYSQL_PWD="$ACCOUNT_PASSWORD" "$MYSQL_BIN" \
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

    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$label" "$db" "$table" "$table_id" "$status" "$log_file" >> "$RESTORE_SUMMARY"
  done
}

compare_restored_tables() {
  local label
  local source_user
  local db
  local db_id
  local table
  local table_id
  local rel_kind
  local tag
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

  printf 'label\tdb\ttable\ttable_id\tsource_count\ttarget_count\tcount_status\tschema_status\tdata_status\n' > "$COMPARE_SUMMARY"

  tail -n +2 "$MANIFEST" | sort -t $'\t' -k3,3 -k6,6n | while IFS=$'\t' read -r label source_user db db_id table table_id rel_kind; do
    tag="$(safe_name "${label}_${db}_${table_id}_${table}")"
    source_schema="$COMPARE_DIR/${tag}.source.schema.sql"
    target_schema="$COMPARE_DIR/${tag}.target.schema.sql"
    schema_diff="$COMPARE_DIR/${tag}.schema.diff"
    source_data="$COMPARE_DIR/${tag}.source.data.tsv"
    target_data="$COMPARE_DIR/${tag}.target.data.tsv"
    data_diff="$COMPARE_DIR/${tag}.data.diff"

    source_count="$(mysql_query "$source_user" "$ACCOUNT_PASSWORD" "SELECT COUNT(*) FROM \`$db\`.\`$table\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    target_count="$(mysql_query "$TARGET_USER" "$ACCOUNT_PASSWORD" "SELECT COUNT(*) FROM \`$db\`.\`$table\`;" 2>/dev/null || printf 'QUERY_FAIL')"
    if [[ "$source_count" == "$target_count" ]]; then
      count_status="OK"
    else
      count_status="DIFF"
    fi

    mysql_query "$source_user" "$ACCOUNT_PASSWORD" "SHOW CREATE TABLE \`$db\`.\`$table\`;" \
      | cut -f2- | normalize_schema "$db" > "$source_schema" || true
    mysql_query "$TARGET_USER" "$ACCOUNT_PASSWORD" "SHOW CREATE TABLE \`$db\`.\`$table\`;" \
      | cut -f2- | normalize_schema "$db" > "$target_schema" || true
    if diff -u "$source_schema" "$target_schema" > "$schema_diff"; then
      schema_status="OK"
    else
      schema_status="DIFF"
    fi

    if dump_table_data "$source_user" "$ACCOUNT_PASSWORD" "$db" "$table" "$source_data" \
        && dump_table_data "$TARGET_USER" "$ACCOUNT_PASSWORD" "$db" "$table" "$target_data" \
        && diff -u "$source_data" "$target_data" > "$data_diff"; then
      data_status="OK"
    else
      data_status="DIFF"
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$label" "$db" "$table" "$table_id" "$source_count" "$target_count" "$count_status" "$schema_status" "$data_status" \
      >> "$COMPARE_SUMMARY"
  done
}

check_selected_subscription_shape() {
  log "==> Check selected-table subscription shape"
  {
    echo "subscriber selected tables:"
    mysql_query "$SUBSCRIBER_USER" "$ACCOUNT_PASSWORD" "SHOW TABLES FROM \`$DB_SUB_PART\`;" || true
  } > "$OUT/selected_subscription_tables.txt" 2> "$LOG_DIR/selected_subscription_tables.err"

  if grep -q '^t_skip$' "$OUT/selected_subscription_tables.txt"; then
    echo "Unexpected t_skip found in selected subscription output" >&2
    return 1
  fi
}

final_check() {
  local failed=0

  log "==> Pub/Sub checkpoint metadata summary"
  column -t -s $'\t' "$DB_METADATA_SUMMARY" || cat "$DB_METADATA_SUMMARY"
  log "==> Pub/Sub dump summary"
  column -t -s $'\t' "$DUMP_SUMMARY" || cat "$DUMP_SUMMARY"
  log "==> Pub/Sub restore summary"
  column -t -s $'\t' "$RESTORE_SUMMARY" || cat "$RESTORE_SUMMARY"
  log "==> Pub/Sub compare summary"
  column -t -s $'\t' "$COMPARE_SUMMARY" || cat "$COMPARE_SUMMARY"
  log "Artifacts: $OUT"

  if awk -F'\t' 'NR > 1 && ($5 != "0" || $6 == "QUERY_FAIL") {bad=1} END {exit bad ? 0 : 1}' "$DUMP_SUMMARY"; then
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && $4 != "FOUND" {bad=1} END {exit bad ? 0 : 1}' "$DB_METADATA_SUMMARY"; then
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && $5 != "OK" {bad=1} END {exit bad ? 0 : 1}' "$RESTORE_SUMMARY"; then
    failed=1
  fi
  if awk -F'\t' 'NR > 1 && ($7 != "OK" || $8 != "OK" || $9 != "OK") {bad=1} END {exit bad ? 0 : 1}' "$COMPARE_SUMMARY"; then
    failed=1
  fi

  if [[ "$failed" -ne 0 ]]; then
    echo "PUBSUB_DUMP_RESTORE_FAIL"
    return 1
  fi

  echo "PUBSUB_DUMP_RESTORE_OK"
}

log "OUT=$OUT"
log "DB_PREFIX=$DB_PREFIX"
log "PUBLISHER=$PUBLISHER_USER"
log "SUBSCRIBER=$SUBSCRIBER_USER"
log "TARGET=$TARGET_USER"
log "MO_TOOL=$MO_TOOL"
log "CKP_DATA=$CKP_DATA"

create_accounts
prepare_publications
prepare_subscriptions
capture_pubsub_metadata
trigger_checkpoint
wait_databases
collect_table_manifest
dump_tables
restore_target
compare_restored_tables
check_selected_subscription_shape
final_check
