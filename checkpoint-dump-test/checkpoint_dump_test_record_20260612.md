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

## 12. `tpcc_1000` database 级 dump/load 验证

### 12.1 测试对象

| 项目 | 值 |
|---|---|
| source account_id | `0` |
| source database | `tpcc_1000` |
| source database_id | `332565` |
| dump 输出目录 | `/data4/weilu/ckp_dump_20260612_145510/tpcc_1000_db_332565` |
| restore.sql | `/data4/weilu/ckp_dump_20260612_145510/tpcc_1000_db_332565/restore.sql` |
| load 目标租户 | `acc_cdc_test:test_account` |
| load 目标 database | `tpcc_1000` |

### 12.2 表清单

`mo-tool ckp list --type=tables --database-id=332565` 可识别 10 张表：

| 表 | table_id |
|---|---:|
| `bmsql_config` | `332566` |
| `bmsql_customer` | `332567` |
| `bmsql_district` | `332568` |
| `bmsql_history` | `332569` |
| `bmsql_item` | `332570` |
| `bmsql_new_order` | `332571` |
| `bmsql_oorder` | `332572` |
| `bmsql_order_line` | `332573` |
| `bmsql_stock` | `332574` |
| `bmsql_warehouse` | `332575` |

### 12.3 dump 命令

```bash
export CKP_DATA=/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared
export OUT=/data4/weilu/ckp_dump_20260612_145510

cd /data4/weilu/matrixone

/usr/bin/time -v ./mo-tool ckp dump \
  --database-id=332565 \
  --output-dir="$OUT/tpcc_1000_db_332565" \
  --header \
  --load-script \
  --jobs=4 \
  -o "$OUT/tpcc_1000_db_332565" \
  "$CKP_DATA" 2>&1 | tee "$OUT/dump_tpcc_1000_db_332565.log"
```

### 12.4 dump 结果

| 项目 | 结果 |
|---|---|
| 导出表数 | `10` |
| dump 耗时 | `1:05.00` |
| CPU | `5035%` |
| 最大内存 | `1,835,560 KB`，约 `1.75 GB` |
| dump 退出码 | `0` |

CSV 行数：

```text
          5 bmsql_config_332566.csv
   30000001 bmsql_customer_332567.csv
      10001 bmsql_district_332568.csv
   30092090 bmsql_history_332569.csv
     100001 bmsql_item_332570.csv
    9011221 bmsql_new_order_332571.csv
   30095971 bmsql_oorder_332572.csv
  300939654 bmsql_order_line_332573.csv
  100000001 bmsql_stock_332574.csv
       1001 bmsql_warehouse_332575.csv
  500249946 total
```

CSV 包含 header，因此数据行数为每个 CSV 行数减 1。

### 12.5 load 命令和结果

首次执行 load 时因当前 shell 未设置 `$TPCC_OUT`，`"$TPCC_OUT/restore.sql"` 被展开为 `/restore.sql`，未实际执行 SQL。重新设置变量后执行成功：

```bash
export OUT=/data4/weilu/ckp_dump_20260612_145510
export TPCC_OUT=$OUT/tpcc_1000_db_332565

mysql -h127.0.0.1 -P6001 -uacc_cdc_test:test_account -p111 \
  -e "drop database if exists tpcc_1000;"

{
  echo "LOAD_TPCC1000_START: $(date '+%Y-%m-%d %H:%M:%S')"
  /usr/bin/time -v mysql -h127.0.0.1 -P6001 -uacc_cdc_test:test_account -p111 \
    < "$TPCC_OUT/restore.sql"
  echo "LOAD_TPCC1000_END: $(date '+%Y-%m-%d %H:%M:%S')"
} 2>&1 | tee "$TPCC_OUT/load_acc_cdc_test.log"
```

实际结果：

| 项目 | 结果 |
|---|---|
| LOAD_TPCC1000_START | `2026-06-12 15:01:25` |
| LOAD_TPCC1000_END | `2026-06-12 15:03:09` |
| `time -v` Elapsed | `1:43.28` |
| load 退出码 | `0` |

### 12.6 表清单和行数校验

源库和普通租户恢复库均包含 10 张表，表清单一致。

行数校验结果：

| 表 | 行数 |
|---|---:|
| `bmsql_config` | `4` |
| `bmsql_customer` | `30,000,000` |
| `bmsql_district` | `10,000` |
| `bmsql_history` | `30,092,089` |
| `bmsql_item` | `100,000` |
| `bmsql_new_order` | `9,011,220` |
| `bmsql_oorder` | `30,095,970` |
| `bmsql_order_line` | `300,939,653` |
| `bmsql_stock` | `100,000,000` |
| `bmsql_warehouse` | `1,000` |

行数与 dump 阶段 CSV 数据行数一致。

### 12.7 DDL 一致性校验

对 10 张表分别执行源库和恢复库 `SHOW CREATE TABLE` 并 diff，结果全部一致：

```text
DDL_OK bmsql_config
DDL_OK bmsql_customer
DDL_OK bmsql_district
DDL_OK bmsql_history
DDL_OK bmsql_item
DDL_OK bmsql_new_order
DDL_OK bmsql_oorder
DDL_OK bmsql_order_line
DDL_OK bmsql_stock
DDL_OK bmsql_warehouse
```

### 12.8 数据 checksum 尝试

曾尝试对 `tpcc_1000` 做全表全列 checksum；由于数据量约 5 亿行，该方式过重，随后改为按主键前后 1000 行样本 checksum。但带 `ORDER BY ... LIMIT` 的样本 checksum 仍然较重，最终连接被服务端断开：

```text
ERROR 2013 (HY000): Lost connection to MySQL server during query
```

后续建议改成更轻量的业务范围抽样，例如按仓库维度选择 `w_id in (1, 500, 1000)`，避免对大表做全表排序或全表 checksum。

### 12.9 `tpcc_1000` 结论

| 验证项 | 结论 |
|---|---|
| `tpcc_1000` database 级 dump | 通过 |
| `tpcc_1000` restore.sql load | 通过 |
| 表清单一致性 | 通过 |
| 行数一致性 | 通过 |
| DDL 一致性 | 通过 |
| 全表/排序 checksum | 未完成，查询过重导致连接断开 |

## 13. TKE/COS `tpcc_100` database 级 dump 验证

### 13.1 测试对象

| 项目 | 值 |
|---|---|
| 环境 | TKE |
| checkpoint 存储 | COS |
| COS checkpoint 前缀 | `mo-nightly-gz-1308875761/mo-benchmark-27359437757/data/ckp/` |
| source account | `sys` / `account_id=0` |
| source database | `tpcc_100` |
| database_id | `272577` |
| dump 输出目录 | `/mnt/disk1/weilu/ckp_dump_tke_tpcc100_20260612_171411/tpcc_100_db_272577` |

本节先记录 TKE/COS checkpoint 输入 + 本地输出目录的 database 级 dump 结果；随后使用最新工具补测 `--out-s3` 输出到 COS 的恢复链路。

### 13.2 COS checkpoint 读取验证

使用 `mo-tool ckp list --backend=S3 --type=databases` 可正常读取 COS checkpoint，输出中包含目标库：

```text
ACCOUNT_ID  DATABASE  DATABASE_ID
0           tpcc_100  272577
```

继续按 database_id 列表：

```text
ACCOUNT_ID  DATABASE  TABLE             TABLE_ID  REL_KIND
0           tpcc_100  bmsql_config      272578    r
0           tpcc_100  bmsql_customer    272579    r
0           tpcc_100  bmsql_district    272580    r
0           tpcc_100  bmsql_history     272596    r
0           tpcc_100  bmsql_item        272581    r
0           tpcc_100  bmsql_new_order   272597    r
0           tpcc_100  bmsql_oorder      272582    r
0           tpcc_100  bmsql_order_line  272583    r
0           tpcc_100  bmsql_stock       272785    r
0           tpcc_100  bmsql_warehouse   272786    r
```

### 13.3 dump 命令

```bash
export DB_ID=272577
export CKP_DIR=ckp
export OUT=/mnt/disk1/weilu/ckp_dump_tke_tpcc100_20260612_171411
export TPCC_OUT="$OUT/tpcc_100_db_${DB_ID}"

{
  echo "DUMP_TPCC100_START: $(date '+%Y-%m-%d %H:%M:%S')"
  /usr/bin/time -v ./mo-tool ckp dump \
    --backend=S3 \
    --s3 "$S3_ARGS" \
    --database-id="$DB_ID" \
    --output-dir="$TPCC_OUT" \
    --header \
    --load-script \
    --jobs=4 \
    -o "$TPCC_OUT" \
    "$CKP_DIR"
  echo "DUMP_TPCC100_END: $(date '+%Y-%m-%d %H:%M:%S')"
} 2>&1 | tee "$TPCC_OUT/dump.log"
```

### 13.4 dump 结果

```text
DUMP_TPCC100_START: 2026-06-12 17:18:30
Dumped 10 tables to /mnt/disk1/weilu/ckp_dump_tke_tpcc100_20260612_171411/tpcc_100_db_272577
Restore script written to /mnt/disk1/weilu/ckp_dump_tke_tpcc100_20260612_171411/tpcc_100_db_272577/restore.sql
Elapsed (wall clock) time: 2:41.87
Maximum resident set size: 587704 KB
Exit status: 0
DUMP_TPCC100_END: 2026-06-12 17:21:12
```

CSV 行数如下，包含 header：

| CSV 文件 | 行数 |
|---|---:|
| `bmsql_config_272578.csv` | `5` |
| `bmsql_customer_272579.csv` | `3,000,001` |
| `bmsql_district_272580.csv` | `1,001` |
| `bmsql_history_272596.csv` | `3,202,140` |
| `bmsql_item_272581.csv` | `100,001` |
| `bmsql_new_order_272597.csv` | `922,790` |
| `bmsql_oorder_272582.csv` | `3,210,370` |
| `bmsql_order_line_272583.csv` | `32,117,299` |
| `bmsql_stock_272785.csv` | `10,000,001` |
| `bmsql_warehouse_272786.csv` | `101` |
| total | `52,553,709` |

### 13.5 restore.sql 语法检查

`restore.sql` 中 10 个 `LOAD DATA` 均包含 header 跳过和并行 load 配置，顺序正确：

```sql
LINES TERMINATED BY '\n'
IGNORE 1 LINES
parallel 'true'
;
```

检查结果说明此前发现的 `parallel 'true'` 放在 `IGNORE 1 LINES` 前导致 parser error 的问题，在该版本中未复现。

### 13.6 `--out-s3` 输出到 COS 阻塞问题

研发更新工具后，`mo-tool ckp dump` 新增输出端参数：

```text
--out-backend string     remote backend for --out-s3: S3 or MINIO
--out-s3 string          S3 arguments for dump output, for example bucket=...,endpoint=...,region=...,key-prefix=...,key-id=...,key-secret=...
```

使用小表 `tpcc_100.bmsql_config` 做 S3/COS 输出冒烟测试：

```bash
./mo-tool ckp dump \
  --backend=S3 \
  --s3 "$S3_ARGS" \
  --table-id=272578 \
  --header \
  --load-script \
  --out-backend=S3 \
  --out-s3 "$OUT_S3_ARGS" \
  -o "bmsql_config" \
  "$CKP_DIR"
```

执行结果：

```text
DUMP_CONFIG_S3_START: 2026-06-12 17:54:18
Table 272578 tpcc_100.bmsql_config dumped to bmsql_config/account_0/db_272577/bmsql_config_272578.csv
Restore script written to bmsql_config/restore.sql
Elapsed (wall clock) time: 2:06.23
Exit status: 0
DUMP_CONFIG_S3_END: 2026-06-12 17:56:24
```

COS 控制台可看到对应 CSV 和 `restore.sql`，说明 `--out-s3` 可以把 dump 产物写入 COS。

但生成的 `restore.sql` 中 `LOAD DATA INFILE` 仍然是相对路径：

```sql
LOAD DATA INFILE 'bmsql_config/account_0/db_272577/bmsql_config_272578.csv'
INTO TABLE `bmsql_config`
FIELDS TERMINATED BY ','
ENCLOSED BY '"'
LINES TERMINATED BY '\n'
IGNORE 1 LINES
parallel 'true'
;
```

该路径在通过集群 IP load 时由服务端 CN pod 解析，CN pod 无法访问该相对路径，导致 TKE/COS 场景仍无法直接端到端 restore。期望行为是：当使用 `--out-s3` 时，`restore.sql` 中的 `LOAD DATA INFILE` 生成 COS/S3 可访问路径，或生成 MatrixOne 支持的远端 load 语法。

已单独提 bug：

```text
https://github.com/matrixorigin/matrixone/issues/24965
```

当前状态：`--out-s3` 写 COS 冒烟通过，但 `restore.sql` 路径错误导致普通租户 load 阻塞。该问题修复前，TKE/COS `tpcc_100` 的 S3 输出端到端恢复测试暂停，下周继续验证。

## 14. 本轮结论

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
| `tpcc_1000` database 级 dump | 通过 |
| `tpcc_1000` restore.sql load | 通过 |
| `tpcc_1000` 行数和 DDL 校验 | 通过 |
| TKE/COS `tpcc_100` database 级 dump | 通过 |
| TKE/COS `tpcc_100` `--out-s3` 写 COS | 冒烟通过 |
| TKE/COS `tpcc_100` `--out-s3` restore.sql load | 阻塞，`restore.sql` 仍生成相对路径，见 #24965 |

本轮使用回归数据中的大表完成了 database 级端到端验证：checkpoint dump 成功，生成 CSV 和 `restore.sql` 成功，`restore.sql` load 到普通租户成功，恢复后行数和 dump 数据一致。

补充的 table 级验证中，`ann.items_gist` 和 `ann.items_sift` 的数据 checksum 一致，但恢复后的 DDL 缺少 IVFFLAT 向量索引，已记录为 ckp issue 合集中的问题 2。

`tpch_100g` 的 database 级 dump 成功，但 load 到 `part` 表失败；去掉 `parallel 'true'` 后仍失败，已单独记录为 `tpch_100g.part` CSV 无法 load 的问题。

`tpcc_1000` 的 database 级 dump 和 restore.sql load 均成功，表清单、行数和 DDL 均一致；全表/排序 checksum 对该规模数据过重，后续改用按业务范围的轻量抽样 checksum。

TKE/COS 场景中，`tpcc_100` 已验证可以从 COS checkpoint 成功 list 和 dump 到本地目录，10 张表 CSV 及 `restore.sql` 均生成成功。最新工具的 `--out-s3` 可将 dump 产物写到 COS，但 `restore.sql` 中 `LOAD DATA INFILE` 仍为相对路径，导致通过集群 IP 恢复到普通租户时 CN pod 无法访问 CSV；该问题已记录为 #24965，当前阻塞 TKE/COS S3 输出端到端 restore 测试。

## 15. 2026-06-15 专项造数与逐表 dump/load 验证

### 15.1 测试目的

前一轮主要复用回归数据和 TPC/TPC-C 大库。本轮补充专项造数，覆盖 checkpoint dump 测试方案中的数据类型、边界值、约束、索引、表形态、MVCC/DML、宽表和可调数据量，便于在 129 上稳定复现和扩展验证。

本轮新增脚本：

| 脚本 | 用途 |
|---|---|
| `checkpoint-dump-test/prepare_ckp_dump_coverage_data.sh` | 创建专项测试库并插入覆盖数据 |
| `checkpoint-dump-test/dump_ckp_tables_20260615_144436.log` | 逐表 checkpoint dump 执行日志 |
| `checkpoint-dump-test/load_ckp_table_dumps.sh` | 遍历逐表 dump 产物并尝试 load 到普通租户 |

### 15.2 专项造数脚本

在 129 上执行：

```bash
./prepare_ckp_dump_coverage_data.sh \
  --host 10.222.1.129 \
  --port 6001 \
  --user dump \
  --password 111 \
  --db-prefix ckp \
  --scale 10000 \
  --drop-existing
```

脚本最终成功创建并插入数据到 4 个专项库：

| database | 内容 |
|---|---|
| `ckp_types` | 整数、浮点、decimal、bit/bool、字符串、二进制、JSON、时间、UUID、vector、array、datalink、全类型宽表 |
| `ckp_constraints` | PK/UK/FK/default/auto_increment/comment/fulltext/vector index/特殊列名 |
| `ckp_tables` | 普通表、空表、临时表可见性、视图、CTAS、LIKE、分区表、cluster by、特殊表名 |
| `ckp_mvcc_perf` | insert/update/delete/truncate/alter、大表、宽表、CSV 特殊字符、可调规模数据 |

关键数据确认：

```text
ckp_types.t_int_signed            4
ckp_types.t_strings               4
ckp_types.t_enum_set              4
ckp_types.t_vector_vecf32         4
ckp_constraints.parent            3
ckp_constraints.t_vector_index    3
ckp_tables.t_hash_partition       1000
ckp_tables.t_cluster_by           1000
ckp_mvcc_perf.t_scale_rows        10000
ckp_mvcc_perf.t_wide_32_cols      10000
```

DDL 额外确认：

```sql
CREATE TABLE `t_vector_index` (
  `id` bigint NOT NULL,
  `embedding` vecf32(3) DEFAULT NULL,
  PRIMARY KEY (`id`),
  KEY `idx_vec_ivf` USING ivfflat (`embedding`) lists = 1  op_type 'vector_l2_ops'
)
```

```sql
CREATE TABLE `t_cluster_by` (
  `id` int NOT NULL,
  `k` int DEFAULT NULL,
  `payload` varchar(30) DEFAULT NULL
) CLUSTER BY (`k`)
```

说明：`DATALINK` 当前 129 环境不支持 `https` scheme，因此脚本保留 `DATALINK` 列类型覆盖，但只插入 `NULL`。

### 15.3 checkpoint 对象确认

专项库已进入 checkpoint，`mo-tool ckp list --type=databases` 可见：

```text
ACCOUNT_ID  DATABASE         DATABASE_ID
0           ckp_constraints  333997
0           ckp_mvcc_perf    334036
0           ckp_tables       334017
0           ckp_types        333981
0           ckp_util         333978
```

逐库表清单也可通过 `ckp list --type=tables --database-id=<DB_ID>` 查询。脚本将 `REL_KIND = r` 的普通表写入：

```text
/data4/weilu/ckp_test/logs/all_target_tables.tsv
```

### 15.4 逐表 checkpoint dump

逐表 dump 输出目录：

```text
/data4/weilu/ckp_test
```

脚本核心命令：

```bash
mo-tool ckp dump \
  --table-id=<TABLE_ID> \
  --header \
  --load-script \
  -o /data4/weilu/ckp_test/<db>/<table_id>_<table> \
  /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared
```

本轮逐表 dump 统计：

| 项目 | 数量 |
|---|---:|
| 尝试 dump 普通表 | 37 |
| 生成 `restore.sql` | 31 |
| dump 失败或无完整 `restore.sql` | 6 |

成功生成 `restore.sql` 的表覆盖 `ckp_types` 全部 14 张表、`ckp_mvcc_perf` 全部 5 张表，以及 `ckp_constraints`/`ckp_tables` 中大部分表。

### 15.5 dump 阶段发现的问题

#### 15.5.1 `--table-id --load-script` 合并索引失败

以下表 CSV 已写出，但生成 `restore.sql` 失败：

```text
ckp_constraints.parent                  table_id=333999
ckp_constraints.t_auto_inc              table_id=334004
ckp_constraints.t_identifier_comments   table_id=334008
```

典型错误：

```text
Table 333999 ckp_constraints.parent dumped to /data4/weilu/ckp_test/ckp_constraints/333999_parent/account_0/db_333997/parent_333999.csv
Error: merge create table indexes for table 333999: cannot locate CREATE TABLE definition
Exit status: 1
```

已单独建 issue：

```text
https://github.com/matrixorigin/matrixone/issues/24985
```

该 issue 正文已补充 129 上稳定复现命令。

#### 15.5.2 `ckp list` 可见但 `ckp dump` prepare 找不到表

以下表在 `ckp list --type=tables` 中可见，但 `ckp dump --table-id` 失败：

```text
ckp_tables.t_empty           table_id=334019
ckp_tables.t_hash_partition  table_id=334023
ckp_tables.t_key_partition   table_id=334028
```

典型错误：

```text
Error: prepare table 334019 (ckp_tables.t_empty): internal error: table 334019 not found in checkpoint at ts 1781505702346157941-0
Exit status: 1
```

已单独建 issue：

```text
https://github.com/matrixorigin/matrixone/issues/24986
```

该 issue 正文已补充 129 上稳定复现命令。

### 15.6 尝试 load 到普通租户

普通租户创建：

```sql
create account acc01 admin_name 'test_account' identified by '111';
```

登录验证：

```bash
mysql -h127.0.0.1 -P6001 -u'acc01:test_account' -p111 -e "select current_user();"
```

结果：

```text
current_user()
test_account@localhost
```

随后使用 `load_ckp_table_dumps.sh` 遍历 `/data4/weilu/ckp_test` 下的 `restore.sql` 并尝试 load。

第一版脚本存在控制流问题：单表 load 使用 `{ ... exit "$rc"; }`，导致第一张表执行后整个脚本退出。已修复为子 shell `( ... exit "$rc"; )`。

第二轮执行结果：

```text
restore_sql attempted: 34
success: 3
failed: 31
missing restore.sql: 3
```

但后续确认：

- 3 个 `success` 是误判，对应 `parent`、`t_auto_inc`、`t_identifier_comments`，其 `restore.sql` 只有 `CREATE DATABASE` 和 `USE`，没有 `CREATE TABLE` 或 `LOAD DATA`。
- 31 个 `failed` 的根因一致：`restore.sql` 的 `CREATE TABLE` DDL 中混入 NUL 字节和内部类型编码，无法被 MySQL 客户端/MatrixOne parser 执行。
- 3 个 `missing restore.sql` 对应 #24986 中 dump prepare 失败的表。

### 15.7 `restore.sql` 含 NUL/内部类型编码问题

以 `ckp_types.t_int_signed` 为最小复现：

```bash
/data4/weilu/matrixone/mo-tool ckp dump \
  --table-id=333982 \
  --header \
  --load-script \
  -o /data4/weilu/ckp_repro_bad_restore_sql/t_int_signed \
  /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared
```

查看生成的 `restore.sql`：

```bash
nl -ba /data4/weilu/ckp_test/ckp_types/333982_t_int_signed/restore.sql | sed -n '1,20p'
```

实际输出：

```text
     1  CREATE DATABASE IF NOT EXISTS `ckp_types`;
     2  USE `ckp_types`;
     3
     4  CREATE TABLE `ckp_types`.`t_int_signed` (
     5    `id`@,
     6    `c_tiny` ,
     7    `c_small`  ,
     8    `c_int`@,
     9    `c_big` �
    10  )
```

`od` 可见列名后出现 NUL 和内部类型编码：

```text
`id`  \0 026 \0 \0 ...
`c_tiny`  \0 024 \0 \0 ...
`c_small` \0 025 \0 \0 ...
`c_int`  \0 026 \0 \0 ...
`c_big`  \0 027 \0 \0 ...
```

批量检查命令：

```bash
find /data4/weilu/ckp_test -name restore.sql -print0 | while IFS= read -r -d '' f; do
  python3 - "$f" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
if b"\x00" in p.read_bytes():
    print("NUL_FOUND", p)
PY
done
```

本轮 31 个 `restore.sql` 均检出 `NUL_FOUND`。典型列表包括：

```text
/data4/weilu/ckp_test/ckp_constraints/334001_child_cascade/restore.sql
/data4/weilu/ckp_test/ckp_constraints/334000_child_restrict/restore.sql
/data4/weilu/ckp_test/ckp_constraints/334002_child_set_null/restore.sql
/data4/weilu/ckp_test/ckp_constraints/334007_t_composite_keys/restore.sql
/data4/weilu/ckp_test/ckp_constraints/334012_t_fulltext/restore.sql
/data4/weilu/ckp_test/ckp_constraints/334016_t_vector_index/restore.sql
/data4/weilu/ckp_test/ckp_mvcc_perf/334041_t_alter_case/restore.sql
/data4/weilu/ckp_test/ckp_mvcc_perf/334037_t_dml_history/restore.sql
/data4/weilu/ckp_test/ckp_mvcc_perf/334042_t_scale_rows/restore.sql
/data4/weilu/ckp_test/ckp_mvcc_perf/334039_t_truncate_case/restore.sql
/data4/weilu/ckp_test/ckp_mvcc_perf/334043_t_wide_32_cols/restore.sql
/data4/weilu/ckp_test/ckp_types/333982_t_int_signed/restore.sql
/data4/weilu/ckp_test/ckp_types/333987_t_strings/restore.sql
/data4/weilu/ckp_test/ckp_types/333994_t_vector_vecf32/restore.sql
```

不加 `--binary-mode=1` 时，MySQL 客户端先报：

```text
ASCII '\0' appeared in the statement, but this is not allowed unless option --binary-mode is enabled
```

加 `--binary-mode=1` 后，SQL 进入 MatrixOne，但 parser 报：

```text
ERROR 1064 (HY000) at line 4: SQL parser error
```

已单独建 issue：

```text
https://github.com/matrixorigin/matrixone/issues/24988
```

该 issue 正文已包含最小复现步骤、`nl`/`od`/Python NUL 检查和 load 失败表现。

### 15.8 当前结论

| 验证项 | 结论 |
|---|---|
| 专项造数脚本 | 通过，4 个专项库创建成功 |
| checkpoint list database/table | 通过，能识别 `ckp_*` 测试库和大部分表 |
| table 级 CSV dump | 大部分通过，部分失败见 #24985/#24986 |
| table 级 `restore.sql` 可用性 | 阻塞，31 个脚本含 NUL/内部类型编码，见 #24988 |
| load 到普通租户 | 阻塞，当前不能基于生成的 `restore.sql` 做有效恢复 |

本轮测试的核心结论：专项造数已完成，checkpoint 中也能读取这些测试对象；但 table 级 `--load-script` 当前存在基础 DDL 生成问题，导致恢复脚本不可用。该问题修复前，继续做普通租户批量 load、行数校验、DDL diff 和 checksum 的意义有限。

## 16. 2026-06-18 补充验证汇总

本节记录 2026-06-17 至 2026-06-18 针对 checkpoint dump 新增能力和修复 issue 的补充验证。验证环境仍为 `mo-srv-129`，checkpoint 数据目录为：

```text
/data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared
```

通用参数：

| 项目 | 值 |
|---|---|
| host | `127.0.0.1` |
| port | `6001` |
| source/sys user | `dump` |
| source/sys password | `111` |
| 普通恢复租户 | `acc01:test_account` |
| 普通恢复租户密码 | `111` |
| mo-tool | `/data4/weilu/matrixone/mo-tool` |
| 输出目录约束 | 所有 dump/load 产物放在 `/data4/weilu` 下 |

### 16.1 修复 issue 验证概览

| Issue | 测试对象 | 脚本/命令 | 产物路径 | 结论 |
|---|---|---|---|---|
| [#25030](https://github.com/matrixorigin/matrixone/issues/25030) | RANGE/LIST 分区表 restore.sql | `verify_partition_options_dump_restore.sh` | `/data4/weilu/verify_25015_25024_25030_20260618_104415/25030_partition_options` | 通过，已关闭 |
| [#25024](https://github.com/matrixorigin/matrixone/issues/25024) | view dump/restore | `verify_views.sh` | `/data4/weilu/verify_25015_25024_25030_20260618_104415/25024_views` | 通过，已关闭 |
| [#25015](https://github.com/matrixorigin/matrixone/issues/25015) | 混合类型、约束、索引大回归 | `run_checkpoint_dump_regression.sh` | `/data4/weilu/verify_25015_regression_20260618_160835` | 通过，已关闭 |
| [#25044](https://github.com/matrixorigin/matrixone/issues/25044) | 发布订阅 subscription DB checkpoint metadata | `verify_pubsub_dump_restore.sh` | `/data4/weilu/verify_pubsub_20260618_172945` | 通过，已关闭 |
| 账号边界专项 | 跨租户同名库表 dump/restore | `verify_account_boundary_dump_restore.sh` | `/data4/weilu/verify_account_boundary_20260618_114405` | 通过 |

### 16.2 #25030 分区表 restore.sql 验证

验证脚本：

```bash
/data4/weilu/verify_partition_options_dump_restore.sh \
  --host 127.0.0.1 \
  --port 6001 \
  --source-user dump \
  --source-password 111 \
  --target-user 'acc01:test_account' \
  --target-password 111 \
  --mo-tool /data4/weilu/matrixone/mo-tool \
  --ckp-data /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared \
  --drop-existing
```

覆盖对象：

| 表 | 覆盖点 |
|---|---|
| `t_range_partition` | `PARTITION BY RANGE` |
| `t_range_columns_partition` | `PARTITION BY RANGE COLUMNS` |
| `t_list_partition` | `PARTITION BY LIST` |
| `t_list_columns_partition` | `PARTITION BY LIST COLUMNS` |
| `t_linear_hash_partition` | `PARTITION BY LINEAR HASH` |
| `t_table_options` | table/column comment、`AUTO_INCREMENT`、unique key |

结果：

```text
table                      load_status  source_count  target_count  count_status  schema_status  data_status
t_range_partition          OK           5             5             OK            OK             OK
t_range_columns_partition  OK           4             4             OK            OK             OK
t_list_partition           OK           5             5             OK            OK             OK
t_list_columns_partition   OK           5             5             OK            OK             OK
t_linear_hash_partition    OK           5             5             OK            OK             OK
t_table_options            OK           3             3             OK            OK             OK
```

结论：

- `ckp dump --load-script` 生成的 RANGE/LIST 分区表 `restore.sql` 已可执行。
- 恢复到普通租户后 schema、行数、全量数据均一致。
- #25030 已 comment 验证通过并关闭。

### 16.3 #25024 view dump/restore 验证

验证脚本：

```bash
/data4/weilu/verify_views.sh \
  --host 127.0.0.1 \
  --port 6001 \
  --source-user dump \
  --source-password 111 \
  --target-user 'acc01:test_account' \
  --target-password 111 \
  --mo-tool /data4/weilu/matrixone/mo-tool \
  --ckp-data /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared \
  --prepare-script /data4/weilu/prepare_ckp_dump_coverage_data.sh \
  --db-prefix ckp \
  --scale 10000 \
  --drop-existing
```

覆盖 view 类型：

| 覆盖对象 | 说明 |
|---|---|
| `v_normal` / `v_empty` / `v_ctas` / `v_like` | 普通表、空表、CTAS、LIKE 表上的 view |
| `v_hash_partition` / `v_key_partition` / `v_cluster_by` | 分区表、cluster by 表上的 view |
| `v_reserved_name` | 特殊标识符表/列上的 view |
| `v_source_view` / `v_chain_base` / `v_chain_child` | view 依赖 view |
| `v_external` | view 依赖 external table |
| `v_parent` / `v_composite_keys` / `v_auto_inc` / `v_fk_join` | 约束类表上的 view |
| `v_fulltext_index` / `v_vector_index` | 特殊索引表上的 view |
| `v_types_wide` / `v_strings` / `v_binary_blob` / `v_temporal` / `v_vector` / `v_enum_set` / `v_uuid` | 多类型表上的 view |
| `v_dml_history` / `v_alter_case` / `v_scale_rows` | DML/MVCC 表上的 view |

结果：所有 view 均满足：

```text
dump_status=0
ddl_status=OK
no_load_data=OK
load_status=OK
count_status=OK
schema_status=OK
data_status=OK
```

结论：

- `REL_KIND=v` 对象已生成 `CREATE VIEW`，不再生成 `CREATE TABLE + LOAD DATA`。
- 恢复到普通租户后对象仍为 view，schema 和查询结果一致。
- #25024 已 comment 验证通过并关闭。

### 16.4 #25015 混合类型和约束大回归

最新验证命令：

```bash
/data4/weilu/run_checkpoint_dump_regression.sh \
  --host 127.0.0.1 \
  --port 6001 \
  --source-user dump \
  --source-password 111 \
  --target-user 'acc01:test_account' \
  --target-password 111 \
  --db-prefix ckp \
  --scale 10000 \
  --mo-tool /data4/weilu/matrixone/mo-tool \
  --ckp-data /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared \
  --prepare-script /data4/weilu/prepare_ckp_dump_coverage_data.sh \
  --out /data4/weilu/verify_25015_regression_20260618_112558 \
  --drop-existing \
  --data-compare-max-rows 20000
```

最新运行结果：

```text
summary: /data4/weilu/verify_25015_regression_20260618_112558/summary.tsv
restore: /data4/weilu/verify_25015_regression_20260618_112558/restore_summary.tsv
compare: /data4/weilu/verify_25015_regression_20260618_112558/compare_summary.tsv
restore summary has failures
compare summary has failures
CHECKPOINT_DUMP_REGRESSION_FAIL
```

上一轮已展开的残留问题：

| 表 | 阶段 | 现象 |
|---|---|---|
| `ckp_types.t_temporal` | restore/load | `ERROR 20101: internal error: the value type 22 is not support now` |
| `ckp_types.t_all_wide` | restore/load | `ERROR 20101: internal error: the value type 22 is not support now` |
| `ckp_types.t_array` | schema compare | `array(varchar(20))` 恢复成 `json` |

schema diff：

```diff
 CREATE TABLE `t_array` (
   `id` int NOT NULL,
-  `tags` array(varchar(20)) DEFAULT NULL,
+  `tags` json DEFAULT NULL,
   PRIMARY KEY (`id`)
 )
```

结论：

- #25015 初次在 `ckp_view` 分支重测后仍未通过，残留问题主要是 `value type 22` 和 `array(varchar(20))` 恢复成 `json`。
- 2026-06-18 下午基于修复版本重新执行完整回归，产物为 `/data4/weilu/verify_25015_regression_20260618_160835`。
- 最新结果为 `CHECKPOINT_DUMP_REGRESSION_OK`，`summary.tsv`、`restore_summary.tsv`、`compare_summary.tsv` 均无失败项。
- `value type 22` 错误未再出现，`t_array` schema diff 为空。
- 该 issue 已 comment 验证通过并关闭。

最新失败明细建议命令：

```bash
OUT=/data4/weilu/verify_25015_regression_20260618_160835

awk -F'\t' 'NR==1 || $4!="0" || $9!="OK"' "$OUT/summary.tsv" | column -t -s $'\t'
awk -F'\t' 'NR==1 || $4!="OK"' "$OUT/restore_summary.tsv" | column -t -s $'\t'
awk -F'\t' 'NR==1 || $6!="OK" || $7!="OK" || ($8!="OK" && $8!="SKIP")' "$OUT/compare_summary.tsv" | column -t -s $'\t'
```

### 16.5 发布订阅库表 checkpoint dump 验证

验证脚本：

```bash
/data4/weilu/verify_pubsub_dump_restore.sh \
  --host 127.0.0.1 \
  --port 6001 \
  --sys-user dump \
  --sys-password 111 \
  --mo-tool /data4/weilu/matrixone/mo-tool \
  --ckp-data /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared \
  --drop-existing
```

测试设计：

| 租户 | 角色 | 说明 |
|---|---|---|
| `ckppubsrc:test_account` | publisher | 创建发布源库，并发布整库/指定表 |
| `ckppubsub:test_account` | subscriber | 订阅 publisher 的整库/指定表 publication |
| `ckppubdst:test_account` | target | 用于恢复 dump 产物 |

重要预期：

- dump publisher 或 subscriber 的数据库到 C 租户后，只恢复普通数据库/表/数据/DDL。
- publication/subscription 关系不应被 checkpoint dump 迁移到 C 租户。
- 因此 target 侧不校验 `SHOW PUBLICATIONS` 或 `SHOW SUBSCRIPTIONS`。

#### 16.5.1 SQL 层发布订阅创建结果

publisher 租户可见：

```text
ckp_pubsub_20260618_105843_pub_all
ckp_pubsub_20260618_105843_pub_part
```

`SHOW PUBLICATIONS`：

```text
publication                           database                              tables        sub_account
ckp_pubsub_20260618_105843_pub_all    ckp_pubsub_20260618_105843_pub_all    *             ckppubsub
ckp_pubsub_20260618_105843_pub_part   ckp_pubsub_20260618_105843_pub_part   t_extra,t_pub ckppubsub
```

subscriber 租户可见：

```text
ckp_pubsub_20260618_105843_sub_all
ckp_pubsub_20260618_105843_sub_part
```

`SHOW SUBSCRIPTIONS ALL` 中两条 subscription `status=0`。

#### 16.5.2 checkpoint metadata 结果

执行：

```bash
/data4/weilu/matrixone/mo-tool ckp list \
  --type=databases \
  /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared \
  | grep 'ckp_pubsub_20260618_105843' || true
```

实际只看到 publisher 源库：

```text
414  ckp_pubsub_20260618_105843_pub_all   335771
414  ckp_pubsub_20260618_105843_pub_part  335779
```

未看到 subscriber 订阅库：

```text
ckp_pubsub_20260618_105843_sub_all   NOT_FOUND
ckp_pubsub_20260618_105843_sub_part  NOT_FOUND
```

已提 issue：

```text
https://github.com/matrixorigin/matrixone/issues/25044
```

#### 16.5.3 publisher 侧 dump 验证

publisher 整库发布源库表：

```text
ACCOUNT_ID  DATABASE                            TABLE   TABLE_ID  REL_KIND
414         ckp_pubsub_20260618_105843_pub_all  t_auto  335773    r
414         ckp_pubsub_20260618_105843_pub_all  t_hash  335774    r
414         ckp_pubsub_20260618_105843_pub_all  t_pk    335772    r
```

publisher 指定表发布源库表：

```text
ACCOUNT_ID  DATABASE                             TABLE    TABLE_ID  REL_KIND
414         ckp_pubsub_20260618_105843_pub_part  t_extra  335781    r
414         ckp_pubsub_20260618_105843_pub_part  t_pub    335780    r
414         ckp_pubsub_20260618_105843_pub_part  t_skip   335782    r
```

说明：`t_skip` 出现在 publisher 原库中是正常现象。publication selected table 只限制 subscriber 能看到哪些表，不改变 publisher 原库对象。

database 级 dump 结果：

```text
Dumped 3 tables to /data4/weilu/verify_pubsub_20260618_105843/manual_pub_dump/pub_all
Restore script written to /data4/weilu/verify_pubsub_20260618_105843/manual_pub_dump/pub_all/restore.sql

Dumped 3 tables to /data4/weilu/verify_pubsub_20260618_105843/manual_pub_dump/pub_part
Restore script written to /data4/weilu/verify_pubsub_20260618_105843/manual_pub_dump/pub_part/restore.sql
```

初次结论：

- publisher 源库可被 checkpoint metadata 识别。
- publisher 源库可执行 database 级 dump，并生成 `restore.sql`。
- subscriber 订阅库 SQL 层存在但 checkpoint metadata 不可见，导致 subscriber 侧 dump/restore 暂时无法验证。

后续修复验证：

- 2026-06-18 下午基于修复版本重新执行 `verify_pubsub_dump_restore.sh`，产物为 `/data4/weilu/verify_pubsub_20260618_172945`。
- checkpoint metadata 中 `publisher_all`、`publisher_part`、`subscriber_all`、`subscriber_part` 四个库均为 `FOUND`。
- 脚本最终输出 `PUBSUB_DUMP_RESTORE_OK`。
- #25044 已 comment 验证通过并关闭。

### 16.6 账号/租户边界专项验证

验证脚本：

```bash
/data4/weilu/verify_account_boundary_dump_restore.sh \
  --host 127.0.0.1 \
  --port 6001 \
  --sys-user dump \
  --sys-password 111 \
  --mo-tool /data4/weilu/matrixone/mo-tool \
  --ckp-data /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared \
  --drop-existing
```

测试目的：

- 验证 `ckp dump` 的隔离边界是 `mo-data/shared + account_id/database_id/table_id`。
- 验证工具不按 SQL 登录租户权限隔离。
- 验证不同租户同名库同名表不会因为只按名字查询而串数据。

测试设计：

| 租户 | 角色 | 数据 |
|---|---|---|
| `ckpbounda:test_account` | 源租户 A | 同名库同名表，数据标记 `tenant_a` |
| `ckpboundb:test_account` | 源租户 B | 同名库同名表，数据标记 `tenant_b` |
| `ckpboundc:test_account` | 目标租户 C | 分别恢复 A/B dump 产物 |

checkpoint metadata：

```text
tenant  account_name  account_id  marker_db                                   same_db                            db_id   table       table_id  status
A       ckpbounda     420         ckp_boundary_20260618_114405_acct_a_marker  ckp_boundary_20260618_114405_same  336399  t_boundary  336400    FOUND
B       ckpboundb     421         ckp_boundary_20260618_114405_acct_b_marker  ckp_boundary_20260618_114405_same  336403  t_boundary  336404    FOUND
```

dump 结果：

```text
case           tenant  dump_mode               dump_status  restore_sql
a_table_id     A       table-id                0            /data4/weilu/verify_account_boundary_20260618_114405/dumps/a_table_id/restore.sql
b_database_id  B       account-id+database-id  0            /data4/weilu/verify_account_boundary_20260618_114405/dumps/b_database_id/restore.sql
```

restore 结果：

```text
case           tenant  load_status
a_table_id     A       OK
b_database_id  B       OK
```

compare 结果：

```text
case           source_count  target_count  count_status  schema_status  data_status  isolation_status  expected_tag
a_table_id     3             3             OK            OK             OK           OK                tenant_a
b_database_id  3             3             OK            OK             OK           OK                tenant_b
```

结论：

- A 租户数据可通过 `--table-id=336400` dump 并恢复到 C。
- B 租户数据可通过 `--account-id=421 --database-id=336403` dump 并恢复到 C。
- A/B 同名库同名表没有串数据。
- restore 到 C 后只恢复普通库表，不保留源租户身份或权限关系。
- 该专项通过，最终标记：

```text
ACCOUNT_BOUNDARY_DUMP_RESTORE_OK
```

### 16.7 临时表、外表和发布订阅关系的当前预期

根据当前验证和研发说明，checkpoint dump 应按以下边界理解：

| 对象/关系 | 当前预期 |
|---|---|
| 普通表 | 应 dump/restore 数据和 DDL |
| view | 应 dump/restore `CREATE VIEW`，不生成 `LOAD DATA` |
| external table | 应明确支持或清晰报错；#25010 已验证 external 表当前可进入 checkpoint 并恢复数据 |
| temporary table | #25011 已验证临时表名恢复为用户可见名，restore 后作为普通表加载 |
| publication/subscription 关系 | 不随数据库 dump 迁移 |
| publisher 源库 | 作为普通库表 dump/restore |
| subscriber 订阅库 | #25044 修复后已能进入 checkpoint metadata；作为普通库表 dump/restore |
| account/user/grant 权限对象 | 当前不在本轮 checkpoint dump 数据对象验证范围内 |

### 16.8 当前未闭环或待补充项

| 项目 | 当前状态 | 后续动作 |
|---|---|---|
| #25015 混合类型恢复 | 已通过 | 2026-06-18 下午复测 `CHECKPOINT_DUMP_REGRESSION_OK`，已关闭 |
| #25044 subscription DB metadata | 已通过 | 2026-06-18 下午复测 subscriber DB 已进入 checkpoint metadata，已关闭 |
| subscriber 订阅库 dump/restore | 已解除阻塞 | `verify_pubsub_dump_restore.sh` 已修复 tenant user 解析并通过 |
| YEAR 类型 LOAD DATA | 新发现问题 | 已拆到 [#25066](https://github.com/matrixorigin/matrixone/issues/25066)，database 级回归里暂时跳过 YEAR 列 |
| publication/subscription 关系迁移 | 不要求迁移 | 测试脚本已按普通库表恢复预期调整 |
| sequence/default 依赖 | 方案中已设计，但当前报告未形成完整结果 | 后续单独展开 `t_sequence_nextval` / `t_sequence_default` |
| 系统库/内部库 dump | 未系统验证 | 后续补 `mo_catalog`、`mysql`、`system` 等 skip/报错预期 |
| 非表对象 | 未系统验证 | 需确认 UDF、stage、task、CDC/stream 是否属于 checkpoint dump 范围 |
| S3/COS 大规模 restore | 已有部分 TPCH 100G/S3 验证，但未全部自动化 | 后续纳入 nightly 或专项大表回归 |

### 16.9 database 级覆盖补充

前面的复杂类型、约束、分区、MVCC 覆盖主要通过逐表 `--table-id` 路径验证；大库场景则主要验证 TPCH/TPCC 这类 benchmark database 级 dump。为补齐“复杂覆盖库整体 database 级 dump/restore”的缺口，新增脚本：

```text
checkpoint-dump-test/verify_database_level_dump_restore.sh
```

覆盖目标：

| database | 覆盖重点 |
|---|---|
| `ckp_types` | 多数据类型、边界值、array/vector/temporal/blob/json 等 |
| `ckp_constraints` | PK/UK/FK/composite key/fulltext/vector index/comment/auto_increment |
| `ckp_tables` | empty/CTAS/LIKE/hash/key partition/cluster by/reserved name |
| `ckp_mvcc_perf` | DML history/truncate/alter/scale/wide table |

验证路径：

```bash
/data4/weilu/verify_database_level_dump_restore.sh \
  --host 127.0.0.1 \
  --port 6001 \
  --source-user dump \
  --source-password 111 \
  --target-user 'acc01:test_account' \
  --target-password 111 \
  --db-prefix ckp \
  --scale 10000 \
  --jobs 4 \
  --mo-tool /data4/weilu/matrixone/mo-tool \
  --ckp-data /data3/actions-runner/_work/mo-auto-test/mo-auto-test/head/mo-data/shared \
  --prepare-script /data4/weilu/prepare_ckp_dump_coverage_data.sh \
  --drop-existing \
  2>&1 | tee /data4/weilu/verify_database_level_dump_restore_run.log
```

脚本检查项：

- `mo-tool ckp dump --database-id=<DB_ID> --header --load-script --jobs=<N>` 是否成功。
- database 级 `restore.sql` 是否生成且无 NUL 字节。
- restore 到普通租户是否成功。
- source/target 表清单是否一致。
- source/target 行数是否一致。
- source/target `SHOW CREATE TABLE` 是否一致。
- 小表 source/target 全量数据是否一致。

最终通过标记：

```text
DATABASE_LEVEL_DUMP_RESTORE_OK
```

2026-06-22 重测结果：

```text
OUT=/data4/weilu/verify_db_level_20260622_112536
DATABASE_LEVEL_DUMP_RESTORE_OK
```

database 级 dump 结果：

| database | dump_status | restore | table list | count/schema/data |
|---|---:|---|---|---|
| `ckp_types` | 0 | OK | 14/14 OK | OK |
| `ckp_constraints` | 0 | OK | 11/11 OK | OK |
| `ckp_tables` | 0 | OK | 14/14 OK | OK |
| `ckp_mvcc_perf` | 0 | OK | 5/5 OK | OK |

本次结论：

- database 级 `--database-id` dump/restore 已覆盖复杂数据类型、约束、分区、宽表和 MVCC 场景，恢复到普通租户后表清单、行数、DDL 和小表全量数据均一致。
- `restore.sql` 均生成成功，且无 NUL 字节。
- `prepare_ckp_dump_coverage_data.sh` 针对当前环境做了兼容：
  - `COUNT(*) AS rows` 改为反引号别名，避免 `rows` 关键字解析问题。
  - `t_array` 会先探测当前 MO 是否支持原生 ARRAY 列语法；不支持时降级为 JSON，避免准备数据阶段阻塞。
  - YEAR 列临时从 `t_temporal`、`t_all_wide` 中移除，因为 `LOAD DATA` 写入 YEAR 会触发 `value type 22 is not support now`。
- YEAR 类型问题已拆分到 [#25066](https://github.com/matrixorigin/matrixone/issues/25066)，最小复现与 checkpoint dump 无关，属于 `LOAD DATA` 对 YEAR 类型支持问题。

### 16.10 当前总体结论

截至 2026-06-22：

- `ckp dump` 主流程在普通表、分区表、view、跨租户 ID 选择等方面已有可用验证。
- #25030、#25024、#25015、#25044 已验证通过并关闭。
- 跨租户同名库表验证通过，说明 `ckp dump` 以 `account_id/database_id/table_id` 作为数据选择边界，不依赖 SQL 登录租户权限。
- 发布订阅 publisher/subscriber 源库均可进入 checkpoint metadata；恢复时按普通库表恢复，不迁移 publication/subscription 关系。
- 逐表 `--table-id` 路径已覆盖复杂类型和结构；database 级复杂覆盖库 `--database-id` dump/restore 已在 `/data4/weilu/verify_db_level_20260622_112536` 验证通过。
- 当前 checkpoint dump 主流程剩余已知问题为 YEAR 类型 `LOAD DATA` 支持，已拆到 #25066，不再阻塞非 YEAR 覆盖回归。
- 剩余主要缺口是 S3/COS 端到端 restore、系统/内部库行为、sequence/default 依赖闭环、以及 UDF/stage/task/CDC/stream 等非表对象是否属于功能范围。
