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

## 10. 本轮结论

| 验证项 | 结论 |
|---|---|
| `mo-tool ckp list` 读取 checkpoint | 通过 |
| database 级 dump | 通过 |
| `--header` CSV 行数 | 通过 |
| `--load-script` 生成 `restore.sql` | 通过 |
| `restore.sql` 中 `parallel 'true'` 修复后可执行 | 通过 |
| 普通租户 load | 通过 |
| load 后行数校验 | 通过 |

本轮使用回归数据中的大表完成了端到端验证：checkpoint dump 成功，生成 CSV 和 `restore.sql` 成功，`restore.sql` load 到普通租户成功，恢复后行数和 dump 数据一致。
