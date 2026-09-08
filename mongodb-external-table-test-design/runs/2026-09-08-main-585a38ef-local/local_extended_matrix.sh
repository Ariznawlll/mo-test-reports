#!/usr/bin/env bash
# Copyright 2026 Matrix Origin
# Licensed under the Apache License, Version 2.0.

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REPORT_DIR="${MO_MONGODB_REPORT_DIR:?MO_MONGODB_REPORT_DIR is required}"
MO_PORT="${MO_PORT:?MO_PORT is required}"
MONGODB_PORT="${MONGODB_PORT:?MONGODB_PORT is required}"
STATUS_PORT="${MO_MONGODB_STATUS_PORT:?MO_MONGODB_STATUS_PORT is required}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}"
MONGODB_ROOT_USER="${MONGODB_ROOT_USER:?MONGODB_ROOT_USER is required}"
MONGODB_ROOT_PASSWORD="${MONGODB_ROOT_PASSWORD:?MONGODB_ROOT_PASSWORD is required}"
MONGODB_TENANT_READER_PASSWORD="${MONGODB_TENANT_READER_PASSWORD:?MONGODB_TENANT_READER_PASSWORD is required}"

MYSQL_BIN="${MYSQL_BIN:-/usr/local/mysql/bin/mysql}"
COMPOSE_FILE="$ROOT_DIR/etc/launch-mongodb-local/compose.yaml"
CASE_FILE="$REPORT_DIR/local-matrix-cases.tsv"
SUMMARY_FILE="$REPORT_DIR/local-matrix-summary.json"
STDERR_FILE="$(mktemp "${TMPDIR:-/private/tmp}/mo-mongodb-matrix-stderr.XXXXXX")"
CSV_FILE="$REPORT_DIR/local_matrix_file.csv"
failures=0
passes=0

cleanup() {
  rm -f -- "$STDERR_FILE"
}
trap cleanup EXIT

mkdir -p "$REPORT_DIR"
printf 'case\tstatus\tdetail\n' >"$CASE_FILE"
printf '1|file-one\n2|file-two\n' >"$CSV_FILE"

record() {
  local name="$1" status="$2" detail="$3"
  detail="$(printf '%s' "$detail" | tr '\t\r\n' ' ' | sed -E \
    -e 's#mongodb(\+srv)?://[^[:space:]]+#mongodb://<redacted>#g' \
    -e 's#(password|credential|token|secret)[=:][^ ,}\"]+#\1=<redacted>#Ig' | cut -c1-500)"
  printf '%s\t%s\t%s\n' "$name" "$status" "$detail" >>"$CASE_FILE"
  if [[ "$status" == PASS ]]; then
    passes=$((passes + 1))
    printf '[local-matrix] PASS %s\n' "$name"
  else
    failures=$((failures + 1))
    printf '[local-matrix] FAIL %s: %s\n' "$name" "$detail" >&2
  fi
}

mysql_raw_as() {
  local user="$1" password="$2" sql="$3"
  MYSQL_PWD="$password" "$MYSQL_BIN" --protocol=tcp -h 127.0.0.1 -P "$MO_PORT" \
    -u "$user" --ssl-mode=DISABLED --connect-timeout=5 --batch --skip-column-names --raw \
    -e "$sql" 2>"$STDERR_FILE"
}

mysql_raw() {
  mysql_raw_as root 111 "$1"
}

expect_ok() {
  local name="$1" sql="$2" output status
  output="$(mysql_raw "$sql")"; status=$?
  if (( status == 0 )); then
    record "$name" PASS ok
  else
    record "$name" FAIL "exit=$status $(<"$STDERR_FILE")"
  fi
}

expect_scalar() {
  local name="$1" expected="$2" sql="$3" output status
  output="$(mysql_raw "$sql")"; status=$?
  if (( status == 0 )) && [[ "$output" == "$expected" ]]; then
    record "$name" PASS "value=$expected"
  else
    record "$name" FAIL "exit=$status expected=$expected actual=$output $(<"$STDERR_FILE")"
  fi
}

expect_fail() {
  local name="$1" pattern="$2" sql="$3" output status error_text
  output="$(mysql_raw "$sql")"; status=$?
  error_text="$(<"$STDERR_FILE")"
  if (( status != 0 )) && printf '%s' "$error_text" | grep -Eiq "$pattern"; then
    record "$name" PASS "rejected as expected"
  elif (( status != 0 )); then
    record "$name" FAIL "rejected with unexpected error: $error_text"
  else
    record "$name" FAIL "unexpectedly succeeded: $output"
  fi
}

expect_scalar_as() {
  local name="$1" user="$2" password="$3" expected="$4" sql="$5" output status
  output="$(mysql_raw_as "$user" "$password" "$sql")"; status=$?
  if (( status == 0 )) && [[ "$output" == "$expected" ]]; then
    record "$name" PASS "value=$expected"
  else
    record "$name" FAIL "exit=$status expected=$expected actual=$output $(<"$STDERR_FILE")"
  fi
}

metric_value() {
  local metric="$1"
  curl -fsS --max-time 5 "http://127.0.0.1:$STATUS_PORT/metrics" 2>/dev/null | \
    awk -v wanted="$metric" '$1 == wanted {sum += $2; found=1} END {if (found) print sum; else print 0}'
}

seed_mongodb() {
  docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" exec -T \
    -e MONGODB_TENANT_READER_PASSWORD="$MONGODB_TENANT_READER_PASSWORD" mongo \
    mongosh --quiet -u "$MONGODB_ROOT_USER" -p "$MONGODB_ROOT_PASSWORD" \
    --authenticationDatabase admin >/dev/null <<'MONGOJS'
const source = db.getSiblingDB("mongodb_source");
if (!source.getUser("mo_tenant_reader")) {
  source.createUser({
    user: "mo_tenant_reader",
    pwd: process.env.MONGODB_TENANT_READER_PASSWORD,
    roles: [{role: "read", db: "mongodb_source"}]
  });
}

source.matrix_types.drop();
source.matrix_types.insertOne({_id: ObjectId("64b000000000000000001001")});
source.matrix_types.updateOne({}, {$set: {
  bool_v: true,
  i8: NumberInt(-128), i16: NumberInt(32767), i32: NumberInt(-2147483648),
  i64: NumberLong("9223372036854775807"),
  u8: NumberInt(255), u16: NumberInt(65535), u32: NumberLong("4294967295"),
  u64: NumberLong("9223372036854775807")
}});
source.matrix_types.updateOne({}, {$set: {f32: 3.5, f64: -1.25}});
source.matrix_types.updateOne({}, {$set: {d64: NumberDecimal("123456789012.3456")}});
source.matrix_types.updateOne({}, {$set: {d128: NumberDecimal("12345678901234567890.1234")}});
source.matrix_types.updateOne({}, {$set: {d256: NumberDecimal("1234567890123456789012345678901234")}});
source.matrix_types.updateOne({}, {$set: {
  date_v: ISODate("2026-09-08T12:34:56.789Z"),
  datetime_v: ISODate("2026-09-08T12:34:56.789Z"),
  timestamp_v: ISODate("2026-09-08T12:34:56.789Z")
}});
source.matrix_types.updateOne({}, {$set: {
  char_v: "中A", varchar_v: "hello🙂", text_v: "text-value",
}});
source.matrix_types.updateOne({}, {$set: {
  binary_v: BinData(0, "AQI="), varbinary_v: BinData(0, "AQID"),
  blob_v: BinData(0, "AP+A"), object_id_v: ObjectId("64b000000000000000009999")
}});
source.matrix_types.updateOne({}, {$set: {
  json_doc: {nested: {k: "v"}, n: NumberInt(2)},
  json_arr: [NumberInt(1), NumberInt(2), NumberInt(3)],
  json_oid: ObjectId("64b000000000000000008888")
}});

source.matrix_nulls.drop();
source.matrix_nulls.insertMany([
  {_id: "good", v: NumberInt(7)},
  {_id: "null", v: null},
  {_id: "missing"},
  {_id: "undefined", v: undefined},
  {_id: "bad", v: "not-an-int"}
]);

source.matrix_paths.drop();
source.matrix_paths.insertMany([
  {_id: "doc", a: {b: {c: NumberInt(5)}}, A: NumberInt(9)},
  {_id: "missing"},
  {_id: "null-parent", a: null},
  {_id: "scalar-parent", a: NumberInt(1)},
  {_id: "array-parent", a: [{b: {c: NumberInt(7)}}]}
]);

source.matrix_strings.drop();
source.matrix_strings.insertOne({_id: "unicode", value: "中文🙂"});

source.matrix_overflow.drop();
source.matrix_overflow.insertOne({
  _id: "overflow",
  i8: NumberInt(128), u8: NumberInt(-1), f32: 1e40,
  decimal_v: NumberDecimal("123456.78"),
  datetime_v: new Date(253402300800000)
});

source.constraint_good.drop();
source.constraint_good.insertMany([
  {_id: "g1", pk: NumberInt(1), uniq: "u1", parent: NumberInt(1), val: NumberInt(10), tag: "a"},
  {_id: "g2", pk: NumberInt(2), uniq: "u2", parent: NumberInt(2), val: NumberInt(20), tag: "b"}
]);
source.bad_pk.drop();
source.bad_pk.insertMany([{_id:"p1",pk:NumberInt(1)},{_id:"p2",pk:NumberInt(1)}]);
source.bad_unique.drop();
source.bad_unique.insertMany([{_id:"u1",pk:NumberInt(1),uniq:"dup"},{_id:"u2",pk:NumberInt(2),uniq:"dup"}]);
source.bad_fk.drop();
source.bad_fk.insertMany([{_id:"f1",pk:NumberInt(1),parent:NumberInt(1)},{_id:"f2",pk:NumberInt(2),parent:NumberInt(99)}]);
source.bad_check.drop();
source.bad_check.insertMany([{_id:"c1",pk:NumberInt(1),val:NumberInt(10)},{_id:"c2",pk:NumberInt(2),val:NumberInt(-1)}]);
source.bad_notnull.drop();
source.bad_notnull.insertMany([{_id:"n1",pk:NumberInt(1),tag:"ok"},{_id:"n2",pk:NumberInt(2)}]);
if (source.matrix_types.countDocuments({}) !== 1) quit(20);
if (source.matrix_overflow.countDocuments({}) !== 1) quit(21);
MONGOJS
}

create_external_tables() {
  mysql_raw "drop database if exists mongodb_matrix; create database mongodb_matrix; \
    create mongodb connection mongodb_matrix with ('hosts'='127.0.0.1:$MONGODB_PORT','replica_set'='rs0','auth_source'='mongodb_source','auth_mechanism'='SCRAM-SHA-256','credential_secret_ref'='secret://env/MO_MONGODB_E2E_CREDENTIAL','tls_mode'='disabled','read_preference'='primary','read_concern'='majority','options_json'='{\"direct\":true}'); \
    create external table mongodb_matrix.all_types( \
      mongo_id char(24) mongodb_path '_id', bool_v bool, i8 tinyint, i16 smallint, i32 int, i64 bigint, \
      u8 tinyint unsigned, u16 smallint unsigned, u32 int unsigned, u64 bigint unsigned, \
      f32 float, f64 double, d64 decimal(16,4), d128 decimal(34,4), d256 decimal(50,0), \
      date_v date, datetime_v datetime(3), timestamp_v timestamp(3), \
      char_v char(4), varchar_v varchar(16), text_v text, binary_v binary(4), \
      varbinary_v varbinary(4), blob_v blob, oid_char varchar(24) mongodb_path 'object_id_v', \
      oid_binary varbinary(12) mongodb_path 'object_id_v', json_doc json, json_arr json, json_oid json \
    ) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_types','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.null_try(id varchar(12) mongodb_path '_id', v int mongodb_convert 'try_null') \
      engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_nulls','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.null_strict(id varchar(12) mongodb_path '_id', v int) \
      engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_nulls','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.path_try(id varchar(16) mongodb_path '_id', nested_v int mongodb_path 'a.b.c' mongodb_convert 'try_null', case_v int mongodb_path 'A' mongodb_convert 'try_null') \
      engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_paths','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.path_strict(id varchar(16) mongodb_path '_id', nested_v int mongodb_path 'a.b.c') \
      engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_paths','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.string_exact(value varchar(3)) \
      engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_strings','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.string_short(value varchar(2) mongodb_convert 'try_null') \
      engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_strings','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.overflow_try(i8 tinyint mongodb_convert 'try_null', u8 tinyint unsigned mongodb_convert 'try_null', f32 float mongodb_convert 'try_null', decimal_v decimal(5,2) mongodb_convert 'try_null', datetime_v datetime mongodb_convert 'try_null') \
      engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_overflow','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.constraint_good(id varchar(4) mongodb_path '_id', pk int, uniq varchar(8), parent int, val int, tag varchar(8)) \
      engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='constraint_good','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.bad_pk(id varchar(4) mongodb_path '_id', pk int) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='bad_pk','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.bad_unique(id varchar(4) mongodb_path '_id', pk int, uniq varchar(8)) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='bad_unique','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.bad_fk(id varchar(4) mongodb_path '_id', pk int, parent int) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='bad_fk','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.bad_check(id varchar(4) mongodb_path '_id', pk int, val int) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='bad_check','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1'); \
    create external table mongodb_matrix.bad_notnull(id varchar(4) mongodb_path '_id', pk int, tag varchar(8)) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='bad_notnull','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1');"
}

run_type_matrix() {
  expect_scalar type-bool 1 "select cast(bool_v as char) from mongodb_matrix.all_types"
  expect_scalar type-signed-integers '-128|32767|-2147483648|9223372036854775807' "select concat_ws('|',i8,i16,i32,i64) from mongodb_matrix.all_types"
  expect_scalar type-unsigned-integers '255|65535|4294967295|9223372036854775807' "select concat_ws('|',u8,u16,u32,u64) from mongodb_matrix.all_types"
  expect_scalar type-float-double '3.5|-1.25' "select concat_ws('|',cast(f32 as char),cast(f64 as char)) from mongodb_matrix.all_types"
  expect_scalar type-decimal64 '123456789012.3456' "select cast(d64 as char) from mongodb_matrix.all_types"
  expect_scalar type-decimal128 '12345678901234567890.1234' "select cast(d128 as char) from mongodb_matrix.all_types"
  expect_scalar type-decimal256 '1234567890123456789012345678901234' "select cast(d256 as char) from mongodb_matrix.all_types"
  expect_scalar type-date '2026-09-08' "set time_zone='+00:00'; select cast(date_v as char) from mongodb_matrix.all_types"
  expect_scalar type-datetime '2026-09-08 12:34:56.789' "set time_zone='+00:00'; select cast(datetime_v as char) from mongodb_matrix.all_types"
  expect_scalar type-timestamp '2026-09-08 12:34:56.789' "set time_zone='+00:00'; select cast(timestamp_v as char) from mongodb_matrix.all_types"
  expect_scalar type-char 1 "select count(*) from mongodb_matrix.all_types where rtrim(char_v)='中A'"
  expect_scalar type-varchar 'hello🙂' "select varchar_v from mongodb_matrix.all_types"
  expect_scalar type-text 'text-value' "select text_v from mongodb_matrix.all_types"
  expect_scalar type-binary '01020000' "select hex(binary_v) from mongodb_matrix.all_types"
  expect_scalar type-varbinary '010203' "select hex(varbinary_v) from mongodb_matrix.all_types"
  expect_scalar type-blob '00FF80' "select hex(blob_v) from mongodb_matrix.all_types"
  expect_scalar type-objectid-char '64b000000000000000009999' "select oid_char from mongodb_matrix.all_types"
  expect_scalar type-objectid-binary '64B000000000000000009999' "select hex(oid_binary) from mongodb_matrix.all_types"
  expect_scalar type-json-document v "select json_unquote(json_extract(json_doc,'$.nested.k')) from mongodb_matrix.all_types"
  expect_scalar type-json-array 3 "select json_length(json_arr) from mongodb_matrix.all_types"
  expect_scalar type-json-bson-wrapper OBJECT "select json_type(json_oid) from mongodb_matrix.all_types"
}

run_null_and_source_constraints() {
  expect_scalar null-missing-undefined-try-null '4|7' "select concat(sum(v is null),'|',sum(coalesce(v,0))) from mongodb_matrix.null_try"
  expect_fail strict-conversion-rejected 'cannot be converted|conversion' "select count(*) from mongodb_matrix.null_strict"
  expect_scalar nested-path-and-case-sensitive '5|4|9' "select concat(sum(coalesce(nested_v,0)),'|',sum(nested_v is null),'|',sum(coalesce(case_v,0))) from mongodb_matrix.path_try"
  expect_fail nested-path-strict-invalid-parent 'cannot be converted|conversion' "select count(*) from mongodb_matrix.path_strict"
  expect_scalar unicode-width-counts-characters '中文🙂' "select value from mongodb_matrix.string_exact"
  expect_scalar unicode-width-overflow-try-null 1 "select count(*) from mongodb_matrix.string_short where value is null"
  expect_scalar scalar-overflow-try-null 5 "select cast(sum(i8 is null)+sum(u8 is null)+sum(f32 is null)+sum(decimal_v is null)+sum(datetime_v is null) as char) from mongodb_matrix.overflow_try"

  local options="engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_nulls','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1')"
  expect_ok source-default-null-allowed "create external table mongodb_matrix.src_default_null(id varchar(12) mongodb_path '_id', v int default null mongodb_convert 'try_null') $options"
  expect_scalar source-default-null-scan 4 "select count(*) from mongodb_matrix.src_default_null where v is null"
  expect_ok source-not-null-ddl-allowed "create external table mongodb_matrix.src_not_null(id varchar(12) mongodb_path '_id', v int not null mongodb_convert 'try_null') $options"
  expect_fail source-not-null-runtime 'cannot be null|not null' "select count(*) from mongodb_matrix.src_not_null"
  expect_fail source-nonnull-default-rejected 'default|not support|invalid' "create external table mongodb_matrix.src_bad_default(v int default 7) $options"
  expect_fail source-primary-key-rejected 'primary|constraint|not support|invalid' "create external table mongodb_matrix.src_bad_pk(v int primary key) $options"
  expect_fail source-unique-rejected 'unique|index|constraint|not support|invalid' "create external table mongodb_matrix.src_bad_unique(v int unique) $options"
  expect_fail source-index-rejected 'key|index|constraint|not support|invalid' "create external table mongodb_matrix.src_bad_index(v int, key idx_v(v)) $options"
  expect_fail source-check-rejected 'check|constraint|not support|invalid' "create external table mongodb_matrix.src_bad_check(v int check(v>0)) $options"
  expect_fail source-auto-increment-rejected 'auto_increment|not support|invalid' "create external table mongodb_matrix.src_bad_auto(v int auto_increment) $options"
  expect_ok source-fk-parent-setup "create table mongodb_matrix.local_parent(id int primary key)"
  expect_fail source-generated-rejected 'generated|not support|invalid' "create external table mongodb_matrix.src_bad_generated(v int, g int as (v+1) stored) $options"
  expect_fail source-foreign-key-rejected 'foreign|constraint|not support|invalid' "create external table mongodb_matrix.src_bad_fk(v int, foreign key(v) references mongodb_matrix.local_parent(id)) $options"
  expect_fail source-time-type-rejected 'type|support|invalid' "create external table mongodb_matrix.src_bad_time(v time) $options"
  expect_fail source-uuid-type-rejected 'type|support|invalid' "create external table mongodb_matrix.src_bad_uuid(v uuid) $options"
  expect_fail source-datalink-type-rejected 'type|support|invalid' "create external table mongodb_matrix.src_bad_datalink(v datalink) $options"
  expect_fail source-geometry-type-rejected 'type|support|invalid' "create external table mongodb_matrix.src_bad_geometry(v geometry) $options"
  expect_fail source-vector-type-rejected 'type|support|invalid' "create external table mongodb_matrix.src_bad_vector(v vecf32(3)) $options"
  expect_scalar source-rejected-ddl-no-catalog-residue 0 "select count(*) from mo_catalog.mo_tables where reldatabase='mongodb_matrix' and relname like 'src_bad_%'"

  expect_fail source-insert-read-only 'cannot insert|external table' "insert into mongodb_matrix.constraint_good values('x',9,'u9',1,1,'x')"
  expect_fail source-update-read-only 'cannot insert/update/delete|external table' "update mongodb_matrix.constraint_good set val=0"
  expect_fail source-delete-read-only 'cannot insert/update/delete|external table' "delete from mongodb_matrix.constraint_good"
  expect_fail source-replace-read-only 'cannot insert|external table' "replace into mongodb_matrix.constraint_good values('x',9,'u9',1,1,'x')"
  expect_fail source-truncate-read-only 'cannot insert/update/delete|external table' "truncate table mongodb_matrix.constraint_good"
  expect_scalar source-preserved-after-dml-rejection '2|30' "select concat(count(*),'|',sum(val)) from mongodb_matrix.constraint_good"
  expect_fail source-alter-schema-rejected 'alter|mongodb|external' "alter table mongodb_matrix.constraint_good add column extra int"
}

run_connection_and_mapping_boundaries() {
  expect_fail connection-missing-discovery-rejected 'hosts|srv|discovery|option|invalid' "create mongodb connection bad_missing"
  expect_fail connection-ambiguous-discovery-rejected 'hosts|srv|exactly|invalid' "create mongodb connection bad_both with ('hosts'='127.0.0.1:$MONGODB_PORT','srv_host'='mongo.example')"
  expect_fail connection-uri-userinfo-rejected 'hosts|uri|userinfo|invalid|seed' "create mongodb connection bad_uri with ('hosts'='mongodb://user:pass@127.0.0.1:$MONGODB_PORT','credential_secret_ref'='secret://env/MO_MONGODB_E2E_CREDENTIAL')"
  expect_fail connection-auth-mechanism-rejected 'auth|mechanism|invalid|support' "create mongodb connection bad_auth with ('hosts'='127.0.0.1:$MONGODB_PORT','auth_mechanism'='PLAIN','credential_secret_ref'='secret://env/MO_MONGODB_E2E_CREDENTIAL')"
  expect_fail connection-read-preference-rejected 'read.preference|invalid|support' "create mongodb connection bad_preference with ('hosts'='127.0.0.1:$MONGODB_PORT','read_preference'='nearestish','credential_secret_ref'='secret://env/MO_MONGODB_E2E_CREDENTIAL')"
  expect_fail connection-unknown-option-rejected 'unknown|option|invalid' "create mongodb connection bad_option with ('hosts'='127.0.0.1:$MONGODB_PORT','credential_secret_ref'='secret://env/MO_MONGODB_E2E_CREDENTIAL','mystery'='x')"
  expect_fail mapping-schema-mode-rejected 'schema.mode|explicit|invalid' "create external table mongodb_matrix.bad_schema(v int) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_types','schema_mode'='infer','conversion_mode'='strict','max_parallelism'='1')"
  expect_fail mapping-conversion-mode-rejected 'conversion.mode|invalid' "create external table mongodb_matrix.bad_conversion(v int) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_types','schema_mode'='explicit','conversion_mode'='lenient','max_parallelism'='1')"
  expect_fail mapping-parallelism-rejected 'parallel|must be 1|invalid' "create external table mongodb_matrix.bad_parallel(v int) engine=mongodb with ('connection'='mongodb_matrix','database'='mongodb_source','collection'='matrix_types','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='2')"
  expect_fail connection-drop-with-dependency-rejected 'depend|referenc|table|use' "drop mongodb connection mongodb_matrix"

  expect_ok connection-missing-secret-ddl "create mongodb connection missing_secret with ('hosts'='127.0.0.1:$MONGODB_PORT','replica_set'='rs0','auth_source'='mongodb_source','auth_mechanism'='SCRAM-SHA-256','credential_secret_ref'='secret://env/MO_MONGODB_NOT_DEFINED','tls_mode'='disabled','read_preference'='primary','read_concern'='majority','options_json'='{\"direct\":true}'); create external table mongodb_matrix.missing_secret_table(v int) engine=mongodb with ('connection'='missing_secret','database'='mongodb_source','collection'='matrix_types','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1')"
  expect_fail connection-missing-secret-runtime 'secret|credential|resolve|not set|missing' "select count(*) from mongodb_matrix.missing_secret_table"
  expect_ok connection-missing-secret-cleanup "drop table mongodb_matrix.missing_secret_table; drop mongodb connection missing_secret"
  expect_scalar connection-invalid-ddl-no-catalog-residue 0 "select count(*) from mo_catalog.mo_mongodb_connections where account_id=0 and name like 'bad_%'"
}

run_table_interop_and_target_constraints() {
  expect_ok target-parent-setup "insert into mongodb_matrix.local_parent values(1),(2)"
  expect_ok table-permanent-target "create table mongodb_matrix.permanent_target(pk int primary key, val int); insert into mongodb_matrix.permanent_target select pk,val from mongodb_matrix.constraint_good"
  expect_scalar table-permanent-join '1|10|a' "select concat(p.pk,'|',p.val,'|',m.tag) from mongodb_matrix.permanent_target p join mongodb_matrix.constraint_good m on p.pk=m.pk where p.pk=1"
  expect_ok table-view-create "create view mongodb_matrix.mongo_view as select pk,val,tag from mongodb_matrix.constraint_good where val>=10"
  expect_scalar table-view-scan '2|30' "select concat(count(*),'|',sum(val)) from mongodb_matrix.mongo_view"
  expect_ok table-ctas "create table mongodb_matrix.ctas_target as select pk,val,tag from mongodb_matrix.constraint_good"
  expect_scalar table-ctas-result '2|30' "select concat(count(*),'|',sum(val)) from mongodb_matrix.ctas_target"
  expect_ok table-partition-target "create table mongodb_matrix.partition_target(pk int primary key, val int) partition by key(pk) partitions 2; insert into mongodb_matrix.partition_target select pk,val from mongodb_matrix.constraint_good"
  expect_scalar table-partition-result '2|30' "select concat(count(*),'|',sum(val)) from mongodb_matrix.partition_target"
  expect_ok table-temporary-target "create temporary table mongodb_matrix.temp_target(pk int primary key, val int); insert into mongodb_matrix.temp_target select pk,val from mongodb_matrix.constraint_good; select count(*) from mongodb_matrix.temp_target"
  expect_fail table-temporary-session-isolation 'doesn.t exist|not exist|unknown table' "select count(*) from mongodb_matrix.temp_target"
  expect_fail table-cluster-target-user-rejected 'privilege' "create cluster table mongodb_matrix.cluster_target(pk int, val int)"
  expect_ok table-file-external-create "create external table mongodb_matrix.file_external(pk int, label varchar(16)) infile{\"filepath\"='$CSV_FILE'} fields terminated by '|' lines terminated by '\\n'"
  expect_scalar table-file-external-join '2|3' "select concat(count(*),'|',sum(m.pk)) from mongodb_matrix.constraint_good m join mongodb_matrix.file_external f on m.pk=f.pk"

  expect_ok target-default "create table mongodb_matrix.default_target(pk int primary key, val int default 7); insert into mongodb_matrix.default_target(pk) select pk from mongodb_matrix.constraint_good"
  expect_scalar target-default-result '2|14' "select concat(count(*),'|',sum(val)) from mongodb_matrix.default_target"
  expect_ok target-auto-generated-index "create table mongodb_matrix.rich_target(id bigint unsigned auto_increment primary key, pk int unique, val int not null, gen int as (val*2) stored, tag varchar(8), index idx_tag(tag)); insert into mongodb_matrix.rich_target(pk,val,tag) select pk,val,tag from mongodb_matrix.constraint_good"
  expect_scalar target-auto-generated-result '2|1|2|60' "select concat(count(*),'|',min(id),'|',max(id),'|',sum(gen)) from mongodb_matrix.rich_target"
  expect_ok target-cluster-by "create table mongodb_matrix.cluster_by_target(pk int, val int) cluster by(pk); insert into mongodb_matrix.cluster_by_target select pk,val from mongodb_matrix.constraint_good"
  expect_scalar target-cluster-by-result '2|30' "select concat(count(*),'|',sum(val)) from mongodb_matrix.cluster_by_target"

  expect_ok target-pk-setup "create table mongodb_matrix.pk_target(pk int primary key)"
  expect_fail target-pk-atomic-reject 'duplicate' "insert into mongodb_matrix.pk_target select pk from mongodb_matrix.bad_pk"
  expect_scalar target-pk-rollback 0 "select count(*) from mongodb_matrix.pk_target"
  expect_ok target-unique-setup "create table mongodb_matrix.unique_target(pk int primary key, uniq varchar(8) unique)"
  expect_fail target-unique-atomic-reject 'duplicate' "insert into mongodb_matrix.unique_target select pk,uniq from mongodb_matrix.bad_unique"
  expect_scalar target-unique-rollback 0 "select count(*) from mongodb_matrix.unique_target"
  expect_ok target-fk-setup "create table mongodb_matrix.fk_target(pk int primary key, parent int, foreign key(parent) references mongodb_matrix.local_parent(id))"
  expect_fail target-fk-atomic-reject 'foreign|constraint' "set foreign_key_checks=1; insert into mongodb_matrix.fk_target select pk,parent from mongodb_matrix.bad_fk"
  expect_scalar target-fk-rollback 0 "select count(*) from mongodb_matrix.fk_target"
  expect_ok target-check-setup "create table mongodb_matrix.check_target(pk int primary key, val int, check(val>0))"
  expect_fail target-check-atomic-reject 'check|constraint' "insert into mongodb_matrix.check_target select pk,val from mongodb_matrix.bad_check"
  expect_scalar target-check-rollback 0 "select count(*) from mongodb_matrix.check_target"
  expect_ok target-notnull-setup "create table mongodb_matrix.notnull_target(pk int primary key, tag varchar(8) not null)"
  expect_fail target-notnull-atomic-reject 'cannot be null|not null' "insert into mongodb_matrix.notnull_target select pk,tag from mongodb_matrix.bad_notnull"
  expect_scalar target-notnull-rollback 0 "select count(*) from mongodb_matrix.notnull_target"

  expect_ok target-replace-setup "create table mongodb_matrix.replace_target(pk int primary key, val int); insert into mongodb_matrix.replace_target values(1,-1); replace into mongodb_matrix.replace_target select pk,val from mongodb_matrix.constraint_good"
  expect_scalar target-replace-result '2|30' "select concat(count(*),'|',sum(val)) from mongodb_matrix.replace_target"
}

run_query_matrix() {
  local filter_query='{"filter":{"site_id":"site-west"}}'
  local sort_query='{"pipeline":[{"$sort":{"site_id":1}}]}'
  local unwind_query='{"pipeline":[{"$unwind":"$site_id"}]}'
  local i
  for i in 1 2 3; do
    expect_scalar "issue-28333-residual-measurement-run-$i" 1 "select count(*) from mongodb_ci.events where __mo_query='$filter_query' and measurement>0"
    expect_scalar "issue-28333-residual-site-run-$i" 1 "select count(*) from mongodb_ci.events where __mo_query='$filter_query' and site_id='site-west'"
    expect_scalar "issue-28333-projection-run-$i" device-001 "select device_id from mongodb_ci.events where __mo_query='$filter_query' and measurement>0"
    expect_scalar "issue-28333-order-limit-run-$i" device-001 "select device_id from mongodb_ci.events where __mo_query='$filter_query' order by ts limit 1"
    expect_scalar "issue-28337-sort-run-$i" 5 "select count(*) from mongodb_ci.events where __mo_query='$sort_query'"
    expect_scalar "issue-28337-unwind-run-$i" 5 "select count(*) from mongodb_ci.events where __mo_query='$unwind_query'"
  done

  expect_scalar query-cte '2|30' "with m as (select pk,val from mongodb_matrix.constraint_good) select concat(count(*),'|',sum(val)) from m"
  expect_scalar query-derived-subquery 20 "select max(val) from (select val from mongodb_matrix.constraint_good where pk>0) x"
  expect_scalar query-union-all 4 "select count(*) from (select pk from mongodb_matrix.constraint_good union all select pk from mongodb_matrix.constraint_good) x"
  expect_scalar query-group-having '2|15.0000' "select concat(count(*),'|',avg(val)) from mongodb_matrix.constraint_good having count(*)=2"
  expect_scalar query-window '1|10|10;2|20|30' "select group_concat(concat(pk,'|',val,'|',running) order by pk separator ';') from (select pk,val,sum(val) over(order by pk) running from mongodb_matrix.constraint_good) x"

  local sort32 sort33 unwind199 unwind200 stages16 stages17 depth33 oversized
  sort32="$(python3 - <<'PY'
import json
print(json.dumps({"pipeline":[{"$sort":{f"f{i}":1 for i in range(32)}}]}, separators=(",",":")))
PY
)"
  sort33="$(python3 - <<'PY'
import json
print(json.dumps({"pipeline":[{"$sort":{f"f{i}":1 for i in range(33)}}]}, separators=(",",":")))
PY
)"
  unwind199="$(python3 - <<'PY'
import json
print(json.dumps({"pipeline":[{"$unwind":"$"+".".join(["a"]*199)}]}, separators=(",",":")))
PY
)"
  unwind200="$(python3 - <<'PY'
import json
print(json.dumps({"pipeline":[{"$unwind":"$"+".".join(["a"]*200)}]}, separators=(",",":")))
PY
)"
  stages16="$(python3 - <<'PY'
import json
print(json.dumps({"pipeline":[{"$limit":1} for _ in range(16)]}, separators=(",",":")))
PY
)"
  stages17="$(python3 - <<'PY'
import json
print(json.dumps({"pipeline":[{"$limit":1} for _ in range(17)]}, separators=(",",":")))
PY
)"
  depth33="$(python3 - <<'PY'
import json
value = 1
for i in range(33): value = {f"a{i}": value}
print(json.dumps({"filter":value}, separators=(",",":")))
PY
)"
  oversized="$(python3 - <<'PY'
import json
print(json.dumps({"filter":{"padding":"x"*65536}}, separators=(",",":")))
PY
)"
  expect_scalar query-sort-32-fields-valid 5 "select count(*) from mongodb_ci.events where __mo_query='$sort32'"
  expect_fail query-sort-33-fields-rejected 'sort requires 1 to 32 fields|32 fields' "select count(*) from mongodb_ci.events where __mo_query='$sort33'"
  expect_scalar query-unwind-199-segments-valid 0 "select count(*) from mongodb_ci.events where __mo_query='$unwind199'"
  expect_fail query-unwind-200-segments-rejected 'field path|199|invalid' "select count(*) from mongodb_ci.events where __mo_query='$unwind200'"
  expect_scalar query-16-stages-valid 1 "select count(*) from mongodb_ci.events where __mo_query='$stages16'"
  expect_fail query-17-stages-rejected 'too many|16|stage' "select count(*) from mongodb_ci.events where __mo_query='$stages17'"
  expect_fail query-depth-33-rejected 'nesting|depth|32|strict Extended JSON' "select count(*) from mongodb_ci.events where __mo_query='$depth33'"
  expect_fail query-over-64k-rejected 'large|65536|64|size limit' "select count(*) from mongodb_ci.events where __mo_query='$oversized'"
  expect_fail query-write-stage-rejected 'not allowed' 'select count(*) from mongodb_ci.events where __mo_query='"'"'{"pipeline":[{"$out":"x"}]}'"'"''
  expect_fail query-cross-collection-rejected 'not allowed' 'select count(*) from mongodb_ci.events where __mo_query='"'"'{"pipeline":[{"$lookup":{"from":"events","as":"x","pipeline":[]}}]}'"'"''
  expect_scalar query-baseline-after-boundaries '5|74' "select concat(count(*),'|',sum(coalesce(measurement,0))) from mongodb_ci.events"
}

run_transactions_concurrency_tenants() {
  expect_scalar transaction-scan-commit 2 "begin; select count(*) from mongodb_matrix.constraint_good; commit"
  expect_scalar transaction-scan-rollback 2 "begin; select count(*) from mongodb_matrix.constraint_good; rollback"
  expect_scalar transaction-target-rollback 0 "create table mongodb_matrix.tx_rollback(pk int primary key,val int); begin; insert into mongodb_matrix.tx_rollback select pk,val from mongodb_matrix.constraint_good; rollback; select count(*) from mongodb_matrix.tx_rollback"
  expect_scalar transaction-target-commit 2 "create table mongodb_matrix.tx_commit(pk int primary key,val int); begin; insert into mongodb_matrix.tx_commit select pk,val from mongodb_matrix.constraint_good; commit; select count(*) from mongodb_matrix.tx_commit"

  local concurrent_dir rc=0 i
  concurrent_dir="$(mktemp -d "${TMPDIR:-/private/tmp}/mo-mongodb-concurrent.XXXXXX")"
  for i in $(seq 1 10); do
    (mysql_raw "select concat(count(*),'|',sum(val)) from mongodb_matrix.constraint_good" >"$concurrent_dir/$i.out") &
  done
  wait || rc=$?
  if (( rc == 0 )) && [[ "$(find "$concurrent_dir" -name '*.out' -type f -exec cat {} \; | grep -cx '2|30')" == 10 ]]; then
    record concurrency-10-readers PASS '10/10 exact results'
  else
    record concurrency-10-readers FAIL "background status=$rc outputs=$(find "$concurrent_dir" -name '*.out' -type f -exec tr '\n' ',' <{} \;)"
  fi
  find "$concurrent_dir" -type f -name '*.out' -delete
  rmdir "$concurrent_dir"

  expect_ok tenant-create "drop account if exists mongodb_tenant_a; drop account if exists mongodb_tenant_b; create account mongodb_tenant_a admin_name='root' identified by '111'; create account mongodb_tenant_b admin_name='root' identified by '111'"
  local tenant_a_id tenant_b_id tenant_setup_a tenant_setup_b out status
  tenant_a_id="$(mysql_raw "select account_id from mo_catalog.mo_account where account_name='mongodb_tenant_a'")"
  tenant_b_id="$(mysql_raw "select account_id from mo_catalog.mo_account where account_name='mongodb_tenant_b'")"
  tenant_setup_a="create database mongodb_tenant; create mongodb connection shared_name with ('hosts'='127.0.0.1:$MONGODB_PORT','replica_set'='rs0','auth_source'='mongodb_source','auth_mechanism'='SCRAM-SHA-256','credential_secret_ref'='secret://env/MO_MONGODB_ACCOUNT_${tenant_a_id}_E2E_CREDENTIAL','tls_mode'='disabled','read_preference'='primary','read_concern'='majority','options_json'='{\"direct\":true}'); create external table mongodb_tenant.events(id varchar(4) mongodb_path '_id',pk int,val int) engine=mongodb with ('connection'='shared_name','database'='mongodb_source','collection'='constraint_good','schema_mode'='explicit','conversion_mode'='strict','max_parallelism'='1')"
  tenant_setup_b="${tenant_setup_a//ACCOUNT_${tenant_a_id}/ACCOUNT_${tenant_b_id}}"
  out="$(mysql_raw_as 'mongodb_tenant_a:root' 111 "$tenant_setup_a")"; status=$?
  if (( status == 0 )); then record tenant-a-same-name-ddl PASS ok; else record tenant-a-same-name-ddl FAIL "$(<"$STDERR_FILE")"; fi
  out="$(mysql_raw_as 'mongodb_tenant_b:root' 111 "$tenant_setup_b")"; status=$?
  if (( status == 0 )); then record tenant-b-same-name-ddl PASS ok; else record tenant-b-same-name-ddl FAIL "$(<"$STDERR_FILE")"; fi
  expect_scalar_as tenant-a-scan 'mongodb_tenant_a:root' 111 '2|30' "select concat(count(*),'|',sum(val)) from mongodb_tenant.events"
  expect_scalar_as tenant-b-scan 'mongodb_tenant_b:root' 111 '2|30' "select concat(count(*),'|',sum(val)) from mongodb_tenant.events"
  expect_scalar tenant-system-catalog-isolation '2|2|0' "select concat(count(*),'|',count(distinct account_id),'|',sum(account_id=0)) from mo_catalog.mo_tables where reldatabase='mongodb_tenant' and relname='events'"
}

run_observability() {
  local before after open_count close_count checked_out pipeline
  before="$(metric_value mo_mongodb_conversion_errors_total)"
  expect_scalar observability-try-null-query 4 "select count(*) from mongodb_matrix.null_try where v is null"
  after="$(metric_value mo_mongodb_conversion_errors_total)"
  if awk -v before="$before" -v after="$after" 'BEGIN {exit !(after > before)}'; then
    record observability-try-null-conversion-metric PASS "before=$before after=$after"
  else
    record observability-try-null-conversion-metric FAIL "before=$before after=$after"
  fi

  before="$(metric_value mo_mongodb_conversion_errors_total)"
  pipeline='{"pipeline":[{"$project":{"_id":0,"device_id":1,"event_count":{"$literal":"bad"},"avg_measurement":{"$literal":1.5}}}]}'
  expect_fail issue-28341-strict-conversion-query 'cannot be converted|conversion' "select device_id,event_count,avg_measurement from mongodb_ci.events_aggregate where __mo_query='$pipeline'"
  after="$(metric_value mo_mongodb_conversion_errors_total)"
  if awk -v before="$before" -v after="$after" 'BEGIN {exit !(after > before)}'; then
    record issue-28341-strict-conversion-metric PASS "before=$before after=$after"
  else
    record issue-28341-strict-conversion-metric FAIL "metric unchanged before=$before after=$after"
  fi

  open_count="$(metric_value 'mo_mongodb_cursor_events_total{event="open"}')"
  close_count="$(metric_value 'mo_mongodb_cursor_events_total{event="close"}')"
  checked_out="$(metric_value mo_mongodb_pool_checked_out_connections)"
  if [[ "$open_count" == "$close_count" && "$checked_out" == 0 ]]; then
    record observability-cursor-pool-cleanup PASS "open=$open_count close=$close_count checked_out=$checked_out"
  else
    record observability-cursor-pool-cleanup FAIL "open=$open_count close=$close_count checked_out=$checked_out"
  fi
}

if seed_mongodb; then
  record seed-mongodb PASS ok
else
  record seed-mongodb FAIL 'MongoDB fixture seeding failed'
fi
if create_external_tables; then
  record matrix-setup PASS ok
else
  record matrix-setup FAIL "$(<"$STDERR_FILE")"
fi

run_type_matrix
run_null_and_source_constraints
run_connection_and_mapping_boundaries
run_table_interop_and_target_constraints
run_query_matrix
run_transactions_concurrency_tenants
run_observability

expect_ok cleanup-sql "drop account if exists mongodb_tenant_a; drop account if exists mongodb_tenant_b; drop database if exists mongodb_matrix; drop mongodb connection if exists mongodb_matrix"

python3 - "$CASE_FILE" "$SUMMARY_FILE" "$passes" "$failures" <<'PY'
import csv
import json
import sys

case_file, summary_file, passes, failures = sys.argv[1:]
with open(case_file, newline="", encoding="utf-8") as source:
    cases = list(csv.DictReader(source, delimiter="\t"))
summary = {
    "status": "passed" if int(failures) == 0 else "failed",
    "passed": int(passes),
    "failed": int(failures),
    "cases": cases,
}
with open(summary_file, "w", encoding="utf-8") as target:
    json.dump(summary, target, ensure_ascii=False, indent=2)
    target.write("\n")
PY

printf '[local-matrix] completed: passed=%d failed=%d\n' "$passes" "$failures"
(( failures == 0 ))
