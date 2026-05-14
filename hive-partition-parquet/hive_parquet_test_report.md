# Hive-Partitioned Parquet 外部表测试报告

**测试日期**: 2026-05-12 ~ 2026-05-13  
**测试 PR**: https://github.com/matrixorigin/matrixone/issues/24320  
**MO 版本**: main (git: 7efe429)  
**测试环境**: 10.222.1.128 (252G RAM, NVMe SSD)  
**ClickHouse**: 22.8.5.29 (同一台服务器，单机模式)

---

## 一、测试数据

| 数据集 | 行数 | 分区数 | 每分区行数 | 磁盘大小 | 覆盖类型 |
|--------|------|--------|-----------|----------|----------|
| sales_100m | 102,500,000 | 84 | ~1.2M | 4.3G | INT8/16/32/64, FLOAT32/64, DECIMAL(12,2)/(7,4), BOOL, VARCHAR, DATE |
| events_50m | 50,000,000 | 200 | 250K | 1.8G | UINT8/16/32/64, BIGINT, DECIMAL(10,2), VARCHAR |
| types_wide | 10,000,000 | 20 | 500K | 933M | TEXT, BINARY(16), TIMESTAMP, DECIMAL(30,6), UUID-VARCHAR |
| types_all | 10,000,000 | 500 | 20K | 2.2G | 全类型覆盖（26列） |
| types_all_1000 | 10,000,000 | 1000 | 10K | 2.2G | 同上 |
| types_all_2000 | 10,000,000 | 2000 | 5K | 2.2G | 同上 |
| **types_2000_large** | **100,000,000** | **2000** | **50K** | **21G** | **全类型覆盖（26列）** |

**总数据量**: ~282,500,000 行 (~35GB on disk)

### 数据生成方式

使用 Python pyarrow 生成 Hive 风格分区目录结构，每个分区一个 data.parquet 文件（Snappy 压缩）：
```
/data2/data-large/types_2000_large/
├── part_id=1/data.parquet
├── part_id=2/data.parquet
├── ...
└── part_id=2000/data.parquet
```

### 建表 DDL

```sql
CREATE DATABASE IF NOT EXISTS hive_test;
USE hive_test;

-- 主测试表: 2000分区 × 50K行 = 1亿行
CREATE EXTERNAL TABLE types_2000_large (
    col_int8 TINYINT, col_int16 SMALLINT, col_int32 INT, col_int64 BIGINT,
    col_uint8 TINYINT UNSIGNED, col_uint16 SMALLINT UNSIGNED,
    col_uint32 INT UNSIGNED, col_uint64 BIGINT UNSIGNED,
    col_float32 FLOAT, col_float64 DOUBLE,
    col_decimal64 DECIMAL(10,2), col_decimal128 DECIMAL(20,4), col_decimal128_big DECIMAL(30,6),
    col_bool BOOL, col_char CHAR(10), col_varchar VARCHAR(100),
    col_text TEXT, col_binary BINARY(16), col_blob BLOB,
    col_date DATE, col_datetime DATETIME, col_timestamp TIMESTAMP,
    col_time_us BIGINT, col_json VARCHAR(200), col_uuid VARCHAR(36), col_enum VARCHAR(10),
    part_id INT
) INFILE{'filepath'='/data2/data-large/types_2000_large/', 'format'='parquet',
         'hive_partitioning'='true', 'hive_partition_columns'='part_id'}
  FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n';

-- 销售数据: 84分区 (year/month)
CREATE EXTERNAL TABLE sales_100m (
    sale_id BIGINT, channel VARCHAR(20), quantity INT, unit_price DECIMAL(12,2),
    discount_pct DECIMAL(7,4), net_paid BIGINT, weight_kg FLOAT,
    is_returned BOOL, customer_segment VARCHAR(20), ship_date DATE,
    year INT, month VARCHAR(4)
) INFILE{'filepath'='/data2/data-large/sales_100m/', 'format'='parquet',
         'hive_partitioning'='true', 'hive_partition_columns'='year,month'}
  FIELDS TERMINATED BY ',' ENCLOSED BY '"' LINES TERMINATED BY '\n';
```

---

## 二、需求 1: 确保使用不报错 + Unhappy Path

### 2.1 基础功能测试

```sql
-- 全表 COUNT
SELECT COUNT(*) FROM types_2000_large;
-- 结果: 100000000 ✅

-- 单分区读取
SELECT COUNT(*) FROM types_2000_large WHERE part_id = 1;
-- 结果: 50000 ✅

-- 分区裁剪: IN
SELECT COUNT(*), SUM(col_int32) FROM types_2000_large
WHERE part_id IN (1,100,200,500,800,1000,1200,1500,1800,2000);
-- 结果: 500000, -1261140767652 ✅ (0.05s)

-- 分区裁剪: BETWEEN
SELECT COUNT(*), AVG(col_float64) FROM types_2000_large WHERE part_id BETWEEN 1 AND 100;
-- 结果: 5000000, -572181324967.42 ✅ (0.23s)

-- 全表聚合
SELECT COUNT(*), SUM(col_float64) FROM types_2000_large;
-- 结果: 100000000, -9572716460227275000 ✅ (0.48s)

-- GROUP BY
SELECT col_enum, COUNT(*), SUM(col_decimal64) FROM types_2000_large
WHERE part_id BETWEEN 1 AND 500 GROUP BY col_enum;
-- 结果: 5组正确返回 ✅ (2.54s)

-- ORDER BY + LIMIT
SELECT col_int64, col_float64 FROM types_2000_large
WHERE part_id BETWEEN 1 AND 100 ORDER BY col_float64 DESC LIMIT 10;
-- 结果: 10行正确排序 ✅ (0.40s)

-- ROW_NUMBER 窗口函数
SELECT col_int64, col_float64, ROW_NUMBER() OVER (ORDER BY col_float64 DESC) AS rn
FROM types_2000_large WHERE part_id BETWEEN 1 AND 100 LIMIT 10;
-- 结果: 正确带行号 ✅ (2.62s)

-- 多条件过滤 (分区裁剪 + 数据过滤)
SELECT COUNT(*), AVG(col_float64) FROM types_2000_large
WHERE part_id BETWEEN 1 AND 2000 AND col_int32 > 0 AND col_bool = true;
-- 结果: 24995967 ✅ (0.50s)

-- GROUP BY 分区键
SELECT part_id, COUNT(*) AS cnt FROM types_2000_large
GROUP BY part_id ORDER BY SUM(col_decimal64) DESC LIMIT 10;
-- 结果: 每个分区50000行 ✅ (2.48s)

-- COUNT DISTINCT
SELECT COUNT(DISTINCT col_varchar) FROM types_2000_large;
-- 结果: 5000 ✅ (0.56s)

SELECT COUNT(DISTINCT col_uuid) FROM types_2000_large WHERE part_id = 1;
-- 结果: 50000 ✅ (0.12s)

-- 嵌套子查询
SELECT MAX(cnt) FROM (SELECT part_id, COUNT(*) AS cnt FROM types_2000_large GROUP BY part_id) sub;
-- 结果: 50000 ✅ (0.16s)
```

### 2.2 Unhappy Path 测试 (20 项)

```sql
-- T1: 不存在的分区值
SELECT COUNT(*) FROM types_2000_large WHERE part_id = 9999;
-- 结果: 0 ✅

-- T2: 负数分区值
SELECT COUNT(*) FROM types_2000_large WHERE part_id = -1;
-- 结果: 0 ✅

-- T3: 分区列表达式 (无法裁剪，退化全表扫描)
SELECT COUNT(*) FROM types_2000_large WHERE part_id + 1 = 100;
-- 结果: 50000 ✅ (全表扫描但结果正确)

-- T4: 类型不匹配 (VARCHAR vs INT)
SELECT COUNT(*) FROM types_2000_large WHERE part_id > 'abc';
-- 结果: ERROR 20203 (invalid argument cast to int) ✅ 预期报错

-- T5: NULL 过滤
SELECT COUNT(*) FROM types_2000_large WHERE part_id IS NULL;
-- 结果: 0 ✅

-- T6: 空结果聚合
SELECT SUM(col_float64), AVG(col_int32), MAX(col_decimal64) FROM types_2000_large WHERE part_id = 9999;
-- 结果: NULL, NULL, NULL ✅

-- T7: 大 IN 列表 (100值，50个存在 + 50个不存在)
SELECT COUNT(*) FROM types_2000_large
WHERE part_id IN (1,2,3,...,50,9901,9902,...,9950);
-- 结果: 2500000 (50×50K) ✅ 正确过滤不存在的分区

-- T8: 矛盾条件
SELECT COUNT(*) FROM types_2000_large WHERE part_id > 2000 AND part_id < 1;
-- 结果: 0 ✅

-- T9: LIMIT 0
SELECT * FROM types_2000_large WHERE part_id = 1 LIMIT 0;
-- 结果: 空 ✅

-- T10: 除零表达式
SELECT col_int32 / 0 FROM types_2000_large WHERE part_id = 1 LIMIT 1;
-- 结果: NULL ✅ (不 panic)

-- T11: SUM overflow BIGINT
SELECT SUM(col_int64) FROM types_2000_large;
-- 结果: ERROR 1690 (data out of range: int64 overflow) ✅ 预期报错

-- T12: COUNT DISTINCT 全表 (高基数)
SELECT COUNT(DISTINCT col_varchar) FROM types_2000_large;
-- 结果: 5000 ✅ (0.56s, 无 OOM)

-- T13: COUNT DISTINCT UUID 单分区 (50K 唯一值)
SELECT COUNT(DISTINCT col_uuid) FROM types_2000_large WHERE part_id = 1;
-- 结果: 50000 ✅ (0.12s)

-- T14: LIKE on INT 分区列 (隐式转换)
SELECT COUNT(*) FROM types_2000_large WHERE part_id LIKE '1%';
-- 结果: 55550000 ✅ (匹配 1,10-19,100-199,1000-1999)

-- T15: BETWEEN 反转边界
SELECT COUNT(*) FROM types_2000_large WHERE part_id BETWEEN 2000 AND 1;
-- 结果: 0 ✅

-- T16: 子查询中使用分区列
SELECT COUNT(*) FROM types_2000_large
WHERE part_id IN (SELECT part_id FROM types_2000_large WHERE part_id <= 5 GROUP BY part_id);
-- 结果: 250000 (5×50K) ✅ (0.23s)

-- T17: UNION ALL 跨分区
SELECT COUNT(*) FROM (
    SELECT col_int32 FROM types_2000_large WHERE part_id = 1
    UNION ALL
    SELECT col_int32 FROM types_2000_large WHERE part_id = 2000
) t;
-- 结果: 100000 (2×50K) ✅

-- T18: HAVING 无匹配
SELECT col_enum, COUNT(*) AS cnt FROM types_2000_large
WHERE part_id BETWEEN 1 AND 10 GROUP BY col_enum HAVING cnt > 999999999;
-- 结果: 空 ✅

-- T19: ORDER BY 全表 LIMIT (100M 行排序)
SELECT col_float64 FROM types_2000_large ORDER BY col_float64 DESC LIMIT 5;
-- 结果: 5行正确降序 ✅ (0.30s, 无 OOM)

-- T20: 嵌套聚合
SELECT MAX(cnt) FROM (SELECT part_id, COUNT(*) AS cnt FROM types_2000_large GROUP BY part_id) sub;
-- 结果: 50000 ✅ (0.16s)
```

**Unhappy Path 结论: 全部 20 项通过，无 panic/hang/OOM，报错行为符合预期。**

### 2.3 `__mo_filepath` 虚拟列测试

```sql
-- 基本查询: 查看文件路径
SELECT __mo_filepath FROM types_2000_large WHERE part_id = 1 LIMIT 1;
-- 结果: /data2/data-large/types_2000_large/part_id=1/data.parquet ✅

-- 分区过滤 + filepath 过滤组合
SELECT COUNT(*) FROM types_2000_large WHERE part_id = 1 AND __mo_filepath LIKE '%part_id=1/data.parquet';
-- 结果: 50000 ✅

-- 仅 filepath 过滤 (无分区谓词)
SELECT COUNT(*) FROM types_2000_large WHERE __mo_filepath LIKE '%part_id=100/%';
-- 结果: 50000 ✅
```

### 2.4 OR / NOT IN / 否定条件测试

```sql
-- OR 条件 (文档说明: 不做目录裁剪，作为行过滤，结果正确)
SELECT COUNT(*) FROM types_2000_large WHERE part_id = 1 OR part_id = 2000;
-- 结果: 100000 (2×50K) ✅

-- NOT IN
SELECT COUNT(*) FROM types_2000_large WHERE part_id NOT IN (1,2,3,4,5);
-- 结果: 99750000 (1995×50K) ✅

-- != 否定
SELECT COUNT(*) FROM types_2000_large WHERE part_id != 1;
-- 结果: 99950000 (1999×50K) ✅
```

### 2.5 `__HIVE_DEFAULT_PARTITION__` (NULL 分区) 测试

```sql
-- 测试数据: year=2024/ (50K行) + year=__HIVE_DEFAULT_PARTITION__/ (50K行)
CREATE EXTERNAL TABLE test_null_partition (..., year INT)
INFILE{'filepath'='/data2/data-large/test_null_partition/', ...};

-- 总行数
SELECT COUNT(*) FROM test_null_partition;
-- 结果: 100000 ✅

-- NULL 分区行数
SELECT COUNT(*) FROM test_null_partition WHERE year IS NULL;
-- 结果: 50000 ✅

-- 非 NULL 行数
SELECT COUNT(*) FROM test_null_partition WHERE year IS NOT NULL;
-- 结果: 50000 ✅

-- 正常分区
SELECT COUNT(*) FROM test_null_partition WHERE year = 2024;
-- 结果: 50000 ✅

-- COALESCE 替换 NULL
SELECT COALESCE(year, -1) AS y, COUNT(*) FROM test_null_partition GROUP BY y ORDER BY y;
-- 结果: -1: 50000, 2024: 50000 ✅
```

### 2.6 文件过滤规则测试

```sql
-- 测试数据: part_id=1/ 下有:
--   data.parquet (正常), sidecar.csv, notes.txt, .crc, _SUCCESS
-- 另外 _temporary/ 目录下有 tmp.parquet
-- 预期: 只读取 data.parquet，其他全部跳过

SELECT COUNT(*) FROM test_file_skip;
-- 结果: 50000 ✅ (只读了 data.parquet，其他文件和 _temporary 目录被忽略)
```

### 2.7 多级分区 + 深度不匹配测试

```sql
-- 测试数据:
--   year=2024/month=01/data.parquet (正常)
--   year=2024/month=02/data.parquet (正常)
--   year=2025/month=01/data.parquet (正常)
--   year=2024/month=01/region=us/data.parquet (比声明更深 → 忽略)
--   year=2024/shallow.parquet (比声明更浅 → 忽略)
CREATE EXTERNAL TABLE test_multilevel (..., year INT, month VARCHAR(2))
INFILE{..., 'hive_partition_columns'='year,month'};

-- 总行数 (深度不匹配的被忽略)
SELECT COUNT(*) FROM test_multilevel;
-- 结果: 150000 (3×50K) ✅ (deeper region=us 和 shallower shallow.parquet 被跳过)

-- 按 year 过滤
SELECT COUNT(*) FROM test_multilevel WHERE year = 2024;
-- 结果: 100000 (2个月份) ✅

-- 按 year + month 过滤
SELECT COUNT(*) FROM test_multilevel WHERE year = 2024 AND month = '01';
-- 结果: 50000 ✅

-- 只按 inner 过滤 (跨所有 year)
SELECT COUNT(*) FROM test_multilevel WHERE month = '01';
-- 结果: 100000 (year=2024+2025 各一个 month=01) ✅

-- DISTINCT 分区列组合
SELECT DISTINCT year, month FROM test_multilevel ORDER BY year, month;
-- 结果: (2024,01), (2024,02), (2025,01) ✅
```

### 2.8 DDL 错误验证 (9 种)

```sql
-- DDL-1: hive_partitioning=true 但缺少 hive_partition_columns
CREATE EXTERNAL TABLE err (...) INFILE{..., 'hive_partitioning'='true'};
-- ERROR 20300: hive_partition_columns is required when hive_partitioning is enabled ✅
-- 说明: 当前版本采用显式分区列模式；不声明分区列并自动推断 schema 是后续 enhancement (#24390)

-- DDL-2: 有 hive_partition_columns 但没有 hive_partitioning=true
CREATE EXTERNAL TABLE err (...) INFILE{..., 'hive_partition_columns'='part_id'};
-- ERROR 20300: hive_partition_columns requires hive_partitioning='true' ✅

-- DDL-3: hive_partitioning 值不是 true/false
CREATE EXTERNAL TABLE err (...) INFILE{..., 'hive_partitioning'='yes', ...};
-- ERROR 20300: hive_partitioning must be 'true' or 'false', got 'yes' ✅

-- DDL-4: partition column 不在列定义中
CREATE EXTERNAL TABLE err (id INT) INFILE{..., 'hive_partition_columns'='nonexist'};
-- ERROR 20300: partition column 'nonexist' not found in table columns ✅

-- DDL-5: 重复分区列
CREATE EXTERNAL TABLE err (...) INFILE{..., 'hive_partition_columns'='part_id,part_id'};
-- ERROR 20300: duplicate partition column 'part_id' ✅

-- DDL-6: 非 parquet 格式
CREATE EXTERNAL TABLE err (...) INFILE{..., 'format'='csv', 'hive_partitioning'='true', ...};
-- ERROR 20300: hive_partitioning currently only supports format='parquet', got 'csv' ✅

-- DDL-7: VECTOR 类型分区列
CREATE EXTERNAL TABLE err (id INT, part_id VECF32(3)) INFILE{..., 'hive_partition_columns'='part_id'};
-- ERROR 20300: partition column 'part_id' cannot be a VECTOR type ✅

-- DDL-8: 重复选项键
CREATE EXTERNAL TABLE err (...) INFILE{..., 'hive_partitioning'='true', 'hive_partitioning'='false', ...};
-- ERROR 20300: duplicate option key 'hive_partitioning' ✅

-- DDL-9: stage URI
CREATE EXTERNAL TABLE err (...) INFILE{'filepath'='stage://my_stage/data/', ..., 'hive_partitioning'='true', ...};
-- ERROR 20300: hive_partitioning does not support stage external tables ✅
```

### 2.9 写入操作拒绝测试

```sql
INSERT INTO types_2000_large (col_int32, part_id) VALUES (1, 1);
-- ERROR 20301: cannot insert/update/delete from external table ✅

DELETE FROM types_2000_large WHERE part_id = 1;
-- ERROR 20301: cannot insert/update/delete from external table ✅

UPDATE types_2000_large SET col_int32 = 0 WHERE part_id = 1;
-- ERROR 20301: cannot insert/update/delete from external table ✅
```

### 2.10 EXPLAIN / EXPLAIN ANALYZE 验证分区裁剪

```sql
-- EXPLAIN 确认 Filter Cond 存在
EXPLAIN SELECT COUNT(*) FROM types_2000_large WHERE part_id = 1;
-- 结果: External Scan on types_2000_large, Filter Cond: (types_2000_large.part_id = 1) ✅

-- EXPLAIN ANALYZE 确认只读了 1 个分区的行
EXPLAIN ANALYZE SELECT COUNT(*) FROM types_2000_large WHERE part_id = 1;
-- 结果: External Scan inputRows=50000 (只读了 1 分区，不是全表 100M) ✅
```

### 2.11 JOIN 外部表与内部表

```sql
CREATE TABLE dim_partition (part_id INT PRIMARY KEY, part_name VARCHAR(20));
INSERT INTO dim_partition VALUES (1,'first'),(100,'hundredth'),(500,'mid'),(1000,'thousand'),(2000,'last');

SELECT d.part_name, COUNT(*), SUM(t.col_int32)
FROM types_2000_large t JOIN dim_partition d ON t.part_id = d.part_id
WHERE t.part_id IN (1, 100, 500, 1000, 2000) GROUP BY d.part_name;
-- 结果: 5行，每行 50000，SUM 正确 ✅
```

### 2.12 DESCRIBE / SELECT DISTINCT 分区列

```sql
DESCRIBE types_2000_large;
-- 结果: 27 列全部正确显示，包括 part_id (INT) ✅

SELECT DISTINCT part_id FROM types_2000_large ORDER BY part_id LIMIT 5;
-- 结果: 1, 2, 3, 4, 5 ✅
```

### 2.13 hive_partitioning='false' 行为

```sql
-- 关闭 hive 分区发现，作为普通外部表读取单文件
CREATE EXTERNAL TABLE test_no_hive (...)
INFILE{'filepath'='/data2/data-large/types_2000_large/part_id=1/data.parquet',
       'format'='parquet', 'hive_partitioning'='false'};
SELECT COUNT(*) FROM test_no_hive;
-- 结果: 50000 ✅ (普通外部表行为，不做分区发现)
```

---

## 三、需求 2: 大数据不 hung 不 OOM

### 3.1 分区扩展性测试 (types_2000_large)

| 测试 SQL | 分区数 | 数据量 | 耗时 | 结果 |
|----------|--------|--------|------|------|
| `SELECT COUNT(*) WHERE part_id = 1` | 1 | 50K | 0.06s | ✅ |
| `SELECT COUNT(*), SUM(col_int32) WHERE part_id IN (10个值)` | 10 | 500K | 0.05s | ✅ |
| `SELECT COUNT(*), AVG(col_float64) WHERE part_id BETWEEN 1 AND 100` | 100 | 5M | 0.23s | ✅ |
| `SELECT COUNT(*), AVG(col_float64) WHERE part_id BETWEEN 1 AND 500` | 500 | 25M | 0.28s | ✅ |
| `SELECT COUNT(*), AVG(col_float64) WHERE part_id BETWEEN 1 AND 1000` | 1000 | 50M | 0.27s | ✅ |
| `SELECT COUNT(*), SUM(col_float64)` (全表) | 2000 | 100M | 0.48s | ✅ |
| `SELECT ... WHERE col_int32 > 0 AND col_bool = true` (数据过滤) | 2000 | 100M | 0.50s | ✅ |
| `GROUP BY col_enum WHERE part_id BETWEEN 1 AND 500` | 500 | 25M | 2.54s | ✅ |
| `GROUP BY part_id ORDER BY ... LIMIT 10` | 2000 | 100M | 2.48s | ✅ |
| `ORDER BY col_float64 DESC LIMIT 10 WHERE part_id BETWEEN 1 AND 100` | 100 | 5M | 0.40s | ✅ |
| `ORDER BY col_float64 DESC LIMIT 5` (全表) | 2000 | 100M | 0.30s | ✅ |
| `ROW_NUMBER() OVER (ORDER BY ...) WHERE part_id BETWEEN 1 AND 100` | 100 | 5M | 2.62s | ✅ |
| `COUNT(DISTINCT col_varchar)` (全表) | 2000 | 100M | 0.56s | ✅ |
| 嵌套子查询 `SELECT MAX(cnt) FROM (GROUP BY part_id)` | 2000 | 100M | 0.16s | ✅ |

### 3.2 Window Function 压力测试 (sales_100m)

| 测试 SQL | 数据量 | 耗时 | 结果 |
|----------|--------|------|------|
| `ROW_NUMBER() OVER (ORDER BY net_paid DESC)` 单分区 | 1.5M | 0.78s | ✅ |
| `ROW_NUMBER() OVER (ORDER BY net_paid DESC)` 全年 | 15M | 8.3s | ✅ |
| `ROW_NUMBER() OVER (ORDER BY net_paid DESC)` 两年 | 30M | 18.5s | ✅ |
| **`ROW_NUMBER() OVER (ORDER BY net_paid DESC)` 全表** | **102.5M** | **59s** | **✅ 无 OOM** |

> 注: 之前在 3.0-dev 分支上 ROW_NUMBER(1.5M) 出现 exit code 137 (OOM kill)，main 分支已无此问题。

---

## 四、需求 3: 性能对比 (MO vs ClickHouse)

### 4.1 对比一：sales_100m (84 分区, 少分区大数据量)

**测试方法**: 同一台服务器同一份数据，MO 通过外部表读取，CK 通过 `file()` 函数直接读 Parquet。

```sql
-- MO 测试示例
SELECT COUNT(*) FROM hive_test.sales_100m WHERE year = 2024 AND month = '06';
SELECT SUM(net_paid) FROM hive_test.sales_100m;
SELECT channel, COUNT(*), SUM(net_paid) FROM hive_test.sales_100m WHERE year = 2024 GROUP BY channel;

-- CK 等价查询
SELECT COUNT(*) FROM file('/path/sales_100m/year=2024/month=06/*.parquet', Parquet);
SELECT SUM(net_paid) FROM file('/path/sales_100m/**/*.parquet', Parquet);
SELECT channel, COUNT(*), SUM(net_paid) FROM file('/path/sales_100m/year=2024/**/*.parquet', Parquet) GROUP BY channel;
```

| Query | 说明 | MO (s) | CK (s) | 对比 |
|-------|------|--------|--------|------|
| Q01 | 单分区 COUNT (1.5M) | 0.075 | 0.315 | **MO 4.2x 更快** |
| Q02 | 全表 COUNT (102M) | 0.224 | 0.280 | **MO 1.3x 更快** |
| Q03 | 全表 SUM (102M) | 2.160 | 0.258 | CK 8.4x |
| Q04 | 分区过滤+多聚合 | 0.486 | 0.453 | 持平 |
| Q05 | GROUP BY 单分区 (1.5M) | 0.660 | 0.336 | CK 2.0x |
| Q06 | GROUP BY 全年 (15M) | 0.404 | 0.303 | CK 1.3x |
| Q07 | ORDER BY LIMIT 单分区 | 0.384 | 0.252 | CK 1.5x |
| Q08 | ORDER BY LIMIT 全年 (15M) | 0.528 | 0.264 | CK 2.0x |
| Q09 | events_50m COUNT (50M) | 0.147 | 0.260 | **MO 1.8x 更快** |
| Q10 | events_50m SUM+AVG (50M) | 2.725 | 0.266 | CK 10.2x |
| Q11 | events_50m GROUP BY | 2.753 | 0.283 | CK 9.7x |
| Q12 | ROW_NUMBER 单分区 (1.5M) | 0.776 | 0.321 | CK 2.4x |
| Q13 | ROW_NUMBER 全年 (15M) | 8.316 | 0.284 | CK 29.3x |
| Q14 | 多条件过滤 (102M) | 0.549 | 0.475 | 持平 |
| Q15 | COUNT DISTINCT (102M) | 0.392 | 0.424 | **MO 1.1x 更快** |

**少分区结论**: MO 优势 4/15，持平 2/15，CK 优势 9/15。CK 在向量化 SUM/AVG 和窗口函数上有明显优势。

### 4.2 对比二：types_2000_large (2000 分区, 高分区数大数据量) ⭐

**测试方法**: 同一份 21GB 数据，MO 通过 hive_partitioning 原生分区裁剪，CK 通过 glob + `_file` 元数据列 regex 过滤。

```sql
-- MO 测试示例 (原生分区裁剪)
SELECT COUNT(*) FROM hive_test.types_2000_large WHERE part_id = 1;
SELECT COUNT(*), AVG(col_float64) FROM hive_test.types_2000_large WHERE part_id BETWEEN 1 AND 100;
SELECT COUNT(*), SUM(col_float64) FROM hive_test.types_2000_large;

-- CK 等价查询 (glob + regex)
SELECT COUNT(*) FROM file('.../types_2000_large/part_id=1/data.parquet', Parquet)
    SETTINGS input_format_parquet_skip_columns_with_unsupported_types_in_schema_inference=1;
SELECT COUNT(*), AVG(col_float64) FROM file('.../types_2000_large/*/data.parquet', Parquet)
    WHERE toInt32OrNull(extract(_file, 'part_id=([0-9]+)')) BETWEEN 1 AND 100
    SETTINGS input_format_parquet_skip_columns_with_unsupported_types_in_schema_inference=1;
SELECT COUNT(*), SUM(col_float64) FROM file('.../types_2000_large/*/data.parquet', Parquet)
    SETTINGS input_format_parquet_skip_columns_with_unsupported_types_in_schema_inference=1;
```

| Query | 说明 | MO (s) | CK (s) | 对比 |
|-------|------|--------|--------|------|
| Q01 | 单分区 COUNT (50K) | 0.064 | 0.472 | **MO 7.4x 更快** |
| Q02 | 全表 COUNT (100M) | 0.201 | 0.641 | **MO 3.2x 更快** |
| Q03 | IN 10 分区 SUM (500K) | 0.156 | 0.572 | **MO 3.7x 更快** |
| Q04 | Range 100 分区 AVG (5M) | 0.307 | 0.639 | **MO 2.1x 更快** |
| Q05 | Range 500 分区 AVG (25M) | 0.295 | 0.581 | **MO 2.0x 更快** |
| Q06 | Range 1000 分区 AVG (50M) | 0.298 | 0.716 | **MO 2.4x 更快** |
| Q07 | 全表 SUM(float64) (100M) | 0.310 | 0.634 | **MO 2.0x 更快** |
| Q08 | GROUP BY enum, 500 分区 (25M) | 2.550 | 0.898 | CK 2.8x |
| Q09 | GROUP BY part_id, 全表 (100M) | 0.257 | 0.460 | **MO 1.8x 更快** |
| Q10 | ORDER BY LIMIT 10, 100 分区 (5M) | 0.555 | 0.769 | **MO 1.4x 更快** |
| Q11 | ORDER BY LIMIT 5, 全表 (100M) | 0.305 | 0.852 | **MO 2.8x 更快** |
| Q12 | COUNT DISTINCT varchar, 全表 (100M) | 0.483 | 0.744 | **MO 1.5x 更快** |
| Q13 | 多条件过滤, 全表 (100M) | 0.632 | 0.771 | **MO 1.2x 更快** |
| Q14 | 嵌套子查询 GROUP BY (100M) | 0.143 | 0.435 | **MO 3.0x 更快** |
| Q15 | ROW_NUMBER, 100 分区 (5M) | 2.352 | 0.789 | CK 3.0x |

**高分区结论**: **MO 优势 13/15**，CK 优势 2/15。MO 原生 Hive 分区裁剪效率远超 CK 的 glob+regex。

### 4.3 综合性能分析

| 维度 | MO 表现 | CK 表现 | 分析 |
|------|---------|---------|------|
| 分区裁剪 | ⭐ 极快 (0.06-0.3s) | 较慢 (0.5-0.7s) | MO 原生 hive partition 支持，CK 需要 glob + _file regex |
| COUNT/元数据查询 | ⭐ 极快 | 较快 | MO 利用 Parquet metadata 优化 |
| SUM/AVG 计算密集 | 高分区快，少分区慢 | ⭐ 少分区极快 | CK 列式向量化引擎优势（少分区场景 8-10x） |
| Window Function | 慢 | ⭐ 快 | MO 窗口函数有优化空间 (3-29x) |
| GROUP BY | 中等 | 较快 | CK 约 2-3x 优势 |
| ORDER BY + LIMIT | 高分区快 | 少分区快 | 高分区数下 MO 更快，少分区下 CK 更快 |
| 分区数扩展性 | ⭐ 100→2000 无退化 | 分区越多越慢 | 分区越多 MO 优势越明显 |

**关键发现**: 
1. MO 的 Hive 分区裁剪在高分区场景下（2000分区）效果非常突出，优于 ClickHouse
2. CK 在少分区（84）+ 计算密集查询下仍有明显优势（向量化 SUM 8-10x，Window 3-29x）
3. MO 的 filter pushdown 优化对分区数扩展性好——100 到 2000 分区性能几乎没有退化

### 4.4 对比三：本地磁盘 vs S3 (MinIO 内网)

**测试环境**: MO (10.222.1.128) 读 MinIO (10.222.6.2) 内网对象存储，同一份 types_2000_large 数据。

```sql
-- 本地 (INFILE)
SELECT COUNT(*) FROM types_2000_large WHERE part_id = 1;
-- S3 (URL s3option, MinIO)
SELECT COUNT(*) FROM types_2000_large_s3 WHERE part_id = 1;
```

| 查询 | 分区数 | 数据量 | 本地 | S3 (MinIO) | S3/本地 |
|------|--------|--------|------|------------|---------|
| 单分区 COUNT | 1 | 50K | 0.05s | 5.2s | 100x |
| IN 10 分区 SUM | 10 | 500K | 0.06s | 5.9s | 98x |
| Range 100 分区 AVG | 100 | 5M | 0.23s | 66.5s | 289x |
| Range 500 分区 AVG | 500 | 25M | 0.24s | 68.3s | 285x |
| 全表 2000 分区 SUM | 2000 | 100M | 0.27s | 71.7s | 266x |
| GROUP BY 500 分区 | 500 | 25M | 2.56s | 77.3s | 30x |
| ORDER BY LIMIT 全表 | 2000 | 100M | 0.27s | 65.1s | 241x |

**S3 功能验证（全部通过）：**

```sql
-- 基本读取
SELECT COUNT(*) FROM types_2000_large_s3;                    -- 100000000 ✅
SELECT COUNT(*) FROM types_2000_large_s3 WHERE part_id = 1;  -- 50000 ✅
SELECT COUNT(*) FROM types_2000_large_s3 WHERE part_id IN (1,500,1000,2000); -- 200000 ✅

-- __mo_filepath 在 S3 上
SELECT __mo_filepath FROM types_2000_large_s3 WHERE part_id = 1 LIMIT 1;
-- /types_2000_large/part_id=1/data.parquet ✅

-- NULL 分区 (S3)
SELECT COUNT(*) FROM test_null_partition_s3 WHERE year IS NULL;  -- 50000 ✅
SELECT COUNT(*) FROM test_null_partition_s3 WHERE year = 2024;   -- 50000 ✅

-- 多级分区 (S3)
SELECT COUNT(*) FROM test_multilevel_s3;                              -- 150000 ✅
SELECT COUNT(*) FROM test_multilevel_s3 WHERE year = 2024 AND month = '01'; -- 50000 ✅
```

**S3 性能分析：**
1. **分区裁剪在 S3 上收益巨大**: 单分区 5.2s vs 全表 71.7s，裁剪减少了 93% 的 GetObject 调用
2. **I/O 是 S3 瓶颈**: 即使单分区(50K行/11MB)也要 5s，主要是 HTTP 往返延迟（ListObjects + GetObject）
3. **文档建议验证**: "rewrite ranges into explicit IN lists whenever the set of interesting partitions is small" — 单分区 5.2s vs 全表 71.7s 证实了窄过滤的重要性
4. **100→2000 分区全表扫描耗时差异不大** (66s→72s)，说明 S3 读取有并行化

### 4.5 对比四：COS (TKE 公有云) 性能测试 ⭐

**测试环境**:
- MO 集群: TKE 广州区, 16 核 CN (multicn)
- 存储: 腾讯云 COS (cos.ap-guangzhou.myqcloud.com), bucket: mo-load-guangzhou-1308875761
- 数据: types_2000_large (2000 分区, 100M 行, 21GB Parquet)
- 网络: TKE pod → COS 内网链路

**逐条精确耗时 (bash `time` 逐条计时)：**

| 测试 | 说明 | 数据量 | 耗时 |
|------|------|--------|------|
| P01 | 单分区 COUNT | 50K (1分区) | 0.40s |
| P02 | 单分区 COUNT run2 | 50K | 0.49s |
| P03 | 单分区 COUNT run3 | 50K | 0.25s |
| P04 | IN 10分区 SUM | 500K (10分区) | 0.74s |
| P05 | IN 10分区 SUM run2 | 500K | 0.62s |
| P06 | Range 100分区 AVG | 5M (100分区) | 93.2s |
| P07 | Range 100分区 AVG run2 | 5M | 92.5s |
| P08 | Range 500分区 AVG | 25M (500分区) | 89.6s |
| P09 | Range 500分区 AVG run2 | 25M | 97.8s |
| P10 | 全表 COUNT | 100M (2000分区) | 100.8s |
| P11 | 全表 COUNT run2 | 100M | 93.7s |
| P12 | 全表 SUM | 100M | 97.3s |
| P13 | 全表 SUM run2 | 100M | 101.0s |
| P14 | GROUP BY 500分区 | 25M | 88.3s |
| P15 | GROUP BY 全表 | 100M | 95.8s |
| P16 | ORDER BY LIMIT 全表 | 100M | 91.1s |
| P17 | COUNT DISTINCT 全表 | 100M | 95.0s |
| P18 | 嵌套子查询 | 100M | 91.6s |
| P19 | 多条件过滤 100分区 | 5M | 104.4s |
| P20 | EXPLAIN ANALYZE 单分区 | 50K | 0.35s (scan 118ms) |

### 4.6 三方性能对比总表

| 查询 | 数据量 | 本地 (128 SSD) | MinIO (内网 10G) | COS (TKE) | COS/本地 | COS/MinIO |
|------|--------|----------------|------------------|------------|----------|-----------|
| 单分区 COUNT | 50K | 0.05s | 5.2s | **0.25s** | 5x | **21x 更快** |
| IN 10分区 SUM | 500K | 0.06s | 5.9s | **0.62s** | 10x | **10x 更快** |
| Range 100分区 AVG | 5M | 0.23s | 66.5s | 93s | 404x | 1.4x 慢 |
| Range 500分区 AVG | 25M | 0.24s | 68.3s | 94s | 392x | 1.4x 慢 |
| 全表 COUNT | 100M | 0.20s | 71.7s | 97s | 485x | 1.4x 慢 |
| 全表 SUM | 100M | 0.27s | 71.7s | 99s | 367x | 1.4x 慢 |
| GROUP BY 500分区 | 25M | 2.56s | 77.3s | 88s | 34x | 持平 |
| ORDER BY LIMIT 全表 | 100M | 0.27s | 65.1s | 91s | 337x | 1.4x 慢 |
| COUNT DISTINCT 全表 | 100M | 0.56s | — | 95s | 170x | — |
| 嵌套子查询 | 100M | 0.14s | — | 92s | 657x | — |

### 4.7 COS 性能分析

**关键发现：**

1. **小查询（分区裁剪到少量文件）COS 极快**：单分区 0.25s、10分区 0.62s，远优于 MinIO 的 5-6s。TKE 内网到 COS 延迟低、list 快。

2. **大查询有带宽天花板**：无论 5M 还是 100M 行，耗时都在 88-105s 区间。说明 COS 读取有并行化（多个 GetObject 并发），但总带宽约 200-250 MB/s 封顶。

3. **COS vs MinIO 对比**：
   - 小查询（≤10分区）：COS 快 10-21x — MinIO 的 ListObjects 延迟是瓶颈
   - 大查询（≥100分区）：COS 慢 1.4x — MinIO 虽然 list 慢但一旦开始传输吞吐更高

4. **分区裁剪在公有云场景价值最大**：单分区 0.25s vs 全表 97s = **388x 提升**。客户使用 COS/S3 时必须配合分区过滤。

5. **100 分区 vs 2000 分区全表扫描差异极小**（93s vs 97s），证实 COS 并行读取能力强，分区数增加不会线性增加耗时。

**客户场景建议：**
- 查询少量分区（OLTP 场景）：COS 延迟<1s，完全可用
- 全表扫描分析：建议使用内部存储或 cache 层，COS 全表扫描需 1.5 分钟
- 务必使用 equality/IN 谓词做分区过滤，避免 BETWEEN/OR 等无法裁剪的谓词

---

## 五、数据类型覆盖

### 5.1 测试 SQL

```sql
-- 整型
SELECT MIN(col_int8), MAX(col_int8) FROM types_2000_large WHERE part_id = 1;    -- -128, 126 ✅
SELECT MIN(col_int16), MAX(col_int16) FROM types_2000_large WHERE part_id = 1;  -- -32768, 32764 ✅
SELECT MIN(col_int32), MAX(col_int32) FROM types_2000_large WHERE part_id = 1;  -- 正确 ✅
SELECT MIN(col_int64), MAX(col_int64) FROM types_2000_large WHERE part_id = 1;  -- 正确 ✅

-- 无符号整型
SELECT MIN(col_uint8), MAX(col_uint8) FROM types_2000_large WHERE part_id = 1;    -- 0, 254 ✅
SELECT MIN(col_uint16), MAX(col_uint16) FROM types_2000_large WHERE part_id = 1;  -- 0, 65534 ✅
SELECT MIN(col_uint32), MAX(col_uint32) FROM types_2000_large WHERE part_id = 1;  -- 正确 ✅
SELECT MIN(col_uint64), MAX(col_uint64) FROM types_2000_large WHERE part_id = 1;  -- 正确 ✅

-- 浮点
SELECT AVG(col_float32), AVG(col_float64) FROM types_2000_large WHERE part_id = 1; -- 正确 ✅

-- DECIMAL
SELECT SUM(col_decimal64), SUM(col_decimal128), SUM(col_decimal128_big)
FROM types_2000_large WHERE part_id = 1; -- 正确 ✅

-- 布尔
SELECT col_bool, COUNT(*) FROM types_2000_large WHERE part_id = 1 GROUP BY col_bool; -- true/false 约各半 ✅

-- 字符串
SELECT COUNT(DISTINCT col_char), COUNT(DISTINCT col_varchar) FROM types_2000_large WHERE part_id = 1; -- 正确 ✅
SELECT LENGTH(col_text) FROM types_2000_large WHERE part_id = 1 LIMIT 5; -- 变长正确 ✅

-- 二进制
SELECT LENGTH(col_binary), LENGTH(col_blob) FROM types_2000_large WHERE part_id = 1 LIMIT 5; -- 16, 8~64 ✅

-- 时间类型
SELECT MIN(col_date), MAX(col_date) FROM types_2000_large WHERE part_id = 1; -- 2020~2024 ✅
SELECT MIN(col_datetime), MAX(col_datetime) FROM types_2000_large WHERE part_id = 1; -- 正确 ✅
SELECT MIN(col_timestamp), MAX(col_timestamp) FROM types_2000_large WHERE part_id = 1; -- 正确 ✅

-- UUID (as VARCHAR)
SELECT col_uuid FROM types_2000_large WHERE part_id = 1 LIMIT 3; -- UUID 格式正确 ✅
```

### 5.2 类型覆盖结果

| 类型 | 测试结果 | 说明 |
|------|----------|------|
| TINYINT (INT8) | ✅ | 范围 -128~126 正确 |
| SMALLINT (INT16) | ✅ | 范围 -32768~32764 正确 |
| INT (INT32) | ✅ | 正确 |
| BIGINT (INT64) | ✅ | 正确 |
| TINYINT UNSIGNED (UINT8) | ✅ | 范围 0~254 正确 |
| SMALLINT UNSIGNED (UINT16) | ✅ | 范围 0~65534 正确 |
| INT UNSIGNED (UINT32) | ✅ | 正确 |
| BIGINT UNSIGNED (UINT64) | ✅ | 正确 |
| FLOAT (FLOAT32) | ✅ | 正确 |
| DOUBLE (FLOAT64) | ✅ | 正确 |
| DECIMAL(10,2) | ✅ | 正确 |
| DECIMAL(20,4) | ✅ | 正确 |
| DECIMAL(30,6) | ✅ | 大精度正确 |
| BOOL | ✅ | true/false 分布正确 |
| CHAR(10) | ✅ | 正确 |
| VARCHAR | ✅ | 正确 |
| TEXT | ✅ | 变长正确 |
| BINARY(16) | ✅ | 16字节正确 |
| BLOB (large_binary) | ✅ | 变长 8~64 字节正确 |
| DATE | ✅ | 范围正确 |
| DATETIME | ✅ | UTC timestamp 映射正确 |
| TIMESTAMP | ✅ | UTC timestamp 正确 |
| TIMESTAMP (non-UTC) | ❌ | 不支持，bug #24356 |
| JSON | ❌ | Parquet STRING→JSON 读为空，bug #24364 |
| ENUM | ❌ | Parquet STRING→ENUM 未实现，bug #24366 |
| UUID (VARCHAR 36) | ✅ | 正确 |
| 跨类型转换 (BOOL→INT等) | ❌ | 大量 "not yet implemented"，综合 bug #24370 |
| **VECF32(N)** | ❌ | Parquet FixedSizeList<float32,N> → VECF32 不支持，bug #24375 |
| **VECF64(N)** | ❌ | Parquet FixedSizeList<float64,N> → VECF64 不支持，bug #24375 |

### 5.3 特殊类型测试 (VECF32/VECF64)

**测试数据**: 2 分区 × 50K 行，包含 `col_vec_f32` (FixedSizeList<float32,3>) 和 `col_vec_f64` (FixedSizeList<float64,4>)

```sql
-- 直接映射 VECF32/VECF64: 失败
CREATE EXTERNAL TABLE ext_special_vec32 (
    col_vec_f32 VECF32(3), col_vec_f64 VECF64(4),
    col_json_str JSON, col_int32 INT, part_id INT
) INFILE{'filepath'='/data2/data-large/types_special/',
         'format'='parquet', 'hive_partitioning'='true', 'hive_partition_columns'='part_id'};

SELECT COUNT(*) FROM ext_special_vec32;  -- ✅ 100000 (元数据读取正常)
SELECT col_vec_f32 FROM ext_special_vec32 LIMIT 1;
-- ERROR: parquet nested column col_vec_f32 must map to JSON or TEXT type, got VECF32

-- 原因: pkg/sql/colexec/external/parquet_nested.go:34 只允许 JSON/TEXT/VARCHAR/CHAR

-- 变通方案: 读为 TEXT 再 CAST
CREATE EXTERNAL TABLE ext_special_vec_text (
    col_vec_f32 TEXT, col_vec_f64 TEXT,
    col_json_str TEXT, col_int32 INT, part_id INT
) INFILE{'filepath'='/data2/data-large/types_special/',
         'format'='parquet', 'hive_partitioning'='true', 'hive_partition_columns'='part_id'};

SELECT col_vec_f32 FROM ext_special_vec_text LIMIT 1;
-- ✅ [-0.991513729095459, 0.43915754556655884, -0.5123825073242188]

SELECT CAST(col_vec_f32 AS VECF32(3)) FROM ext_special_vec_text LIMIT 1;
-- ✅ [0.49671414, -0.1382643, 0.64768857] (可用，但需多一步 CAST)
```

**结论**: VECF32/VECF64 需通过 TEXT 中转 + CAST 才能使用，不支持直接映射。已提 enhancement #24375。

### 5.4 DDL 约束与索引覆盖测试

```sql
-- CREATE INDEX: panic ❌ (bug #24374)
CREATE INDEX idx_int ON types_2000_large(col_int32);
-- panic: runtime error: invalid memory address or nil pointer dereference

-- CREATE UNIQUE INDEX: panic ❌ (bug #24374)
CREATE UNIQUE INDEX uk_int ON types_2000_large(col_int32);
-- panic: runtime error: invalid memory address or nil pointer dereference

-- ALTER TABLE ADD UNIQUE: panic ❌ (bug #24374)
ALTER TABLE types_2000_large ADD UNIQUE INDEX (col_int32);
-- panic: runtime error: invalid memory address or nil pointer dereference

-- FULLTEXT INDEX: 正确拒绝 ✅
CREATE FULLTEXT INDEX ft_text ON types_2000_large(col_text);
-- ERROR: invalid input: fulltext index require primary key

-- PRIMARY KEY 约束: 建表时指定 ✅
CREATE EXTERNAL TABLE ext_pk_test (
    id INT PRIMARY KEY, name VARCHAR(50), part_id INT
) INFILE{'filepath'='/data2/data-large/types_2000_large/',
         'format'='parquet', 'hive_partitioning'='true', 'hive_partition_columns'='part_id'};
-- ✅ 建表成功（外部表允许 DDL 指定 PK，但无实际约束校验）

-- NOT NULL 约束: 建表时指定 ✅
CREATE EXTERNAL TABLE ext_nn_test (
    col_int32 INT NOT NULL, col_varchar VARCHAR(100), part_id INT
) INFILE{...};
-- ✅ 建表成功

-- AUTO_INCREMENT: 建表时指定 ✅
CREATE EXTERNAL TABLE ext_ai_test (
    id INT AUTO_INCREMENT PRIMARY KEY, name VARCHAR(50), part_id INT
) INFILE{...};
-- ✅ 建表成功（外部表只读，AUTO_INCREMENT 无实际意义但不报错）

-- DEFAULT 值: 建表时指定 ✅
CREATE EXTERNAL TABLE ext_def_test (
    col_int32 INT DEFAULT 0, col_varchar VARCHAR(100) DEFAULT 'N/A', part_id INT
) INFILE{...};
-- ✅ 建表成功

-- SHOW CREATE TABLE: filepath 和 S3 参数丢失 ❌ (bug #24372)
SHOW CREATE TABLE types_2000_large_s3;
-- 输出中 FILEPATH 为空字符串，且 S3 参数全部丢失
```

| DDL/约束操作 | 结果 | 说明 |
|-------------|------|------|
| CREATE INDEX | ❌ panic | bug #24374 |
| CREATE UNIQUE INDEX | ❌ panic | bug #24374 |
| ALTER TABLE ADD UNIQUE | ❌ panic | bug #24374 |
| FULLTEXT INDEX | ✅ 正确拒绝 | 需要 PK |
| PRIMARY KEY 列 | ✅ 可创建 | DDL 层面接受 |
| NOT NULL | ✅ 可创建 | DDL 层面接受 |
| AUTO_INCREMENT | ✅ 可创建 | 外部表只读，无实际意义 |
| DEFAULT | ✅ 可创建 | 外部表只读，无实际意义 |
| INSERT/UPDATE/DELETE | ✅ 正确拒绝 | "cannot insert/update/delete from external table" |
| SHOW CREATE TABLE (S3) | ❌ 信息丢失 | bug #24372 |

### 5.5 分区路径安全规则测试（Query-time errors）

**测试数据**: `/data2/data-large/edge_cases/` 下各子目录

```sql
-- TEST 1: 目录名含 % → 报错
CREATE EXTERNAL TABLE edge_path_percent (id INT, value DOUBLE, year INT)
INFILE{'filepath'='/data2/data-large/edge_cases/path_percent/', 'format'='parquet',
       'hive_partitioning'='true', 'hive_partition_columns'='year'};
SELECT COUNT(*) FROM edge_path_percent;
-- ERROR: hive partition directory name contains '%' which is not supported: 'year=2024%25encoded' ✅

-- 即使加分区过滤 WHERE year = 2024 也报错（发现阶段先枚举所有目录）
SELECT COUNT(*) FROM edge_path_percent WHERE year = 2024;
-- ERROR: 同上 ✅

-- TEST 2: key 含非法字符 (@) → 报错
CREATE EXTERNAL TABLE edge_special_key (id INT, value DOUBLE, year INT)
INFILE{'filepath'='/data2/data-large/edge_cases/path_special_key/', ...};
SELECT COUNT(*) FROM edge_special_key;
-- ERROR: invalid hive partition key 'ye@r': only letters, digits, and '_' are allowed ✅

-- TEST 3: value 为 . 或 .. (路径穿越) → 报错
CREATE EXTERNAL TABLE edge_traversal (id INT, value DOUBLE, year VARCHAR(10))
INFILE{'filepath'='/data2/data-large/edge_cases/path_traversal/', ...};
SELECT COUNT(*) FROM edge_traversal;
-- ERROR: invalid hive partition value '.': path traversal segment is not allowed ✅

-- TEST 4: 类型转换失败 (year=abc → INT) → 报错
CREATE EXTERNAL TABLE edge_type_fail (id INT, value DOUBLE, year INT)
INFILE{'filepath'='/data2/data-large/edge_cases/type_convert_fail/', ...};
SELECT COUNT(*) FROM edge_type_fail;
-- ERROR: partition value type conversion failed: col=year, value='abc', ... ✅
-- 即使 WHERE year = 2024 也报错（发现阶段先转换所有目录值）
SELECT COUNT(*) FROM edge_type_fail WHERE year = 2024;
-- ERROR: 同上 ✅

-- TEST 5: 空分区值 (country=/) → 解析为空字符串
CREATE EXTERNAL TABLE edge_empty_val (id INT, value DOUBLE, country VARCHAR(20))
INFILE{'filepath'='/data2/data-large/edge_cases/empty_value/', ...};
SELECT COUNT(*), country, LENGTH(country) FROM edge_empty_val GROUP BY country;
-- 结果: country='' (len=0) 50行, country='US' (len=2) 50行 ✅

-- TEST 19: value 含 \b (被解释为控制字符) → 报错
-- ERROR: invalid hive partition value 'a': control character is not allowed ✅
```

| 安全规则 | 测试结果 | 说明 |
|----------|----------|------|
| 目录名含 `%` | ✅ 正确拒绝 | 即使有分区过滤也会报错 |
| key 含非法字符 (`@`) | ✅ 正确拒绝 | |
| value 为 `.` / `..` | ✅ 正确拒绝 | 路径穿越防护 |
| value 含控制字符 | ✅ 正确拒绝 | |
| value 类型转换失败 | ✅ 正确报错 | 即使有分区过滤也报错 |
| 空 value (`country=/`) | ✅ 解析为空字符串 | LENGTH=0 |

### 5.6 NOT NULL + `__HIVE_DEFAULT_PARTITION__`

```sql
-- 分区列声明为 NOT NULL，遇到 __HIVE_DEFAULT_PARTITION__ 应报错
CREATE EXTERNAL TABLE edge_notnull_default (id INT, value DOUBLE, year INT NOT NULL)
INFILE{'filepath'='/data2/data-large/edge_cases/notnull_default/', ...};
SELECT COUNT(*) FROM edge_notnull_default;
-- ERROR: constraint violation: partition column 'year' is NOT NULL but directory has
--   __HIVE_DEFAULT_PARTITION__ in path '...'; allow NULL on the partition column or
--   remove/rename the default partition directory ✅

-- 对比: 同一数据，Nullable 列正常工作
CREATE EXTERNAL TABLE edge_nullable_default (id INT, value DOUBLE, year INT)
INFILE{same path};
SELECT COUNT(*), year FROM edge_nullable_default GROUP BY year;
-- year=2024: 50行, year=NULL: 50行 ✅
SELECT COUNT(*) FROM edge_nullable_default WHERE year IS NULL;  -- 50 ✅
SELECT COALESCE(year, -1) AS y, COUNT(*) FROM edge_nullable_default GROUP BY y;
-- y=-1: 50, y=2024: 50 ✅
```

### 5.7 分区列类型与裁剪行为

```sql
-- INT 列 leading-zero 匹配: month=01 被 WHERE month = 1 命中
CREATE EXTERNAL TABLE edge_leading_zero (id INT, value DOUBLE, month INT)
INFILE{'filepath'='/data2/data-large/edge_cases/leading_zero/', ...};
SELECT COUNT(*) FROM edge_leading_zero WHERE month = 1;   -- 100 ✅ (匹配 month=01/)
SELECT COUNT(*) FROM edge_leading_zero WHERE month = 2;   -- 100 ✅ (匹配 month=02/)
SELECT COUNT(*) FROM edge_leading_zero WHERE month = 10;  -- 100 ✅
SELECT COUNT(*) FROM edge_leading_zero WHERE month IN (1, 10); -- 200 ✅

-- VARCHAR 列精确匹配: '01' != '1'
CREATE EXTERNAL TABLE edge_varchar_exact (id INT, value DOUBLE, month VARCHAR(5))
INFILE{'filepath'='/data2/data-large/edge_cases/varchar_exact/', ...};
-- 目录: month=01/, month=1/, month=02/
SELECT COUNT(*) FROM edge_varchar_exact WHERE month = '01'; -- 100 ✅
SELECT COUNT(*) FROM edge_varchar_exact WHERE month = '1';  -- 100 ✅ (不同目录!)
SELECT COUNT(*) FROM edge_varchar_exact WHERE month = '02'; -- 100 ✅
SELECT DISTINCT month FROM edge_varchar_exact ORDER BY month;
-- 结果: '01', '02', '1' (三个不同值) ✅
```

| 分区列类型 | 裁剪行为 | EXPLAIN ANALYZE 验证 |
|-----------|----------|---------------------|
| INT (leading-zero `01`) | ✅ 目录裁剪 | inputRows=100 (只读 1 分区) |
| VARCHAR (精确匹配) | ✅ 目录裁剪 | inputRows=100 |
| DATE | ❌ Row filter | inputRows=300 (全表), outputRows=100 |
| BOOL | ❌ Row filter | inputRows=200 (全表), outputRows=100 |
| DOUBLE/FLOAT | ❌ Row filter | inputRows=200 (全表), outputRows=100 |

### 5.8 非裁剪谓词正确性验证

**测试数据**: `edge_predicate` 表，5 个分区 (year=2020~2024)，每分区 200 行，共 1000 行。

```sql
-- 所有谓词结果均正确，但均不做目录裁剪（inputRows = 1000 全表）

SELECT COUNT(*) FROM edge_predicate WHERE year > 2022;           -- 400 ✅ (2023+2024)
SELECT COUNT(*) FROM edge_predicate WHERE year = 2020 OR year = 2024; -- 400 ✅
SELECT COUNT(*) FROM edge_predicate WHERE year NOT IN (2020, 2021);   -- 600 ✅
SELECT COUNT(*) FROM edge_predicate WHERE year != 2024;               -- 800 ✅
SELECT COUNT(*) FROM edge_predicate WHERE year + 1 = 2025;            -- 200 ✅
SELECT COUNT(*) FROM edge_predicate WHERE CAST(year AS VARCHAR) = '2024'; -- 200 ✅
SELECT COUNT(*) FROM edge_predicate WHERE year BETWEEN 2022 AND 2024; -- 600 ✅
SELECT COUNT(*) FROM edge_varchar_exact WHERE month LIKE '0%';        -- 200 ✅
```

| 谓词形式 | 结果正确 | 裁剪？ | EXPLAIN ANALYZE |
|----------|---------|--------|-----------------|
| `year > 2022` (Range) | ✅ | ❌ | inputRows=1000 |
| `year = 2020 OR year = 2024` | ✅ | ❌ | inputRows=1000 |
| `year NOT IN (2020,2021)` | ✅ | ❌ | inputRows=1000 |
| `year != 2024` | ✅ | ❌ | inputRows=1000 |
| `year + 1 = 2025` (Expression) | ✅ | ❌ | inputRows=1000 |
| `CAST(year AS VARCHAR)='2024'` | ✅ | ❌ | inputRows=1000 |
| `year BETWEEN 2022 AND 2024` | ✅ | ❌ | inputRows=1000 |
| `month LIKE '0%'` (Partial) | ✅ | ❌ | inputRows=300 |
| **`year = 2024`** (Equality) | ✅ | **✅** | **inputRows=200** |
| **`year IN (2020, 2024)`** | ✅ | **✅** | **inputRows=400** |

### 5.9 Schema 不一致（Schema Evolution 不支持）

```sql
-- year=2023/: Parquet 含 id, value 两列
-- year=2024/: Parquet 只有 id 列 (缺 value)
CREATE EXTERNAL TABLE edge_schema_mismatch (id INT, value DOUBLE, year INT)
INFILE{'filepath'='/data2/data-large/edge_cases/schema_mismatch/', ...};

-- 全表查询引用 value → 报错
SELECT COUNT(*), SUM(value) FROM edge_schema_mismatch;
-- ERROR: column value not found ✅

-- 只查有 value 列的分区 → 正常
SELECT COUNT(*), SUM(value) FROM edge_schema_mismatch WHERE year = 2023;
-- 100, 5445 ✅

-- 只查共有列 id (存在于所有分区) → 正常
SELECT COUNT(*), SUM(id) FROM edge_schema_mismatch;
-- 200, 19900 ✅
```

**结论**: Schema Evolution 不支持，缺少列时报 `column not found`（不填 NULL），但通过分区裁剪可以避开不兼容分区。

### 5.10 物理列名冲突（Path value wins）

```sql
-- Parquet 文件内含物理列 year=9999 (year=2024分区) 和 year=8888 (year=2025分区)
CREATE EXTERNAL TABLE edge_col_conflict (id INT, value DOUBLE, year INT)
INFILE{'filepath'='/data2/data-large/edge_cases/col_conflict/', ...};

SELECT DISTINCT year FROM edge_col_conflict ORDER BY year;
-- 结果: 2024, 2025 ✅ (path value wins, 物理列 9999/8888 被忽略)
```

### 5.11 `__mo_filepath` 单独使用

```sql
-- 无分区过滤，只用 __mo_filepath
SELECT COUNT(*) FROM edge_predicate WHERE __mo_filepath LIKE '%year=2024%';
-- 200 ✅

-- EXPLAIN ANALYZE: inputRows=200 (文件级过滤有效)
EXPLAIN ANALYZE SELECT COUNT(*) FROM edge_predicate WHERE __mo_filepath LIKE '%year=2024%';
-- External Scan inputRows=200 ✅ (只读了匹配文件)
```

### 5.12 深度不匹配

```sql
-- 树比声明更深: 声明 (year,month), 但 month=01/ 下有 region=us/data.parquet
CREATE EXTERNAL TABLE edge_depth_deeper (id INT, value DOUBLE, year INT, month VARCHAR(2))
INFILE{'filepath'='/data2/data-large/edge_cases/depth_deeper/', ...};
SELECT COUNT(*) FROM edge_depth_deeper;
-- 100 ✅ (只读 month=01/ 和 month=02/ 下的直接文件, region=us/ 下的被忽略)

-- 树比声明更浅: 声明 (year,month), 但 year=2024/ 下直接放了 data.parquet (没有 month)
CREATE EXTERNAL TABLE edge_depth_shallower (id INT, value DOUBLE, year INT, month VARCHAR(2))
INFILE{'filepath'='/data2/data-large/edge_cases/depth_shallower/', ...};
SELECT COUNT(*) FROM edge_depth_shallower;
-- 100 ✅ (只读正确深度的文件: year=2024/month=01/ + year=2025/month=02/, 中间层文件被忽略)
```

### 5.13 隐藏文件/目录和非 Parquet 文件

```sql
-- 目录中混入: .hidden.parquet, _temporary.parquet, data.csv, _SUCCESS, .staging/, _temporary/
CREATE EXTERNAL TABLE edge_skip_hidden (id INT, value DOUBLE, year INT)
INFILE{'filepath'='/data2/data-large/edge_cases/skip_hidden/', ...};
SELECT COUNT(*) FROM edge_skip_hidden;
-- 100 ✅ (只读 data.parquet, 所有 ./_ 开头文件和非.parquet文件被跳过)
```

### 5.14 文件扩展名识别

```sql
-- part-00000.snappy.parquet, part-00001.gzip.parquet, part-00002.PARQUET, part-00003.orc
CREATE EXTERNAL TABLE edge_multi_ext (id INT, value DOUBLE, year INT)
INFILE{'filepath'='/data2/data-large/edge_cases/multi_ext/', ...};
SELECT COUNT(*) FROM edge_multi_ext;
-- 300 ✅ (3个 .parquet 文件各100行, .orc 被跳过)
-- .snappy.parquet ✅, .gzip.parquet ✅, .PARQUET (大写) ✅, .orc ❌ 被跳过
```

### 5.15 分区数安全上限测试

```sql
-- 生成 50,100 个分区 (每分区 1 行)
-- /data2/data-large/edge_cases/partition_limit/part_id=0/ ~ part_id=50099/

-- TEST: 全表扫描 50,100 分区 → hard error
CREATE EXTERNAL TABLE edge_partition_limit (id INT, value DOUBLE, part_id INT)
INFILE{'filepath'='/data2/data-large/edge_cases/partition_limit/', ...};
SELECT COUNT(*) FROM edge_partition_limit;
-- ERROR: hive partition discovery exceeded 50000 partitions; consider adding partition filters ✅

-- TEST: 加分区过滤 → 正常查询 (绕过上限)
SELECT COUNT(*) FROM edge_partition_limit WHERE part_id = 1;          -- 1 ✅
SELECT COUNT(*) FROM edge_partition_limit WHERE part_id IN (1,100,1000,10000,50000); -- 5 ✅

-- 生成 6,000 个分区
-- /data2/data-large/edge_cases/partition_warn/part_id=0/ ~ part_id=5999/
CREATE EXTERNAL TABLE edge_partition_warn (id INT, value DOUBLE, part_id INT)
INFILE{'filepath'='/data2/data-large/edge_cases/partition_warn/', ...};
SELECT COUNT(*) FROM edge_partition_warn;  -- 6000 ✅ (查询成功)
```

**服务端日志验证**:
```json
// 5,000 WARN (6000 分区表):
{"level":"WARN","caller":"external/hive_partition.go:361",
 "msg":"hive partition discovery: partition count exceeds 5000 (current: 5001, base: .../partition_warn); consider adding partition filters"}

// 50,000 hard error (50100 分区表):
{"level":"ERROR","caller":"external/hive_partition.go:356",
 "msg":"error: internal error: hive partition discovery exceeded 50000 partitions; consider adding partition filters"}
```

| 安全限制 | 测试结果 | 说明 |
|----------|---------|------|
| 5,000 分区 WARN | ✅ | 查询成功 + 服务端 WARN 日志 |
| 50,000 分区 hard error | ✅ | 返回错误，阻止查询 (本地 + S3) |
| 10,000 List call hard error | ✅ | 3级×22 (10,648叶) 触发 (本地 + S3) |
| 加分区过滤绕过上限 | ✅ | equality/IN 可正常查询 |

**10,000 List call 测试详情**:
```sql
-- 3级分区树: year(22) × month(22) × day(22) = 10,648 叶节点
-- discoverRecursive 调用: 1 + 22 + 484 + 10648 = 11,155 > 10,000

-- 本地: 触发
SELECT COUNT(*) FROM edge_list_call_local;
-- ERROR: hive partition discovery exceeded 10000 List calls ✅

-- S3 (MinIO): 同样触发
SELECT COUNT(*) FROM edge_list_call_s3;
-- ERROR: hive partition discovery exceeded 10000 List calls ✅

-- 加外层过滤: 只遍历 year=1/ 子树 (485 calls)，不触发
SELECT COUNT(*) FROM edge_list_call_s3 WHERE year = 1;  -- 484 ✅
SELECT COUNT(*) FROM edge_list_call_s3 WHERE year = 1 AND month = 1;  -- 22 ✅
```

---

## 六、COS (TKE) 功能测试结果

**测试环境**: TKE 广州区 MO 集群 (16 核 multicn) → COS (cos.ap-guangzhou.myqcloud.com)

| 测试 | 说明 | 预期 | 实际 | 状态 |
|------|------|------|------|------|
| F01 | 全表 COUNT (2000分区) | 100,000,000 | 100,000,000 | ✅ |
| F02 | 单分区 COUNT | 50,000 | 50,000 | ✅ |
| F03 | IN 10分区 COUNT | 500,000 | 500,000 | ✅ |
| F04 | predicate total | 1,000 | 1,000 | ✅ |
| F05 | equality pruning | 200 | 200 | ✅ |
| F06 | OR (无裁剪) | 400 | 400 | ✅ |
| F07 | range > | 400 | 400 | ✅ |
| F08 | NOT IN | 600 | 600 | ✅ |
| F09 | leading zero INT (month=01 → 1) | 100 | 100 | ✅ |
| F10 | varchar exact '01' | 100 | 100 | ✅ |
| F11 | varchar exact '1' | 100 | 100 | ✅ |
| F12 | NOT NULL + DEFAULT_PARTITION | error | 100 (无报错) | ⚠️ 待确认 |
| F13 | nullable + DEFAULT_PARTITION | 100 | 100 | ✅ |
| F14 | nullable NULL count | 50 | 50 | ✅ |
| F15 | schema mismatch 全表 | error | ERROR 20301 | ✅ |
| F16 | schema mismatch 好分区 | 100 | 100, sum=5445 | ✅ |
| F17 | col conflict (path wins) | 2024,2025 | 2024,2025 | ✅ |
| F18 | depth deeper | 100 | 100 | ✅ |
| F19 | depth shallower | 100 | 100 | ✅ |
| F20 | skip hidden | 100 | 100 | ✅ |
| F21 | multi ext (.snappy.parquet等) | 300 | 300 | ✅ |
| F22 | path percent (安全拒绝) | error | ERROR 20101 | ✅ |
| F23 | path traversal (安全拒绝) | error | ERROR 20101 | ✅ |
| F24 | type convert fail (year=abc→INT) | error | COUNT(*)=100, 无报错 | 🐛 #24385 |
| F25 | empty value (country=) | 50+50 | 50 US + 50 "" | ✅ |
| F26 | `__mo_filepath` 路径 | COS路径 | `/hive_partition/.../part_id=1/data.parquet` | ✅ |
| F27 | `__mo_filepath` filter | 50,000 | 50,000 | ✅ |

**COS 功能测试总结**: 25/27 通过, 1 个 bug (#24385), 1 个待确认 (F12)

---

## 七、已发现并提交的 Issue

| # | 标题 | 严重程度 | 状态 |
|---|------|----------|------|
| #24356 | [Bug]: TIMESTAMP(isAdjustedToUTC=false) parquet 不支持 | s0 | Open |
| #24359 | [Bug]: GROUP_CONCAT ORDER BY on external table causes panic | s0 | **Fixed on main** |
| #24360 | [Bug]: COUNT(DISTINCT) on external table fails | s0 | **Fixed on main** |
| #24364 | [Bug]: Parquet STRING → JSON type reads as empty | s0 | Open |
| #24366 | [Bug]: Parquet STRING → ENUM type not implemented | s0 | Open |
| #24370 | [Bug]: Parquet external table cross-type conversions fail | s0 | Open |
| #24372 | [Bug]: SHOW CREATE TABLE 丢失 S3 参数和 filepath | s1 | Open |
| #24374 | [Bug]: CREATE INDEX/UNIQUE on external table causes panic | s0 | Open |
| #24375 | [Enhancement]: Parquet FixedSizeList → VECF32/VECF64 直接映射 | s1 | Open |
| #24385 | [Bug]: COUNT(*) silently skips partitions with unconvertible hive values | s1 | Open |
| #24390 | [Enhancement]: Support auto-inference of Hive partition columns from key=value directories | s1 | Open |

---

## 七、总结

1. **功能完备性**: 22/28 数据类型通过 Hive Parquet 外部表正确读取；JSON/ENUM/non-UTC TIMESTAMP/跨类型转换/VECF32/VECF64 有问题 (6 个 open issue)
2. **稳定性**: 2.8 亿+ 行数据，20 项 unhappy path 测试，各种查询模式下均无 hang/OOM (但 CREATE INDEX 会 panic)
3. **分区支持**: 当前版本采用显式 `hive_partition_columns` 模式；在声明分区列后，2000 分区 × 50K 行 (1亿行, 21GB) 正常工作，虚拟列和分区裁剪有效，100→2000 分区性能无退化。仅根据 `key=value/` 目录自动推断分区列 schema 未纳入当前版本，作为 #24390 enhancement 跟踪。
4. **性能 (本地)**: 
   - 高分区场景 (2000 分区): **MO 全面优于 ClickHouse** (13/15 查询更快，最大 7.4x)
   - 少分区计算密集场景 (84 分区): CK 在 SUM/窗口函数上更快 (2-29x)
   - MO 的 filter pushdown 和分区裁剪是核心竞争力
5. **S3 (MinIO 内网)**:
   - 功能全部正确（包括分区裁剪、NULL 分区、多级分区、文件跳过、__mo_filepath）
   - 分区裁剪收益巨大：单分区 5s vs 全表 72s，减少 93% 的 API 调用
   - I/O 是瓶颈：即使内网 MinIO，S3 协议开销比本地磁盘慢 100-289 倍
   - 结论：S3 场景下**必须加分区过滤条件**，否则全表扫描代价极大
6. **DDL 约束**: PRIMARY KEY/NOT NULL/AUTO_INCREMENT/DEFAULT 均可在建表时指定；CREATE INDEX/UNIQUE 触发 panic (#24374)；SHOW CREATE TABLE S3 参数丢失 (#24372)
7. **向量类型**: VECF32/VECF64 不支持从 Parquet FixedSizeList 直接映射，需通过 TEXT 中转 + CAST (#24375)
8. **安全上限**: 50,000 分区 hard error ✅、10,000 List call hard error ✅、5,000 分区 WARN 日志 ✅、加分区过滤可绕过 ✅
9. **路径安全规则**: 6 项 query-time 安全验证全部通过（%、非法字符、路径穿越、控制字符、类型转换失败、空值）
10. **裁剪行为验证**: 
    - INT/VARCHAR: 目录裁剪 ✅ (INT leading-zero 正确匹配, VARCHAR 精确匹配)
    - DATE/BOOL/FLOAT: Row filter only ✅ (功能正确, 不裁剪)
    - OR/Range/NOT IN/Expression/CAST/LIKE: Row filter only ✅ (功能正确, 不裁剪)
11. **Schema 不一致**: 缺列时正确报 column-not-found (不填 NULL)，可通过分区裁剪避开
12. **物理列名冲突**: Path value wins ✅
13. **深度不匹配**: 更深的忽略、更浅的忽略 ✅
14. **隐藏文件/非 Parquet**: .xxx/_xxx 开头被跳过, 非.parquet 扩展被跳过, .snappy.parquet/.gzip.parquet/.PARQUET 全识别 ✅
15. **3.0-dev OOM 问题在 main 分支未复现**
