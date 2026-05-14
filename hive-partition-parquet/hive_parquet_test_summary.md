# Hive-Partitioned Parquet 外部表 — 测试总结

**测试日期**: 2026-05-12 ~ 2026-05-13  
**测试 PR**: https://github.com/matrixorigin/matrixone/issues/24320  
**MO 版本**: main (git: 7efe429)  
**测试环境**: 10.222.1.128 (252G RAM, NVMe SSD)  
**对比引擎**: ClickHouse 22.8.5.29 (同服务器)  
**S3 存储**: MinIO (10.222.6.2, 内网)

---

## 一、测试内容概览

共 **7 大类 50+ 项** 测试，覆盖当前 `hive_partition_user_guide_en.md` 中显式声明 `hive_partition_columns` 模式下的功能点。  
不声明分区列、仅根据 `key=value/` 目录自动推断分区列 schema 的能力未纳入当前版本，已作为 enhancement #24390 跟踪。

| 类别 | 测试项数 | 说明 |
|------|---------|------|
| 功能验证 | 23 项 | 显式分区列模式下的目录发现、虚拟列、分区裁剪、非裁剪谓词、NULL 分区、深度不匹配等 |
| 路径安全规则 | 6 项 | %、非法字符、路径穿越、控制字符、类型转换失败、空值 |
| 安全上限 | 3 项 | 50,000 分区 / 10,000 List call / 5,000 WARN |
| 数据类型 | 28 种 | 全类型覆盖 + VECF32/VECF64 特殊类型 |
| DDL/约束 | 10 项 | INDEX/UNIQUE/FULLTEXT/PK/NOT NULL/DEFAULT/AUTO_INCREMENT |
| 稳定性 (大数据不 hung 不 OOM) | 14 种查询 | 1 亿行 × 2000 分区 + ROW_NUMBER 全表 1.02 亿行 |
| 性能对比 | 37 组 | MO vs CK (两种场景) + 本地 vs S3 |

---

## 二、测试数据

| 数据集 | 行数 | 分区数 | 磁盘 | 用途 |
|--------|------|--------|------|------|
| types_2000_large | 1 亿 | 2000 | 21G | 高分区性能、稳定性、功能主测 |
| sales_100m | 1.02 亿 | 84 | 4.3G | 少分区性能对比 |
| events_50m | 5000 万 | 200 | 1.8G | 中分区对比 |
| edge_cases/* | 各 50~50,100 | 1~50,100 | ~200M | 边界条件 |
| types_special | 10 万 | 2 | 小 | VECF32/VECF64 |

**总数据量**: ~2.82 亿行, ~35GB

---

## 三、性能对比结果

### 3.1 MO vs ClickHouse — 高分区场景

> **数据集**: types_2000_large — **1 亿行, 2000 分区, 每分区 50K 行, 21GB, 26 列全类型覆盖 (Snappy 压缩)**  
> MO 使用原生 `hive_partitioning` 分区裁剪；CK 使用 `file()` + glob + `_file` regex 过滤。

| Query | 说明 | MO (s) | CK (s) | 胜者 |
|-------|------|--------|--------|------|
| Q01 | 单分区 COUNT (50K) | 0.064 | 0.472 | **MO 7.4x** |
| Q02 | 全表 COUNT (100M) | 0.201 | 0.641 | **MO 3.2x** |
| Q03 | IN 10 分区 SUM (500K) | 0.156 | 0.572 | **MO 3.7x** |
| Q04 | Range 100 分区 AVG (5M) | 0.307 | 0.639 | **MO 2.1x** |
| Q05 | Range 500 分区 AVG (25M) | 0.295 | 0.581 | **MO 2.0x** |
| Q06 | Range 1000 分区 AVG (50M) | 0.298 | 0.716 | **MO 2.4x** |
| Q07 | 全表 SUM(float64) (100M) | 0.310 | 0.634 | **MO 2.0x** |
| Q08 | GROUP BY enum, 500 分区 | 2.550 | 0.898 | CK 2.8x |
| Q09 | GROUP BY part_id, 全表 | 0.257 | 0.460 | **MO 1.8x** |
| Q10 | ORDER BY LIMIT 10, 100 分区 | 0.555 | 0.769 | **MO 1.4x** |
| Q11 | ORDER BY LIMIT 5, 全表 | 0.305 | 0.852 | **MO 2.8x** |
| Q12 | COUNT DISTINCT, 全表 | 0.483 | 0.744 | **MO 1.5x** |
| Q13 | 多条件过滤, 全表 | 0.632 | 0.771 | **MO 1.2x** |
| Q14 | 嵌套子查询 GROUP BY | 0.143 | 0.435 | **MO 3.0x** |
| Q15 | ROW_NUMBER, 100 分区 | 2.352 | 0.789 | CK 3.0x |

**结果: MO 赢 13/15, CK 赢 2/15**

### 3.2 MO vs ClickHouse — 少分区场景

> **数据集**: sales_100m — **1.02 亿行, 84 分区 (7年×12月), 每分区 ~1.2M 行, 4.3GB, 含 INT/FLOAT/DECIMAL/BOOL/VARCHAR/DATE**  
> **数据集**: events_50m — **5000 万行, 200 分区, 每分区 250K 行, 1.8GB, 含 UINT/BIGINT/DECIMAL/VARCHAR**  
> MO 通过外部表读取；CK 通过 `file()` 直接读 Parquet。

| Query | 说明 | MO (s) | CK (s) | 胜者 |
|-------|------|--------|--------|------|
| Q01 | 单分区 COUNT (1.5M) | 0.075 | 0.315 | **MO 4.2x** |
| Q02 | 全表 COUNT (102M) | 0.224 | 0.280 | **MO 1.3x** |
| Q03 | 全表 SUM (102M) | 2.160 | 0.258 | CK 8.4x |
| Q04 | 分区过滤+多聚合 | 0.486 | 0.453 | 持平 |
| Q05 | GROUP BY 单分区 (1.5M) | 0.660 | 0.336 | CK 2.0x |
| Q06 | GROUP BY 全年 (15M) | 0.404 | 0.303 | CK 1.3x |
| Q07 | ORDER BY LIMIT 单分区 | 0.384 | 0.252 | CK 1.5x |
| Q08 | ORDER BY LIMIT 全年 (15M) | 0.528 | 0.264 | CK 2.0x |
| Q09 | events_50m COUNT (50M) | 0.147 | 0.260 | **MO 1.8x** |
| Q10 | events_50m SUM+AVG (50M) | 2.725 | 0.266 | CK 10.2x |
| Q11 | events_50m GROUP BY | 2.753 | 0.283 | CK 9.7x |
| Q12 | ROW_NUMBER 单分区 (1.5M) | 0.776 | 0.321 | CK 2.4x |
| Q13 | ROW_NUMBER 全年 (15M) | 8.316 | 0.284 | CK 29.3x |
| Q14 | 多条件过滤 (102M) | 0.549 | 0.475 | 持平 |
| Q15 | COUNT DISTINCT (102M) | 0.392 | 0.424 | **MO 1.1x** |

**结果: MO 赢 4/15, 持平 2/15, CK 赢 9/15**

### 3.3 本地 vs S3 (MinIO 内网)

> **数据集**: types_2000_large — **1 亿行, 2000 分区, 21GB**  
> **S3 环境**: MinIO (10.222.6.2), 内网带宽，bucket: hive-partition-test

| 查询 | 分区数 | 数据量 | 本地 | S3 | 倍数 |
|------|--------|--------|------|-----|------|
| 单分区 COUNT | 1 | 50K | 0.05s | 5.2s | 100x |
| IN 10 分区 SUM | 10 | 500K | 0.06s | 5.9s | 98x |
| Range 100 分区 AVG | 100 | 5M | 0.23s | 66.5s | 289x |
| Range 500 分区 AVG | 500 | 25M | 0.24s | 68.3s | 285x |
| 全表 SUM | 2000 | 100M | 0.27s | 71.7s | 266x |
| GROUP BY 500 分区 | 500 | 25M | 2.56s | 77.3s | 30x |
| ORDER BY LIMIT 全表 | 2000 | 100M | 0.27s | 65.1s | 241x |

### 3.4 分区扩展性

> **数据集**: types_2000_large — **1 亿行, 2000 分区, 每分区 50K 行, 21GB**  
> 同一数据集，逐步增加扫描分区数，验证 MO 分区裁剪在分区数增长时是否有退化。

| 查询 | 分区数 | 数据量 | 耗时 | 结论 |
|------|--------|--------|------|------|
| `COUNT(*) WHERE part_id = 1` | 1 | 50K | 0.06s | 基线 |
| `COUNT(*), SUM WHERE part_id IN (10个值)` | 10 | 500K | 0.05s | ≈基线 |
| `COUNT(*), AVG WHERE part_id BETWEEN 1 AND 100` | 100 | 5M | 0.23s | 线性 |
| `COUNT(*), AVG WHERE part_id BETWEEN 1 AND 500` | 500 | 25M | 0.28s | 无退化 |
| `COUNT(*), AVG WHERE part_id BETWEEN 1 AND 1000` | 1000 | 50M | 0.27s | 无退化 |
| `COUNT(*), SUM(col_float64)` 全表 | 2000 | 100M | 0.48s | 无退化 |
| `col_int32 > 0 AND col_bool = true` 全表 | 2000 | 100M | 0.50s | 数据过滤稳定 |
| `GROUP BY col_enum WHERE ... BETWEEN 1 AND 500` | 500 | 25M | 2.54s | GROUP BY 稳定 |
| `GROUP BY part_id ORDER BY ... LIMIT 10` 全表 | 2000 | 100M | 2.48s | 稳定 |
| `ORDER BY col_float64 LIMIT 10` 100 分区 | 100 | 5M | 0.40s | 稳定 |
| `ORDER BY col_float64 LIMIT 5` 全表 | 2000 | 100M | 0.30s | 稳定 |
| `ROW_NUMBER() OVER (...)` 100 分区 | 100 | 5M | 2.62s | Window 稳定 |
| `COUNT(DISTINCT col_varchar)` 全表 | 2000 | 100M | 0.56s | 稳定 |
| 嵌套子查询 `MAX(cnt) FROM (GROUP BY part_id)` | 2000 | 100M | 0.16s | 稳定 |

**关键发现**: 分区数从 100 增长到 2000（数据从 5M 到 100M），COUNT/SUM/AVG 耗时仅从 0.23s 增长到 0.48s，接近线性，**无非线性退化**。

### 3.5 性能综合结论

| 维度 | MO 优势 | CK 优势 |
|------|---------|---------|
| **分区裁剪** | 原生支持，高分区数极快 (7.4x) | 需 glob+regex，分区多时慢 |
| **COUNT / 元数据** | 极快，利用 Parquet metadata | 较快 |
| **SUM/AVG 计算密集** | 高分区场景快 | 少分区时极快 (8-10x) |
| **Window Function** | 有优化空间 | 明显更快 (3-29x) |
| **分区数扩展性** | 100→2000 无退化 | 分区越多越慢 |
| **S3 性能** | 分区裁剪减少 93% API 调用 | - |

**核心结论**: 
1. **高分区场景 MO 全面胜出** — 分区裁剪是核心竞争力
2. **少分区计算密集场景 CK 有优势** — 向量化 SUM 和 Window Function
3. **S3 场景必须加分区过滤** — 否则 I/O 开销 100-289x

---

## 四、功能验证结果

### 4.1 核心功能（全部通过）

| 功能 | 验证方式 | 结果 |
|------|---------|------|
| 分区列 SELECT/WHERE/GROUP BY/ORDER BY/JOIN | 多种 SQL | ✅ |
| 等值/IN 分区裁剪 | EXPLAIN ANALYZE inputRows | ✅ 只读目标分区 |
| AND 跨分区列裁剪 | 多级分区 year+month | ✅ |
| OR/Range/NOT IN/Expression/CAST/LIKE | 结果正确 + 不裁剪 | ✅ 全表 scan 后过滤 |
| `__mo_filepath` 虚拟列 | 单独 + 组合使用 | ✅ 文件级过滤有效 |
| `__HIVE_DEFAULT_PARTITION__` | IS NULL / COALESCE | ✅ |
| NOT NULL + NULL 目录 | constraint violation 报错 | ✅ |
| 物理列名与分区列冲突 | path value wins | ✅ |
| Schema 不一致 | 缺列报 column not found | ✅ |
| 深度不匹配 (更深/更浅) | 多余文件被忽略 | ✅ |
| 隐藏文件 (`.xxx`, `_xxx`) | 全部跳过 | ✅ |
| 非 Parquet 文件 | 全部跳过 | ✅ |
| `.snappy.parquet` / `.gzip.parquet` / `.PARQUET` | 全部识别 | ✅ |
| INT leading-zero (`month=01` → `WHERE month=1`) | 正确匹配 + 裁剪 | ✅ |
| VARCHAR 精确匹配 (`'01'` ≠ `'1'`) | 不同值，正确 | ✅ |
| DATE/BOOL/FLOAT 分区列 | 功能正确，row filter | ✅ |
| 空分区值 (`country=/`) | 解析为空字符串 | ✅ |

### 4.2 路径安全规则（全部通过）

| 安全规则 | 错误信息 | 结果 |
|----------|---------|------|
| 目录名含 `%` | `directory name contains '%' which is not supported` | ✅ 拒绝 |
| key 含非法字符 (`@`) | `only letters, digits, and '_' are allowed` | ✅ 拒绝 |
| value 为 `.` / `..` | `path traversal segment is not allowed` | ✅ 拒绝 |
| value 含控制字符 | `control character is not allowed` | ✅ 拒绝 |
| 类型转换失败 (`year=abc`) | `partition value type conversion failed` | ✅ 报错 |

### 4.3 安全上限（全部通过）

| 限制 | 触发条件 | 错误信息 | 结果 |
|------|---------|---------|------|
| 50,000 分区 hard error | 50,100 个分区全表扫描 | `exceeded 50000 partitions` | ✅ |
| 10,000 List call hard error | 3 级 × 22 = 10,648 叶 | `exceeded 10000 List calls` | ✅ |
| 5,000 分区 WARN | 6,000 分区全表扫描 | 服务端 WARN 日志 | ✅ |
| 分区过滤绕过上限 | `WHERE part_id = 1` 在 5 万分区表 | 正常返回 | ✅ |

### 4.4 DDL 约束

| 操作 | 结果 |
|------|------|
| CREATE INDEX | ❌ panic (#24374) |
| CREATE UNIQUE INDEX | ❌ panic (#24374) |
| ALTER TABLE ADD UNIQUE | ❌ panic (#24374) |
| FULLTEXT INDEX | ✅ 正确拒绝（需要 PK） |
| PRIMARY KEY 列 | ✅ DDL 接受 |
| NOT NULL | ✅ DDL 接受 |
| AUTO_INCREMENT | ✅ DDL 接受 |
| DEFAULT | ✅ DDL 接受 |
| INSERT/UPDATE/DELETE | ✅ 正确拒绝 |
| 9 种 DDL 错误 | ✅ 全部正确报错 |

### 4.5 数据类型 (28 种)

| 类型 | 结果 | | 类型 | 结果 |
|------|------|-|------|------|
| TINYINT | ✅ | | TINYINT UNSIGNED | ✅ |
| SMALLINT | ✅ | | SMALLINT UNSIGNED | ✅ |
| INT | ✅ | | INT UNSIGNED | ✅ |
| BIGINT | ✅ | | BIGINT UNSIGNED | ✅ |
| FLOAT | ✅ | | DOUBLE | ✅ |
| DECIMAL(10,2) | ✅ | | DECIMAL(20,4) | ✅ |
| DECIMAL(30,6) | ✅ | | BOOL | ✅ |
| CHAR(10) | ✅ | | VARCHAR | ✅ |
| TEXT | ✅ | | BINARY(16) | ✅ |
| BLOB | ✅ | | DATE | ✅ |
| DATETIME | ✅ | | TIMESTAMP (UTC) | ✅ |
| UUID (VARCHAR) | ✅ | | | |
| **TIMESTAMP (non-UTC)** | **❌** #24356 | | **JSON** | **❌** #24364 |
| **ENUM** | **❌** #24366 | | **跨类型转换** | **❌** #24370 |
| **VECF32** | **❌** #24375 | | **VECF64** | **❌** #24375 |

### 4.6 稳定性 (大数据不 hung 不 OOM)

在 1 亿行 × 2000 分区数据集上，14 种查询模式全部完成，无 hang/OOM：

| 查询模式 | 最大数据量 | 耗时 |
|----------|-----------|------|
| COUNT + 分区裁剪 | 50K ~ 100M | 0.06s ~ 0.48s |
| SUM/AVG + 范围分区 | 5M ~ 100M | 0.23s ~ 0.50s |
| GROUP BY | 25M ~ 100M | 2.48s ~ 2.54s |
| ORDER BY + LIMIT | 5M ~ 100M | 0.30s ~ 0.40s |
| COUNT DISTINCT | 100M | 0.56s |
| ROW_NUMBER() OVER | 5M | 2.62s |
| 嵌套子查询 | 100M | 0.16s |
| **ROW_NUMBER() 全表** | **1.02 亿** | **59s, 无 OOM** |

---

## 五、发现的 Bug

### 5.1 严重 (s0) — 影响功能

| Issue | 问题 | 影响 | 状态 |
|-------|------|------|------|
| **#24374** | CREATE INDEX/UNIQUE 触发 panic | 用户误操作导致进程崩溃 | Open |
| #24356 | TIMESTAMP(non-UTC) 不支持 | non-UTC 时间列无法读取 | Open |
| #24364 | Parquet STRING → JSON 读为空 | JSON 类型完全不可用 | Open |
| #24366 | Parquet STRING → ENUM 未实现 | ENUM 类型完全不可用 | Open |
| #24370 | 跨类型转换大量 NYI | BOOL→INT 等转换失败 | Open |
| ~~#24359~~ | GROUP_CONCAT ORDER BY panic | | **已修复** |
| ~~#24360~~ | COUNT(DISTINCT) 失败 | | **已修复** |

### 5.2 一般 (s1) — 可接受

| Issue | 问题 | Workaround | 状态 |
|-------|------|-----------|------|
| #24372 | SHOW CREATE TABLE S3 参数丢失 | 不影响查询 | Open |
| #24375 | VECF32/VECF64 不支持 FixedSizeList 映射 | 读为 TEXT + CAST | Open |
| #24385 | 不可转换分区值被 COUNT(*) 静默跳过 | 避免混入非法分区值 | Open |
| #24390 | 自动推断 Hive 分区列 schema | 显式声明 `hive_partition_columns` | Open |

---

## 六、当前限制与建议

### 必须修复（影响用户体验）

1. **#24374 CREATE INDEX panic** — 外部表建索引应该报错拒绝，不应该 panic
2. **#24364 JSON 类型为空** — Parquet STRING → JSON 映射有问题，影响 JSON 数据读取
3. **#24366 ENUM 未实现** — 需要完成 STRING → ENUM 的加载支持

### 建议文档说明（设计限制）

| 限制 | 说明 | Workaround |
|------|------|-----------|
| VECF32/VECF64 | FixedSizeList 不直接映射 | 声明为 TEXT，SELECT 时 CAST |
| TIMESTAMP non-UTC | 只支持 isAdjustedToUTC=true | 数据生成时设为 UTC |
| 跨类型转换 | BOOL→INT, INT→VARCHAR 等不支持 | 建表时类型严格匹配 Parquet schema |
| Schema Evolution | 缺列报错，不填 NULL | 确保所有分区 schema 一致 |
| 非等值裁剪 | OR/Range/NOT IN 走全表 | 改写为 IN list |
| SHOW CREATE TABLE S3 | 参数丢失 | 建表 SQL 自行保存 |

### S3 使用建议

1. **必须加分区过滤条件** — 全表扫描比本地慢 100-289x
2. **优先用 equality / IN** — 只有这两种做目录裁剪
3. **Range 改写为 IN** — `BETWEEN 1 AND 10` 不裁剪，`IN (1,2,...,10)` 裁剪
4. **分区数不宜超过 5,000** — 超过会有 WARN，超 50,000 直接报错

---

## 七、总结评价

| 维度 | 评价 |
|------|------|
| **功能完备性** | 22/28 类型正确，核心功能全部通过 |
| **稳定性** | 2.8 亿行 + 50,100 分区，无 hang/OOM |
| **性能** | 高分区场景全面优于 CK (13/15) |
| **安全性** | 路径穿越/注入全部防护，上限机制完整 |
| **文档覆盖** | 当前显式 `hive_partition_columns` 实现范围已验证；自动推断分区列见 #24390 |
| **遗留问题** | 7 个 open bug + 2 个 enhancement，#24374 (panic) 最需优先修复 |
