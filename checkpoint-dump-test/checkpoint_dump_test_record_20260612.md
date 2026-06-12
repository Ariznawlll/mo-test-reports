# Checkpoint Dump 工具测试记录 - 2026-06-12

## 1. 测试背景

本次测试基于已有回归产生的 `mo-data`，不额外造大数据。使用研发修复后的 `mo-tool ckp dump` 从 checkpoint 离线导出 CSV 和 `restore.sql`，再导入普通租户验证数据正确性和 load 性能。

关联 issue：

- MatrixOne 主库 issue：[matrixorigin/matrixone#24943](https://github.com/matrixorigin/matrixone/issues/24943)

## 2. 测试环境

| 项目 | 值 |
|---|---|
| 服务器 | `mo-srv-129` |
| 服务器 IP | `10.222.1.129` |
| 工具路径 | `/data4/weilu/matrixone/mo-tool` |
| 源 MO 数据目录 | `/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data` |
| checkpoint 读取目录 | `/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared` |
| 最终 dump 输出目录 | `/data4/weilu/ckp_dump_20260612_140136` |
| load 目标租户 | `acc_cdc_test:test_account` |
| load 目标库 | `test` |

本次工具读取目录必须使用 `mo-data/shared`，不能直接使用 `mo-data`。直接传 `mo-data` 时工具报错：

```text
Error: resolve --ts: no checkpoint timestamp is available
```

## 3. checkpoint 对象确认

使用 `mo-tool ckp list` 可以正确读取 checkpoint 中的 database 清单。

关键 database：

| ACCOUNT_ID | DATABASE | DATABASE_ID |
|---|---|---|
| `0` | `test` | `332576` |
| `406` | `test` | `333843` |
| `0` | `tpch_1g` | `332507` |
| `0` | `tpch_10g` | `332516` |
| `0` | `tpch_100g` | `332525` |
| `0` | `tpch_1000g` | `332534` |
| `0` | `ssb_1g` | `332489` |
| `0` | `ssb_10g` | `332495` |
| `0` | `ssb_100g` | `332501` |

本轮优先测试 `account_id=0` 下的 `test` 库，`database_id=332576`。

## 4. dump 命令

```bash
export SRC_MO_HOME=/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head
export MO_DATA=$SRC_MO_HOME/mo-data
export CKP_DATA=$MO_DATA/shared
export TOOL_HOME=/data4/weilu/matrixone
export OUT=/data4/weilu/ckp_dump_20260612_140136

cd "$TOOL_HOME"

/usr/bin/time -v ./mo-tool ckp dump \
  --database-id=332576 \
  --output-dir="$OUT/test_db_332576" \
  --header \
  --load-script \
  -o "$OUT/test_db_332576" \
  "$CKP_DATA" 2>&1 | tee "$OUT/dump_test_db_332576.log"
```

## 5. dump 结果

| 项目 | 结果 |
|---|---|
| database | `test` |
| database_id | `332576` |
| account_id | `0` |
| 导出表数 | `3` |
| restore.sql | `/data4/weilu/ckp_dump_20260612_140136/test_db_332576/restore.sql` |
| dump 退出码 | `0` |
| dump 耗时 | `1:56.90` |
| CPU | `2899%` |
| 最大内存 | `6,271,468 KB`，约 `5.98 GB` |
| 文件系统输入 | `88,629,712` |
| 文件系统输出 | `287,613,096` |

导出表：

| 表 | table_id | 数据行数 | CSV 行数 |
|---|---:|---:|---:|
| `test.table_100_columns` | `332588` | `40,000,000` | `40,000,001` |
| `test.table_200_columns` | `332592` | `10,000` | `10,001` |
| `test.table_20_columns` | `332581` | `100,000,000` | `100,000,001` |
| 合计 | - | `140,010,000` | `140,010,003` |

CSV 行数校验命令：

```bash
cd "$OUT/test_db_332576/account_0/db_332576"
wc -l *.csv
```

实际结果：

```text
    40000001 table_100_columns_332588.csv
       10001 table_200_columns_332592.csv
   100000001 table_20_columns_332581.csv
   140010003 total
```

## 6. restore.sql 修复验证

测试过程中发现 `restore.sql` 中 `LOAD DATA` 没有并行参数时，大数据导入性能差，已记录到 issue。

研发第一次修复后，`parallel 'true'` 生成在 `IGNORE 1 LINES` 前面，当前 MO parser 报错：

```text
ERROR 1064 (HY000) at line 108: SQL parser error ...
syntax error ... near "
IGNORE 1 LINES";
```

正确语法顺序应为：

```sql
LINES TERMINATED BY '\n'
IGNORE 1 LINES
parallel 'true'
;
```

研发再次修复后，本轮 `restore.sql` 可成功执行。

## 7. load 命令

load 到普通租户 `acc_cdc_test:test_account`：

```bash
{
  echo "LOAD_START: $(date '+%Y-%m-%d %H:%M:%S')"
  /usr/bin/time -v mysql -h127.0.0.1 -P6001 -uacc_cdc_test:test_account -p111 \
    < "$OUT/test_db_332576/restore.sql"
  echo "LOAD_END: $(date '+%Y-%m-%d %H:%M:%S')"
} 2>&1 | tee "$OUT/test_db_332576/load_acc_cdc_test.log"
```

## 8. load 结果

| 项目 | 结果 |
|---|---|
| load 目标租户 | `acc_cdc_test:test_account` |
| load 目标库 | `test` |
| LOAD_START | `2026-06-12 14:06:01` |
| LOAD_END | `2026-06-12 14:07:26` |
| `time -v` Elapsed | `1:25.59` |
| load 退出码 | `0` |

## 9. load 后行数校验

校验 SQL：

```bash
mysql -h127.0.0.1 -P6001 -uacc_cdc_test:test_account -p111 -e "
select 'table_100_columns' as tbl, count(*) as cnt from test.table_100_columns
union all
select 'table_200_columns', count(*) from test.table_200_columns
union all
select 'table_20_columns', count(*) from test.table_20_columns;
"
```

实际结果：

```text
+-------------------+-----------+
| tbl               | cnt       |
+-------------------+-----------+
| table_20_columns  | 100000000 |
| table_200_columns |     10000 |
| table_100_columns |  40000000 |
+-------------------+-----------+
```

行数与 dump 阶段 CSV 数据行数一致，验证通过。

## 10. table 级 dump/load 验证

### 10.1 测试对象

本轮补充验证 `ann` 库下两张向量表的 table 级 dump 和 restore。

| 项目 | 值 |
|---|---|
| source account_id | `0` |
| source database | `ann` |
| source database_id | `333172` |
| load 目标租户 | `acc_cdc_test:test_account` |
| load 目标 database | `ann` |

表信息：

| 表 | table_id | 类型特点 |
|---|---:|---|
| `ann.items_gist` | `333177` | `vecf32(960)` + IVFFLAT index |
| `ann.items_sift` | `333173` | `vecf32(128)` + IVFFLAT index |

### 10.2 table 级 dump 命令

`items_gist`：

```bash
./mo-tool ckp dump \
  --database-id=333172 \
  --table=items_gist \
  --header \
  --load-script \
  -o "$OUT/ann_items_gist" \
  "$CKP_DATA" 2>&1 | tee "$OUT/dump_ann_items_gist.log"
```

`items_sift`：

```bash
./mo-tool ckp dump \
  --database-id=333172 \
  --table=items_sift \
  --header \
  --load-script \
  -o "$OUT/ann_items_sift" \
  "$CKP_DATA" 2>&1 | tee "$OUT/dump_ann_items_sift.log"
```

### 10.3 table 级 dump 结果

| 表 | table_id | visible_rows | physical_rows | CSV | restore.sql |
|---|---:|---:|---:|---|---|
| `ann.items_gist` | `333177` | `1,000,000` | `1,000,000` | `/data4/weilu/ckp_dump_20260612_140136/ann_items_gist/account_0/db_333172/items_gist_333177.csv` | `/data4/weilu/ckp_dump_20260612_140136/ann_items_gist/restore.sql` |
| `ann.items_sift` | `333173` | `1,000,000` | `1,000,000` | `/data4/weilu/ckp_dump_20260612_140136/ann_items_sift/account_0/db_333172/items_sift_333173.csv` | `/data4/weilu/ckp_dump_20260612_140136/ann_items_sift/restore.sql` |

CSV 输出大小：

| 表 | written_bytes |
|---|---:|
| `items_gist` | `7,583,671,563` |
| `items_sift` | `468,818,728` |

### 10.4 table 级 load 命令和结果

`items_gist` load：

```bash
{
  echo "LOAD_GIST_START: $(date '+%Y-%m-%d %H:%M:%S')"
  /usr/bin/time -v mysql -h127.0.0.1 -P6001 -uacc_cdc_test:test_account -p111 \
    < "$OUT/ann_items_gist/restore.sql"
  echo "LOAD_GIST_END: $(date '+%Y-%m-%d %H:%M:%S')"
} 2>&1 | tee "$OUT/ann_items_gist/load_acc_cdc_test.log"
```

结果：

| 项目 | 值 |
|---|---|
| LOAD_GIST_START | `2026-06-12 14:18:49` |
| LOAD_GIST_END | `2026-06-12 14:18:57` |
| `time -v` Elapsed | `0:07.53` |
| Exit status | `0` |

`items_sift` load：

```bash
{
  echo "LOAD_SIFT_START: $(date '+%Y-%m-%d %H:%M:%S')"
  /usr/bin/time -v mysql -h127.0.0.1 -P6001 -uacc_cdc_test:test_account -p111 \
    < "$OUT/ann_items_sift/restore.sql"
  echo "LOAD_SIFT_END: $(date '+%Y-%m-%d %H:%M:%S')"
} 2>&1 | tee "$OUT/ann_items_sift/load_acc_cdc_test.log"
```

结果：

| 项目 | 值 |
|---|---|
| LOAD_SIFT_START | `2026-06-12 14:19:20` |
| LOAD_SIFT_END | `2026-06-12 14:19:26` |
| `time -v` Elapsed | `0:05.74` |
| Exit status | `0` |

### 10.5 table 级数据正确性校验

使用源租户和恢复租户分别执行聚合 checksum，并对 `id % 100` 分桶结果做 diff。

聚合 checksum SQL：

```sql
select 'items_gist' as tbl,
       count(*) as cnt,
       min(id) as min_id,
       max(id) as max_id,
       sum(crc32(cast(id as char))) as id_crc_sum,
       sum(crc32(embedding)) as emb_crc_sum
from ann.items_gist
union all
select 'items_sift' as tbl,
       count(*) as cnt,
       min(id) as min_id,
       max(id) as max_id,
       sum(crc32(cast(id as char))) as id_crc_sum,
       sum(crc32(embedding)) as emb_crc_sum
from ann.items_sift;
```

源租户和恢复租户聚合结果一致：

```text
items_sift  1000000  0  999999  2147509531781186  2148181623720352
items_gist  1000000  0  999999  2147509531781186  2148923198754481
```

分桶 checksum 校验：

```sql
select 'items_gist' as tbl,
       id % 100 as bucket,
       count(*) as cnt,
       sum(crc32(cast(id as char))) as id_crc_sum,
       sum(crc32(embedding)) as emb_crc_sum
from ann.items_gist
group by bucket
union all
select 'items_sift' as tbl,
       id % 100 as bucket,
       count(*) as cnt,
       sum(crc32(cast(id as char))) as id_crc_sum,
       sum(crc32(embedding)) as emb_crc_sum
from ann.items_sift
group by bucket
order by tbl, bucket;
```

校验结果：

| 校验项 | 结果 |
|---|---|
| 源租户分桶结果 | `200` rows |
| 恢复租户分桶结果 | `200` rows |
| `diff` | 无差异 |

数据正确性结论：`items_gist` 和 `items_sift` 行数、id 范围、全表 checksum、分桶 checksum 均一致。

### 10.6 table 级 DDL 一致性校验

数据一致，但 DDL 不完全一致：恢复后的表缺少源表中的 IVFFLAT 向量索引。该问题已追加到 issue：

- [matrixorigin/matrixone#24943 comment](https://github.com/matrixorigin/matrixone/issues/24943#issuecomment-4688062717)

`items_gist` 源表：

```sql
CREATE TABLE `items_gist` (
  `id` int NOT NULL,
  `embedding` vecf32(960) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `ivf_2000` USING ivfflat (`embedding`) lists = 2000  op_type 'vector_l2_ops'
)
```

`items_gist` 恢复后：

```sql
CREATE TABLE `items_gist` (
  `id` int NOT NULL,
  `embedding` vecf32(960) DEFAULT NULL,
  PRIMARY KEY (`id`)
)
```

`items_sift` 源表：

```sql
CREATE TABLE `items_sift` (
  `id` int NOT NULL,
  `embedding` vecf32(128) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `ivf_500` USING ivfflat (`embedding`) lists = 500  op_type 'vector_l2_ops'
)
```

`items_sift` 恢复后：

```sql
CREATE TABLE `items_sift` (
  `id` int NOT NULL,
  `embedding` vecf32(128) DEFAULT NULL,
  PRIMARY KEY (`id`)
)
```

DDL 结论：列定义和主键一致，但 IVFFLAT 向量索引丢失，需研发修复。

## 11. `tpch_100g` database 级 dump/load 验证

### 11.1 测试对象

| 项目 | 值 |
|---|---|
| source account_id | `0` |
| source database | `tpch_100g` |
| source database_id | `332525` |
| dump 输出目录 | `/data4/weilu/ckp_dump_20260612_143026/tpch_100g_db_332525` |
| restore.sql | `/data4/weilu/ckp_dump_20260612_143026/tpch_100g_db_332525/restore.sql` |
| load 目标租户 | `acc_cdc_test:test_account` |
| load 目标 database | `tpch_100g` |

### 11.2 dump 命令

```bash
export CKP_DATA=/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared
export OUT=/data4/weilu/ckp_dump_20260612_143026

cd /data4/weilu/matrixone

/usr/bin/time -v ./mo-tool ckp dump \
  --database-id=332525 \
  --output-dir="$OUT/tpch_100g_db_332525" \
  --header \
  --load-script \
  --jobs=4 \
  -o "$OUT/tpch_100g_db_332525" \
  "$CKP_DATA" 2>&1 | tee "$OUT/dump_tpch_100g_db_332525.log"
```

### 11.3 dump 结果

| 项目 | 结果 |
|---|---|
| 导出表数 | `8` |
| dump 耗时 | `3:17.32` |
| CPU | `5517%` |
| 最大内存 | `1,358,120 KB`，约 `1.30 GB` |
| dump 退出码 | `0` |

导出表：

| 表 | table_id | visible_rows |
|---|---:|---:|
| `tpch_100g.nation` | `332528` | `25` |
| `tpch_100g.region` | `332532` | `5` |
| `tpch_100g.supplier` | `332533` | `1,000,000` |
| `tpch_100g.customer` | `332526` | `15,000,000` |
| `tpch_100g.part` | `332530` | `20,000,000` |
| `tpch_100g.partsupp` | `332531` | `80,000,000` |
| `tpch_100g.orders` | `332529` | `150,000,000` |
| `tpch_100g.lineitem` | `332527` | `600,037,902` |

### 11.4 load 命令和失败现象

```bash
export TPCH_OUT=/data4/weilu/ckp_dump_20260612_143026/tpch_100g_db_332525

mysql -h127.0.0.1 -P6001 -uacc_cdc_test:test_account -p111 \
  -e "drop database if exists tpch_100g;"

{
  echo "LOAD_TPCH100G_START: $(date '+%Y-%m-%d %H:%M:%S')"
  /usr/bin/time -v mysql -h127.0.0.1 -P6001 -uacc_cdc_test:test_account -p111 \
    < "$TPCH_OUT/restore.sql"
  echo "LOAD_TPCH100G_END: $(date '+%Y-%m-%d %H:%M:%S')"
} 2>&1 | tee "$TPCH_OUT/load_acc_cdc_test.log"
```

实际结果：

| 项目 | 结果 |
|---|---|
| LOAD_TPCH100G_START | `2026-06-12 14:37:41` |
| LOAD_TPCH100G_END | `2026-06-12 14:39:53` |
| `time -v` Elapsed | `2:11.76` |
| load 退出码 | `1` |
| 失败行 | `restore.sql` line `111` |
| 失败表 | `tpch_100g.part` |

错误信息：

```text
ERROR 20101 (HY000) at line 111: internal error: the input value '
```

第 111 行对应 `part` 表的 `LOAD DATA`：

```sql
LOAD DATA INFILE '/data4/weilu/ckp_dump_20260612_143026/tpch_100g_db_332525/account_0/db_332525/part_332530.csv'
INTO TABLE `part`
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
parallel 'true'
;
```

失败时，普通租户中已经创建/导入了前面的部分表：

```text
customer
lineitem
nation
orders
part
```

后续表未执行：

```text
partsupp
region
supplier
```

### 11.5 单独验证 `part` 表 load

进入 `tpch_100g` 后，手工执行不带 `parallel 'true'` 的 `LOAD DATA`：

```sql
use tpch_100g;

LOAD DATA INFILE '/data4/weilu/ckp_dump_20260612_143026/tpch_100g_db_332525/account_0/db_332525/part_332530.csv'
INTO TABLE `part`
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES;
```

仍然失败：

```text
ERROR 20101 (HY000): internal error: the input value '
```

因此该问题不是 `parallel 'true'` 顺序或并行 load 导致，疑似 `part_332530.csv` 中某些字符串字段的 CSV 转义或 `LOAD DATA` 解析问题。

已单独提交 issue：

- [matrixorigin/matrixone#24957](https://github.com/matrixorigin/matrixone/issues/24957)

### 11.6 `tpch_100g` 结论

| 验证项 | 结论 |
|---|---|
| `tpch_100g` database 级 dump | 通过 |
| `tpch_100g` restore.sql load | 不通过 |
| 失败定位 | `part_332530.csv` 对应 `LOAD DATA` |
| 去掉 `parallel` 后单独 load `part` | 仍失败 |
| 初步判断 | CSV 特殊字符转义或 `LOAD DATA` 解析问题 |

## 12. 本轮结论

| 验证项 | 结论 |
|---|---|
| `mo-tool ckp list` 读取 checkpoint | 通过 |
| database 级 dump | 通过 |
| `--header` CSV 行数 | 通过 |
| `--load-script` 生成 `restore.sql` | 通过 |
| `restore.sql` 中 `parallel 'true'` 修复后可执行 | 通过 |
| 普通租户 load | 通过 |
| load 后行数校验 | 通过 |
| table 级 dump | 通过 |
| table 级 load | 通过 |
| table 级数据 checksum | 通过 |
| table 级 DDL 一致性 | 不通过，IVFFLAT 向量索引丢失 |
| `tpch_100g` database 级 dump | 通过 |
| `tpch_100g` restore.sql load | 不通过，`part` 表 CSV load 失败 |

本轮使用回归数据中的大表完成了 database 级端到端验证：checkpoint dump 成功，生成 CSV 和 `restore.sql` 成功，`restore.sql` load 到普通租户成功，恢复后行数和 dump 数据一致。

补充的 table 级验证中，`ann.items_gist` 和 `ann.items_sift` 的数据 checksum 一致，但恢复后的 DDL 缺少 IVFFLAT 向量索引，已记录为 ckp issue 合集中的问题 2。

`tpch_100g` 的 database 级 dump 成功，但 load 到 `part` 表失败；去掉 `parallel 'true'` 后仍失败，已单独记录为 `tpch_100g.part` CSV 无法 load 的问题。
