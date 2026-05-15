# MatrixOne Bug 验证报告 — TPC-DS 及其他专项

**测试日期**: 2026-05-15  
**MO 版本 (main)**: commit `20346cae7` (2026-05-15)  
**MO 版本 (main, 129)**: commit `8b18b39` (2026-05-14)  
**测试环境**: 本地 MO (127.0.0.1:6001) + 10.222.1.129:6001  
**TPC-DS 数据**: 1G scale，10.222.1.129，数据目录 `/data3/tpcds/data/1G`  
**关联 issues**: #24208 #24209 #24210 #24211 #24212 #24215 #24216 #24219 #24220 #23598 #24333

---

## 一、测试结论概览

| Issue | 类型 | 描述 | Fix PR | 结论 |
|-------|------|------|--------|------|
| [#24208](https://github.com/matrixorigin/matrixone/issues/24208) | TPC-DS q34 | HAVING COUNT 结果多行（519 vs 471） | #24223 | ✅ 已修复 |
| [#24209](https://github.com/matrixorigin/matrixone/issues/24209) | TPC-DS q22 | ROLLUP/GROUPING 结果与 MySQL 不一致 | — | ⚠️ 非 MO 问题 |
| [#24210](https://github.com/matrixorigin/matrixone/issues/24210) | TPC-DS q78 | 多渠道聚合与 MySQL 不一致 | — | ⚠️ 非 MO 问题 |
| [#24211](https://github.com/matrixorigin/matrixone/issues/24211) | TPC-DS q79 | 聚合值错误 | #24290 | ✅ 已修复 |
| [#24212](https://github.com/matrixorigin/matrixone/issues/24212) | TPC-DS q50 | 退货延迟桶计数全部错误 | #24318 | ✅ 已修复 |
| [#24215](https://github.com/matrixorigin/matrixone/issues/24215) | TPC-DS q29 | 多次执行结果不一致（非确定性） | — | ✅ 已修复 |
| [#24216](https://github.com/matrixorigin/matrixone/issues/24216) | TPC-DS q66 | 丢失一行 + 结果非确定性 | — | ✅ 已修复 |
| [#24219](https://github.com/matrixorigin/matrixone/issues/24219) | SQL | EXISTS OR EXISTS 半连接语义错误 | #24223 | ✅ 已修复 |
| [#24220](https://github.com/matrixorigin/matrixone/issues/24220) | SQL | STDDEV_SAMP/VAR_SAMP 单行返回 0 而非 NULL | — | ✅ 已修复 |
| [#23598](https://github.com/matrixorigin/matrixone/issues/23598) | Parquet | LOAD parquet 文件报 internal error | — | ✅ 无法复现 |
| [#24333](https://github.com/matrixorigin/matrixone/issues/24333) | 稳定性 | lockservice 长时间持锁（10h+）/ 40+ waiters | #24345 | ✅ 已修复 |

---

## 二、TPC-DS 查询验证详情

### 测试环境

- **MO**: commit `8b18b39` (2026-05-14, main)
- **数据**: TPC-DS 1G，25 张表，总行数约 2,000 万行（store_sales: 2,880,404 行，inventory: 11,745,000 行等）
- **对比基准**: 本地 MySQL golden 结果（strict mode + NULLIF 加载）

### #24208 — q34: HAVING COUNT 结果行数错误

**Bug**: AP 并行 MergeGroup 路径重建 hash table 时未恢复 nullable group-key 元数据，导致 NULL customer group 被丢弃，计数偏高。

**验证结果**: 471 行，与 MySQL baseline 完全一致（原来返回 519 行）

```
c_last_name  c_first_name  c_salutation  c_preferred_cust_flag  ss_ticket_number  cnt
(null)       (null)        (null)        Y                      53729             15
(null)       (null)        (null)        Y                      217817            16
... (471 rows, exact match)
```

**Fix**: PR #24223 — 序列化 `keyNullable`，在 MergeGroup 构建 hash table 前恢复 nullable key 元数据

---

### #24211 — q79: 聚合值错误

**Bug**: 并行 LOAD DATA 路径下，空数值字段被物化为 NULL 而非 0，导致 `ss_coupon_amt`、`ss_net_profit` 聚合结果偏差。

**验证结果**: 100 行，与 MySQL baseline 完全一致

```
c_last_name  c_first_name  substr(s_city,1,30)  ss_ticket_number  amt      profit
(null)       (null)        Fairview             28219             1069.69  -30116.68
(null)       (null)        Fairview             158139            3721.39  -23039.01
... (100 rows, exact match)
```

**Fix**: PR #24290 — 并行 LOAD DATA 路径对空数值字段统一处理为 0

---

### #24212 — q50: 退货延迟桶计数全部错误

**Bug**: `ss_customer_sk` / `sr_customer_sk` 均为 nullable 列，但 `hashOnPk` 优化错误地应用于这两列，导致 join 结果行偏移，所有 6 行的桶计数均错误。

**验证结果**: 6 行，与 MySQL baseline 完全一致

```
s_store_name  s_company_id  s_city    30 days  31-60 days  61-90 days  91-120 days  >120 days
able          1             Midway    67       48          61          66           98
ation         1             Midway    70       51          50          61           109
bar           1             Midway    96       53          55          76           86
eing          1             Fairview  69       63          62          63           114
ese           1             Midway    58       57          55          54           106
ought         1             Midway    81       63          52          58           103
```

**Fix**: PR #24318 — `determineHashOnPK` 增加 `expr.Typ.NotNullable` 检查，nullable 列不走 HashOnPK 优化

---

### #24215 — q29: 结果非确定性

**Bug**: 多次执行返回不同的 `max(ss_quantity)` 值（10 次运行出现 6 种不同结果）。

**验证结果**: 多次运行结果完全一致，1 行，与 MySQL baseline 一致

```
i_item_id         i_item_desc                              s_store_id        s_store_name  store_sales_quantity  store_returns_quantity  catalog_sales_quantity
AAAAAAAAJMMBAAAA  Different, social ideas ought to enjoy.  AAAAAAAACAAAAAAA  able          10                    9                       99
```

---

### #24216 — q66: 丢失行 + 结果非确定性

**Bug**: 
1. `w_warehouse_name=''` 的仓库行被丢弃，返回 4 行而非 5 行
2. 每次执行的聚合数值不同

**验证结果**: 5 行，多次运行稳定

```
w_warehouse_name      w_warehouse_sq_ft  year  jan_sales     jan_net
(empty)               0                  2001  58503842.11   39575477.11   ← 原来丢失的行，已恢复
Bad cards must make.  621234             2001  56238489.97   40144605.02
Conventional childr   977787             2001  59656968.66   35885446.84
Doors canno           294242             2001  54004347.89   34871293.03
Important issues liv  138504             2001  46926924.33   33954546.31
```

**注**: 与 MySQL golden 文件存在两处**非 MO 问题**的差异：
- `ship_carriers` 列：MO 返回 `ORIENTAL,BOXBUNDLES`（正确，字符串字面量拼接）；MySQL golden 显示 `0`（MySQL 将 `||` 解释为逻辑 OR）
- `*_per_sq_foot` 列：MO 返回 8 位小数，MySQL golden 为 6 位，数值本身一致

---

## 三、非 TPC-DS 专项验证

### #24219 — EXISTS OR EXISTS 半连接语义错误

**Bug**: `WHERE EXISTS(...) OR EXISTS(...)` 中，`catalog_sales` 的匹配行数被当作普通行返回（返回 20 而非 1）。

**验证** (commit `20346cae7`):
```sql
SELECT count(*) FROM customer c
WHERE c.c_customer_sk = 12829
  AND (EXISTS (SELECT 1 FROM web_sales ws, date_dim ...)
       OR EXISTS (SELECT 1 FROM catalog_sales cs, date_dim ...));
-- Result: 1 ✅ (previously: 20)
```

**Fix**: PR #24223

---

### #24220 — STDDEV_SAMP / VAR_SAMP 单行返回 0 而非 NULL

**Bug**: 对单行输入，`stddev_samp` / `var_samp` 返回 `0` 而非标准定义的 `NULL`（样本标准差/方差在 n=1 时无意义）。

**验证** (commit `20346cae7`):
```sql
SELECT stddev_samp(x), var_samp(x) FROM (SELECT 5 AS x) t;
-- Result: NULL, NULL ✅ (previously: 0, 0)
```

---

### #23598 — LOAD parquet 文件报 internal error

**Bug**: `LOAD DATA INFILE ... FORMAT='parquet'` 时报 `internal error: convert go error to mo error reading parquet file metadata`。

**验证** (commit `20346cae7`, main):
```sql
LOAD DATA INFILE {'filepath'='/tmp/parquet_massive_conversions_3_17mb.parquet', 'format'='parquet'}
INTO TABLE parquet_massive_conversions;
-- Result: 30970 rows loaded, no error ✅
```

原始问题可能由损坏的 parquet 文件引起，当前版本无法复现。

---

### #24333 — lockservice 长时间持锁（3.0-dev 稳定性）

**Bug**: `wait too long` 持续时间达 13h41m，40+ waiters 被阻塞，触发 `no available CN server` 级联错误，报错速率升至 55K/h。

**验证** (稳定性集群 `mo-stb-d4d5dc0-202605131921`，2026-05-13 部署，含 fix):

| 指标 | 修复前 | 修复后 |
|------|--------|--------|
| 最长 wait too long | 13h41m | 2m42s |
| wait > 1h | 持续 10h+ | **0** |
| 最大 waiter 数 | 40+ | **1** |
| `wait active` errors | 持续 | **0** |
| 报错速率 | ~55K/h | ~763/h（正常锁竞争） |

**Fix**: PR #24345 (3.0-dev)，PR #24349 (main backport)

---

## 四、非 MO 问题说明

### #24209 (q22) 和 #24210 (q78) — MySQL 数据加载行为差异

这两个 issue 的结果差异**不是 MO bug**，根因是 MySQL `LOAD DATA` 在非严格 `sql_mode` 下将空数值字段静默转为 `0` 而非 `NULL`，导致用于对比的 MySQL 基准数据本身错误。

| 字段 | 受影响行数 | MO / PG / MySQL-strict | MySQL-lax (issue 环境) |
|------|-----------|----------------------|----------------------|
| `inv_quantity_on_hand` (q22) | 586,913 | NULL | 0 |
| `ss_customer_sk` (q78) | 129,752 | NULL | 0 |

- **q22**: MySQL-lax 的 `0` 值拉低 `AVG(qoh)` 约 6%，导致 TOP-100 偏移
- **q78**: MySQL-lax 产生虚假的 `customer_sk=0` 聚合桶，主导 TOP-100

MO、PostgreSQL、MySQL-strict 三者结果完全一致。

**建议 MySQL 侧修复**:
```sql
SET SESSION sql_mode='STRICT_TRANS_TABLES,...';
LOAD DATA ... SET col = NULLIF(col, '');
```

---

## 五、所有 issues 处理状态

| Issue | 状态 |
|-------|------|
| #24208 | ✅ Verified & Closed |
| #24209 | ✅ Investigated (non-MO) & Closed |
| #24210 | ✅ Investigated (non-MO) & Closed |
| #24211 | ✅ Verified & Closed |
| #24212 | ✅ Verified & Closed |
| #24215 | ✅ Verified & Closed |
| #24216 | ✅ Verified & Closed |
| #24219 | ✅ Verified & Closed |
| #24220 | ✅ Verified & Closed |
| #23598 | ✅ Cannot reproduce & Closed |
| #24333 | ✅ Verified on stability cluster & Closed |
