#!/usr/bin/env bash
set -Eeuo pipefail

usage() {
  cat <<'USAGE'
Verify issue #24957 tpch_100g.part S3 dump data against a loaded tenant table.

The script downloads the dumped part CSV from COS/S3, computes CSV-side metrics,
queries the same metrics from the MatrixOne tenant, compares them, and checks a
small exact row sample.

Usage:
  ./verify_issue24957_part_consistency.sh [options]

Required:
  --host HOST                 MatrixOne MySQL host
  --user USER                 MatrixOne tenant user, e.g. acc01:test_account
  --password PASSWORD         MatrixOne password
  --out-prefix PREFIX         S3 key prefix used by ckp dump, without trailing /part

S3/COS options:
  --out-s3-args ARGS          Same args used by mo-tool --out-s3. Used to parse bucket,
                              endpoint, key-id, and key-secret.
  --bucket BUCKET             Output bucket. Overrides --out-s3-args bucket.
  --endpoint ENDPOINT         COS/S3 endpoint. Overrides --out-s3-args endpoint.
  --secret-id SECRET_ID       COS/S3 secret id. Overrides --out-s3-args key-id.
  --secret-key SECRET_KEY     COS/S3 secret key. Overrides --out-s3-args key-secret.
  --csv-local FILE            Use an existing local CSV and skip download if it exists.

Other options:
  --port PORT                 MatrixOne MySQL port, default: 6001
  --database DB               Target database, default: tpch_100g
  --table TABLE               Target table, default: part
  --db-id ID                  Source checkpoint database id, default: 272585
  --table-id ID               Source checkpoint table id, default: 272589
  --work-dir DIR              Work dir, default: /tmp/issue24957_verify_<timestamp>
  --coscli PATH               coscli path, default: coscli
  --mysql-bin PATH            mysql path, default: mysql
  --help                      Show this help

Example:
  ./verify_issue24957_part_consistency.sh \
    --host 172.16.43.103 \
    --user 'acc01:test_account' \
    --password 111 \
    --out-s3-args "$OUT_S3_ARGS" \
    --out-prefix "$OUT_PREFIX"
USAGE
}

HOST=""
PORT="6001"
USER=""
PASSWORD=""
OUT_S3_ARGS="${OUT_S3_ARGS:-}"
OUT_PREFIX="${OUT_PREFIX:-}"
BUCKET=""
ENDPOINT=""
SECRET_ID=""
SECRET_KEY=""
DATABASE="tpch_100g"
TABLE="part"
DB_ID="272585"
TABLE_ID="272589"
TS="$(date +%Y%m%d_%H%M%S)"
WORK_DIR="/tmp/issue24957_verify_${TS}"
CSV_LOCAL=""
COSCLI="coscli"
MYSQL_BIN="mysql"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --host) HOST="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --user) USER="$2"; shift 2 ;;
    --password) PASSWORD="$2"; shift 2 ;;
    --out-s3-args) OUT_S3_ARGS="$2"; shift 2 ;;
    --out-prefix) OUT_PREFIX="$2"; shift 2 ;;
    --bucket) BUCKET="$2"; shift 2 ;;
    --endpoint) ENDPOINT="$2"; shift 2 ;;
    --secret-id) SECRET_ID="$2"; shift 2 ;;
    --secret-key) SECRET_KEY="$2"; shift 2 ;;
    --database) DATABASE="$2"; shift 2 ;;
    --table) TABLE="$2"; shift 2 ;;
    --db-id) DB_ID="$2"; shift 2 ;;
    --table-id) TABLE_ID="$2"; shift 2 ;;
    --work-dir) WORK_DIR="$2"; shift 2 ;;
    --csv-local) CSV_LOCAL="$2"; shift 2 ;;
    --coscli) COSCLI="$2"; shift 2 ;;
    --mysql-bin) MYSQL_BIN="$2"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
  esac
done

parse_s3_arg() {
  local key="$1"
  if [[ -z "$OUT_S3_ARGS" ]]; then
    return 0
  fi
  printf '%s' "$OUT_S3_ARGS" | tr ',' '\n' | awk -F= -v k="$key" '$1 == k {print substr($0, length($1) + 2); exit}'
}

if [[ -z "$BUCKET" ]]; then BUCKET="$(parse_s3_arg bucket)"; fi
if [[ -z "$ENDPOINT" ]]; then ENDPOINT="$(parse_s3_arg endpoint)"; fi
if [[ -z "$SECRET_ID" ]]; then SECRET_ID="$(parse_s3_arg key-id)"; fi
if [[ -z "$SECRET_KEY" ]]; then SECRET_KEY="$(parse_s3_arg key-secret)"; fi

if [[ -z "$HOST" || -z "$USER" || -z "$PASSWORD" || -z "$OUT_PREFIX" ]]; then
  echo "--host, --user, --password, and --out-prefix are required" >&2
  usage
  exit 2
fi
if [[ -z "$BUCKET" ]]; then
  echo "bucket is required, pass --bucket or include bucket=... in --out-s3-args" >&2
  exit 2
fi

OUT_PREFIX="${OUT_PREFIX%/}"
mkdir -p "$WORK_DIR"

CSV_KEY="$OUT_PREFIX/part/account_0/db_${DB_ID}/${TABLE}_${TABLE_ID}.csv"
if [[ -z "$CSV_LOCAL" ]]; then
  CSV_LOCAL="$WORK_DIR/${TABLE}_${TABLE_ID}.csv"
fi

TARGET_METRICS="$WORK_DIR/target_metrics.tsv"
CSV_METRICS="$WORK_DIR/csv_metrics.tsv"
TARGET_SAMPLE="$WORK_DIR/target_sample.tsv"
CSV_SAMPLE="$WORK_DIR/csv_sample.tsv"
SUMMARY="$WORK_DIR/summary.txt"

mysql_args=(
  -h"$HOST"
  -P"$PORT"
  -u"$USER"
  --default-character-set=utf8mb4
  --batch
  --raw
  --skip-column-names
)

echo "==> Work dir: $WORK_DIR"
echo "==> CSV object: cos://$BUCKET/$CSV_KEY"
echo "==> Target table: $USER@$HOST:$PORT $DATABASE.$TABLE"

if [[ -f "$CSV_LOCAL" ]]; then
  echo "==> Reusing local CSV: $CSV_LOCAL"
else
  echo "==> Downloading CSV to $CSV_LOCAL"
  cos_args=()
  if [[ -n "$ENDPOINT" ]]; then cos_args+=(-e "$ENDPOINT"); fi
  if [[ -n "$SECRET_ID" ]]; then cos_args+=(-i "$SECRET_ID"); fi
  if [[ -n "$SECRET_KEY" ]]; then cos_args+=(-k "$SECRET_KEY"); fi
  "$COSCLI" cp "cos://$BUCKET/$CSV_KEY" "$CSV_LOCAL" "${cos_args[@]}"
fi

echo "==> Querying tenant-side metrics"
MYSQL_PWD="$PASSWORD" "$MYSQL_BIN" "${mysql_args[@]}" -e "
SELECT
  COUNT(*) AS row_count,
  MIN(P_PARTKEY) AS min_key,
  MAX(P_PARTKEY) AS max_key,
  SUM(P_PARTKEY) AS sum_key,
  SUM(P_SIZE) AS sum_size,
  CAST(SUM(P_RETAILPRICE) AS DECIMAL(30,2)) AS sum_price,
  SUM(LENGTH(P_NAME)) AS sum_name_len,
  SUM(LENGTH(P_COMMENT)) AS sum_comment_len,
  COUNT(DISTINCT P_PARTKEY) AS distinct_key
FROM \`${DATABASE}\`.\`${TABLE}\`;
" > "$TARGET_METRICS"

echo "==> Computing CSV-side metrics"
python3 - "$CSV_LOCAL" > "$CSV_METRICS" <<'PY'
import csv
import sys
from decimal import Decimal

path = sys.argv[1]
row_count = 0
min_key = None
max_key = None
sum_key = 0
sum_size = 0
sum_price = Decimal("0")
sum_name_len = 0
sum_comment_len = 0
seen = set()

with open(path, newline="", encoding="utf-8") as f:
    reader = csv.reader(f)
    header = next(reader)
    for row in reader:
        k = int(row[0])
        row_count += 1
        min_key = k if min_key is None else min(min_key, k)
        max_key = k if max_key is None else max(max_key, k)
        sum_key += k
        sum_size += int(row[5])
        sum_price += Decimal(row[7])
        sum_name_len += len(row[1])
        sum_comment_len += len(row[8])
        seen.add(k)

print(
    row_count,
    min_key,
    max_key,
    sum_key,
    sum_size,
    f"{sum_price:.2f}",
    sum_name_len,
    sum_comment_len,
    len(seen),
    sep="\t",
)
PY

echo "==> Querying exact sample rows"
MYSQL_PWD="$PASSWORD" "$MYSQL_BIN" "${mysql_args[@]}" -e "
SELECT
  P_PARTKEY, P_NAME, P_MFGR, P_BRAND, P_TYPE, P_SIZE, P_CONTAINER,
  CAST(P_RETAILPRICE AS DECIMAL(15,2)), P_COMMENT
FROM \`${DATABASE}\`.\`${TABLE}\`
WHERE P_PARTKEY IN (1,2,9999999,10000000,20000000)
ORDER BY P_PARTKEY;
" > "$TARGET_SAMPLE"

python3 - "$CSV_LOCAL" > "$CSV_SAMPLE" <<'PY'
import csv
import sys

samples = {1, 2, 9999999, 10000000, 20000000}
rows = []

with open(sys.argv[1], newline="", encoding="utf-8") as f:
    reader = csv.reader(f)
    next(reader)
    for row in reader:
        if int(row[0]) in samples:
            row[7] = f"{float(row[7]):.2f}"
            rows.append(row)

for row in sorted(rows, key=lambda item: int(item[0])):
    print("\t".join(row))
PY

{
  echo "metric_columns=row_count,min_key,max_key,sum_key,sum_size,sum_price,sum_name_len,sum_comment_len,distinct_key"
  echo "target_metrics=$(cat "$TARGET_METRICS")"
  echo "csv_metrics=$(cat "$CSV_METRICS")"
  echo "target_sample_file=$TARGET_SAMPLE"
  echo "csv_sample_file=$CSV_SAMPLE"
} > "$SUMMARY"

echo "==> Comparing metrics"
if ! cmp -s "$TARGET_METRICS" "$CSV_METRICS"; then
  echo "FAIL: metrics differ"
  echo "target metrics:"
  cat "$TARGET_METRICS"
  echo "csv metrics:"
  cat "$CSV_METRICS"
  echo "summary: $SUMMARY"
  exit 1
fi

echo "==> Comparing exact sample rows"
if ! cmp -s "$TARGET_SAMPLE" "$CSV_SAMPLE"; then
  echo "FAIL: sample rows differ"
  echo "diff:"
  diff -u "$CSV_SAMPLE" "$TARGET_SAMPLE" || true
  echo "summary: $SUMMARY"
  exit 1
fi

echo "PASS: CSV dump and tenant table are consistent"
echo "metrics:"
cat "$TARGET_METRICS"
echo "summary: $SUMMARY"
