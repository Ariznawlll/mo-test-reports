#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify MatrixOne checkpoint dump fixes for:
  #25030 RANGE/LIST partition restore.sql
  #25024 view restore as CREATE VIEW
  #25015 mixed data types and constraints regression

The script runs the three focused verifiers independently, keeps every artifact
under /data4, and writes a top-level summary.tsv.

Usage:
  ./verify_25015_25024_25030.sh [options]

Options:
  --host HOST                     MatrixOne MySQL host. Default: 127.0.0.1
  --port PORT                     MatrixOne MySQL port. Default: 6001
  --source-user USER              Source tenant user. Default: dump
  --source-password PASS          Source tenant password. Default: 111
  --target-user USER              Target tenant user. Default: acc01:test_account
  --target-password PASS          Target tenant password. Default: 111
  --db-prefix PREFIX              Coverage database prefix. Default: ckp
  --scale N                       Coverage scale rows. Default: 10000
  --mo-tool PATH                  mo-tool path. Default: /data4/weilu/matrixone/mo-tool
  --ckp-data PATH                 Checkpoint data path.
  --out DIR                       Output dir. Default: /data4/weilu/verify_25015_25024_25030_<timestamp>
  --mysql-bin PATH                mysql client path. Default: mysql
  --wait-seconds N                Max wait for checkpoint metadata. Default: 600
  --poll-seconds N                Poll interval. Default: 10
  --data-compare-max-rows N       Full data compare threshold for #25015. Default: 20000
  --scripts-dir DIR               Directory containing verifier scripts. Default: script location
  --drop-existing                 Drop source/target test databases in subtests.
  --only LIST                     Comma list: 25030,25024,25015. Default: all.
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
MO_TOOL="/data4/weilu/matrixone/mo-tool"
CKP_DATA="/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared"
OUT="/data4/weilu/verify_25015_25024_25030_${TS}"
MYSQL_BIN="mysql"
WAIT_SECONDS="600"
POLL_SECONDS="10"
DATA_COMPARE_MAX_ROWS="20000"
SCRIPTS_DIR="$SCRIPT_DIR"
DROP_EXISTING="0"
ONLY="25030,25024,25015"

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
    --wait-seconds) WAIT_SECONDS="$2"; shift 2 ;;
    --poll-seconds) POLL_SECONDS="$2"; shift 2 ;;
    --data-compare-max-rows) DATA_COMPARE_MAX_ROWS="$2"; shift 2 ;;
    --scripts-dir) SCRIPTS_DIR="$2"; shift 2 ;;
    --drop-existing) DROP_EXISTING="1"; shift ;;
    --only) ONLY="$2"; shift 2 ;;
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
if [[ ! -d "$SCRIPTS_DIR" ]]; then
  echo "scripts dir not found: $SCRIPTS_DIR" >&2
  exit 2
fi

PARTITION_SCRIPT="$SCRIPTS_DIR/verify_partition_options_dump_restore.sh"
VIEWS_SCRIPT="$SCRIPTS_DIR/verify_views.sh"
REGRESSION_SCRIPT="$SCRIPTS_DIR/run_checkpoint_dump_regression.sh"
PREPARE_SCRIPT="$SCRIPTS_DIR/prepare_ckp_dump_coverage_data.sh"

for script in "$PARTITION_SCRIPT" "$VIEWS_SCRIPT" "$REGRESSION_SCRIPT" "$PREPARE_SCRIPT"; do
  if [[ ! -x "$script" ]]; then
    echo "required script not found or not executable: $script" >&2
    exit 2
  fi
done

mkdir -p "$OUT/logs"
SUMMARY="$OUT/summary.tsv"
printf "issue\tname\tstatus\texit_code\tartifact\tlog\tmarker\n" > "$SUMMARY"

echo "OUT=$OUT"
echo "SCRIPTS_DIR=$SCRIPTS_DIR"
echo "MO_TOOL=$MO_TOOL"
echo "CKP_DATA=$CKP_DATA"

contains_case() {
  local needle="$1"
  case ",$ONLY," in
    *",$needle,"*) return 0 ;;
    *) return 1 ;;
  esac
}

extract_out() {
  local log_file="$1"
  awk -F= '/^OUT=/{print $2; exit}' "$log_file"
}

append_result() {
  local issue="$1"
  local name="$2"
  local status="$3"
  local rc="$4"
  local artifact="$5"
  local log_file="$6"
  local marker="$7"
  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$issue" "$name" "$status" "$rc" "$artifact" "$log_file" "$marker" >> "$SUMMARY"
}

run_case() {
  local issue="$1"
  local name="$2"
  local marker="$3"
  local log_file="$4"
  shift 4

  echo "==> Run $issue $name"
  set +e
  "$@" 2>&1 | tee "$log_file"
  local rc=${PIPESTATUS[0]}
  set -e

  local artifact
  artifact="$(extract_out "$log_file")"
  if [[ -z "$artifact" ]]; then
    artifact="-"
  fi

  local status="FAIL"
  if [[ "$rc" -eq 0 ]] && grep -q "$marker" "$log_file"; then
    status="OK"
  fi
  append_result "$issue" "$name" "$status" "$rc" "$artifact" "$log_file" "$marker"
  return 0
}

drop_flag=()
if [[ "$DROP_EXISTING" == "1" ]]; then
  drop_flag=(--drop-existing)
fi

if contains_case "25030"; then
  run_case \
    "#25030" \
    "partition_options" \
    "PARTITION_OPTIONS_DUMP_RESTORE_OK" \
    "$OUT/logs/25030_partition_options.log" \
    "$PARTITION_SCRIPT" \
      --host "$HOST" \
      --port "$PORT" \
      --source-user "$SOURCE_USER" \
      --source-password "$SOURCE_PASSWORD" \
      --target-user "$TARGET_USER" \
      --target-password "$TARGET_PASSWORD" \
      --mo-tool "$MO_TOOL" \
      --ckp-data "$CKP_DATA" \
      --out "$OUT/25030_partition_options" \
      --mysql-bin "$MYSQL_BIN" \
      --wait-seconds "$WAIT_SECONDS" \
      --poll-seconds "$POLL_SECONDS" \
      "${drop_flag[@]}"
fi

if contains_case "25024"; then
  run_case \
    "#25024" \
    "views" \
    "CHECKPOINT_VIEW_DUMP_OK" \
    "$OUT/logs/25024_views.log" \
    "$VIEWS_SCRIPT" \
      --host "$HOST" \
      --port "$PORT" \
      --source-user "$SOURCE_USER" \
      --source-password "$SOURCE_PASSWORD" \
      --target-user "$TARGET_USER" \
      --target-password "$TARGET_PASSWORD" \
      --db-prefix "$DB_PREFIX" \
      --scale "$SCALE" \
      --mo-tool "$MO_TOOL" \
      --ckp-data "$CKP_DATA" \
      --out "$OUT/25024_views" \
      --mysql-bin "$MYSQL_BIN" \
      --prepare-script "$PREPARE_SCRIPT" \
      --wait-seconds "$WAIT_SECONDS" \
      --poll-seconds "$POLL_SECONDS" \
      "${drop_flag[@]}"
fi

if contains_case "25015"; then
  run_case \
    "#25015" \
    "mixed_types_constraints" \
    "CHECKPOINT_DUMP_REGRESSION_OK" \
    "$OUT/logs/25015_regression.log" \
    "$REGRESSION_SCRIPT" \
      --host "$HOST" \
      --port "$PORT" \
      --source-user "$SOURCE_USER" \
      --source-password "$SOURCE_PASSWORD" \
      --target-user "$TARGET_USER" \
      --target-password "$TARGET_PASSWORD" \
      --db-prefix "$DB_PREFIX" \
      --scale "$SCALE" \
      --mo-tool "$MO_TOOL" \
      --ckp-data "$CKP_DATA" \
      --out "$OUT/25015_regression" \
      --mysql-bin "$MYSQL_BIN" \
      --prepare-script "$PREPARE_SCRIPT" \
      --wait-seconds "$WAIT_SECONDS" \
      --poll-seconds "$POLL_SECONDS" \
      --data-compare-max-rows "$DATA_COMPARE_MAX_ROWS" \
      "${drop_flag[@]}"
fi

echo "==> Summary"
cat "$SUMMARY"

if awk -F'\t' 'NR > 1 && $3 != "OK" {bad=1} END {exit bad ? 0 : 1}' "$SUMMARY"; then
  echo "VERIFY_ISSUES_FAIL: at least one issue still fails. Artifacts: $OUT"
  exit 1
fi

echo "VERIFY_ISSUES_OK: #25030, #25024, #25015 checks passed. Artifacts: $OUT"
