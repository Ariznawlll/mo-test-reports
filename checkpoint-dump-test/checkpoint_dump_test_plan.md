# Checkpoint Dump 工具测试方案

## 1. 测试目标

验证 `mo-tool ckp dump` 在不同导出粒度、表类型、数据类型、列约束、索引/分区、DML/MVCC、异常输入、大数据量和跨版本升级场景下的正确性、性能和稳定性。

核心结论不能只以“命令执行成功”为准，必须验证：

- dump 产物完整：CSV、目录结构、`restore.sql`、日志、退出码符合预期。
- load 后数据正确：schema、行数、checksum、NULL/空字符串、特殊字符、类型精度一致。
- 失败路径清晰：错误信息明确，不产生容易误判为成功的半截文件。
- 兼容升级可靠：3.0-dev 产生的 checkpoint 在 4.0-dev 中可按预期 dump 和恢复。

## 2. 基于回归数据的执行策略

第一轮测试优先复用 MatrixOne 已有 SQL 回归测试产生的数据，不单独建设大规模造数流程。回归用例本身已经覆盖大量 DDL、DML、类型、表达式、边界值和历史问题，用它作为 checkpoint dump 的数据源，可以更快暴露真实兼容性问题。

### 2.1 总体思路

| 步骤 | 操作 | 产物 | 目的 |
|---|---|---|---|
| 1 | 启动源端 MO，执行现有回归测试集合 | 源端 `mo-data`、回归数据库/表 | 复用已有数据覆盖面 |
| 2 | 回归执行完成后停止写入，等待或触发 checkpoint | 稳定 checkpoint、latest ts | 固定 dump 快照 |
| 3 | 从源端导出对象清单 | account_id、database_id、table_id、表类型、行数 | 确定 dump 范围 |
| 4 | 对源端库表生成基线 | schema、row count、checksum、关键查询结果 | 作为恢复后对比标准 |
| 5 | 使用 `mo-tool ckp dump` 从回归 `mo-data` 离线导出 | CSV、`restore.sql`、dump 日志 | 验证 checkpoint 工具 |
| 6 | 启动干净目标 MO，执行 `restore.sql` 或 `LOAD DATA` | 恢复后的库表 | 验证 dump 产物可恢复 |
| 7 | 对恢复库执行同样的基线 SQL | 恢复端 schema/count/checksum/result | 和源端基线对比 |
| 8 | 对回归未覆盖的类型/约束/表形态补少量专项用例 | 补充库表 | 封住覆盖缺口 |

### 2.2 回归数据选择

| 类型 | 选择原则 | dump 范围 | 说明 |
|---|---|---|---|
| 全量冒烟 | 选一批稳定回归库 | database/account | 验证目录结构、批量导出、restore.sql |
| 类型覆盖 | 从回归中挑包含多数据类型的表 | table/database | 优先验证 CSV 编码和 load 正确性 |
| DDL 覆盖 | 选含 PK/UK/FK/default/auto_increment/comment/index 的表 | table/database | 验证 DDL 还原能力 |
| DML 覆盖 | 选经历 insert/update/delete/truncate/alter 的回归库 | database | 验证 checkpoint 可见性 |
| 大数据覆盖 | 复用回归或已有性能回归中的大表 | table/database | 验证吞吐、内存和大文件 |
| 多租户覆盖 | 复用多 account 回归数据 | account | 验证 account 级导出 |

### 2.3 源端基线采集

回归数据 dump 前必须先采集源端基线，否则恢复后无法判断“数据正确”还是“只是 load 成功”。

| 基线 | 建议采集方式 | 用途 |
|---|---|---|
| 对象清单 | `mo_database`、`mo_tables`、`information_schema` | 确定 database_id/table_id/account_id |
| 建表语句 | `SHOW CREATE TABLE` | 对比 DDL |
| 行数 | `SELECT COUNT(*) FROM t` | 快速发现丢行/多行 |
| 主键范围 | `MIN(pk)`, `MAX(pk)` | 快速发现范围异常 |
| 分桶 checksum | `GROUP BY pk % N` 或按稳定列分桶 | 大表对比 |
| 关键查询结果 | 复用回归 result 或自定义 select | 验证复杂类型和表达式 |
| 约束行为 | 恢复后执行负向插入/更新 | 验证 PK/UK/FK/default 等仍生效 |

### 2.4 和现有回归的关系

| 内容 | 处理方式 |
|---|---|
| 已被回归覆盖的数据类型/DDL/DML | 直接复用回归数据，不重复造数 |
| 回归 result 文件已有稳定预期 | 恢复端重新执行同类查询，对比 result |
| 回归没有稳定主键的大表 | 用行数 + 多列 checksum + 抽样查询对比 |
| 回归没有覆盖的表类型/列类型/约束 | 使用第 9 节的专项库补齐 |
| 外部表/临时表/视图等特殊对象 | 先以回归真实行为为准，再明确工具应该导出、跳过还是报错 |

### 2.5 第一轮执行优先级

| 优先级 | 内容 | 原因 |
|---|---|---|
| P0 | 回归库 database dump + restore + count/checksum | 最快验证主流程 |
| P0 | 典型单表 table dump + restore | 定位单表 CSV/DDL 问题 |
| P0 | unhappy path：错误 id、错误路径、非法 ts、无权限目录 | 成本低，能快速发现体验问题 |
| P1 | 大表/宽表/大字段表 dump | 验证性能和内存 |
| P1 | 3.0-dev 回归数据升级到 4.0-dev 后 dump | 验证领导关注的兼容性 |
| P2 | 回归缺口专项库 | 全类型、全约束、特殊对象收尾 |

## 3. 测试对象和命令矩阵

### 3.1 导出粒度

| ID | 场景 | 命令模板 | 期望 |
|---|---|---|---|
| CMD-001 | 单表 dump CSV 到文件 | `mo-tool ckp dump --table-id=<tid> --header -o <file> <mo-data>` | 生成单个 CSV，header 正确，退出码 0 |
| CMD-002 | 单表 dump 到 stdout | `mo-tool ckp dump --table-id=<tid> --header <mo-data>` | stdout 输出完整 CSV，不生成文件 |
| CMD-003 | 单表 dump load script | `mo-tool ckp dump --table-id=<tid> --load-script -o <dir> <mo-data>` | 生成 `restore.sql` 和对应 CSV，load 后数据一致 |
| CMD-004 | 单库 dump CSV | `mo-tool ckp dump --database-id=<dbid> --output-dir=<dir> --header <mo-data>` | 导出该库所有普通表，视图不导出 |
| CMD-005 | 单库 dump load script | `mo-tool ckp dump --database-id=<dbid> --output-dir=<dir> --load-script -o <dir> <mo-data>` | 生成一个库级恢复脚本，所有表可恢复 |
| CMD-006 | 租户 dump CSV | `mo-tool ckp dump --account-id=<aid> --output-dir=<dir> --header <mo-data>` | 导出该租户所有 database/table |
| CMD-007 | 租户 dump load script | `mo-tool ckp dump --account-id=<aid> --output-dir=<dir> --load-script -o <dir> <mo-data>` | 所有 database/table 可恢复 |
| CMD-008 | 指定历史快照 | `mo-tool ckp dump --table-id=<tid> --ts=<ts> --header -o <file> <mo-data>` | 导出指定 ts 可见数据，不混入之后变更 |
| CMD-009 | latest 快照 | 不带 `--ts` | 使用最新 checkpoint，可恢复最新可见数据 |
| CMD-010 | `--no-load` | `--load-script --no-load` | 只生成 DDL，不生成或不执行 `LOAD DATA` |

### 3.2 参数组合

| ID | 参数组合 | 覆盖点 | 期望 |
|---|---|---|---|
| ARG-001 | `--header` | CSV 第一行列名 | load 脚本包含 `IGNORE 1 LINES` |
| ARG-002 | 不带 `--header` | 无 header CSV | load 脚本不能错误忽略首行数据 |
| ARG-003 | `--meta-comments` | CSV 文件头注释 | 注释不影响 load，行数统计可信 |
| ARG-004 | `--row-order=storage` | 默认流式顺序 | 不强制排序，性能基线 |
| ARG-005 | `--row-order=lexical` | 可见列字典序 | 输出顺序稳定，数据不丢不重 |
| ARG-006 | 本地 `mo-data` | 本地对象存储 | 正常读取 |
| ARG-007 | S3/MinIO `mo-data` | 远端对象存储 | 正常读取，网络异常可诊断 |
| ARG-008 | `-o` 为文件 | 单表 CSV | 文件路径语义正确 |
| ARG-009 | `-o` 为目录 | load script | 目录路径语义正确 |
| ARG-010 | `--output-dir` 和 `-o` 同时存在 | db/account 模式 | 语义明确，不把 CSV 和 SQL 写错位置 |

## 4. Schema 覆盖测试

### 4.1 表类型覆盖

| ID | 表类型 | 建表/数据准备 | dump 粒度 | 验证点 | 期望 |
|---|---|---|---|---|---|
| TBL-001 | 普通表 | `CREATE TABLE t_normal (...)`，插入多行 | table/db/account | CSV、DDL、load | 完整导出和恢复 |
| TBL-002 | 空普通表 | 只建表不插入 | table/db/account | 空 CSV、DDL | load 后表存在且 0 行 |
| TBL-003 | 临时表 | `CREATE TEMPORARY TABLE t_tmp (...)`，插入数据 | db/account | checkpoint 可见性 | 明确预期：若 checkpoint 不持久化临时表，应不导出；若导出则需可恢复 |
| TBL-004 | 视图 | `CREATE VIEW v AS SELECT ...` | db/account | 文档写明 `relkind='v'` 不导出 | 不导出视图，不影响普通表 |
| TBL-005 | 外部表 CSV localfile | `CREATE EXTERNAL TABLE ... localfile ...` | db/account | 元数据和数据来源 | 明确预期：外部表是否跳过或只导出 DDL；不能误导出不完整数据 |
| TBL-006 | 外部表 S3 CSV | `CREATE EXTERNAL TABLE ... URL s3option ...` | db/account | S3 元数据 | 同上，错误信息清晰 |
| TBL-007 | 外部表 Parquet | `CREATE EXTERNAL TABLE ... infile{"format"='parquet'}` | db/account | Parquet 外表 | 同上 |
| TBL-008 | Hive partition Parquet 外表 | `hive_partitioning='true'` | db/account | 分区列 | 同上 |
| TBL-009 | Cluster table | sys 租户下 `CREATE CLUSTER TABLE` | account/sys | `account_id` 可见性 | sys 下全量可见，普通租户可见范围正确 |
| TBL-010 | CTAS 表 | `CREATE TABLE t_ctas AS SELECT ...` | table/db/account | schema 还原 | DDL 和数据可恢复 |
| TBL-011 | LIKE 表 | `CREATE TABLE t_like LIKE t_src` | table/db/account | 结构复制 | DDL 和数据可恢复 |
| TBL-012 | 分区表 hash | `PARTITION BY HASH(col) PARTITIONS n` | table/db/account | 分区 DDL | load 后 `SHOW CREATE TABLE` 保留分区定义 |
| TBL-013 | 分区表 linear hash | `PARTITION BY LINEAR HASH(expr)` | table/db/account | 表达式分区 | DDL 可执行，数据一致 |
| TBL-014 | 分区表 key | `PARTITION BY KEY(col)` | table/db/account | KEY 分区 | DDL 可执行，数据一致 |
| TBL-015 | 多列分区表 | `PARTITION BY KEY(c1,c2)` | table/db/account | 多列分区 | DDL 可执行，数据一致 |
| TBL-016 | `cluster by` 表 | `CREATE TABLE (...) CLUSTER BY col` | table/db/account | 物理排序定义 | DDL 保留，数据一致 |
| TBL-017 | 带 comment 表 | table comment + column comment | table/db/account | 注释 | `SHOW CREATE TABLE`/information_schema 一致 |
| TBL-018 | 特殊表名 | 关键字、大小写、中文、空格、特殊符号 | table/db/account | 标识符转义、文件名清洗 | DDL 正确加反引号，CSV 文件名安全 |

### 4.2 数据类型覆盖

每种类型都需要至少覆盖：正常值、边界值、`NULL`、默认值、CSV 特殊字符/转义、dump 后 load 一致性。大字段类型还要覆盖大值和内存占用。

| ID | 类型组 | 类型 | 测试值 | 验证点 |
|---|---|---|---|---|
| TYPE-001 | 有符号整数 | `TINYINT` | `-128`, `0`, `127`, `NULL` | 边界值一致 |
| TYPE-002 | 有符号整数 | `SMALLINT` | `-32768`, `0`, `32767`, `NULL` | 边界值一致 |
| TYPE-003 | 有符号整数 | `INT` | `-2147483648`, `0`, `2147483647`, `NULL` | 边界值一致 |
| TYPE-004 | 有符号整数 | `BIGINT` | `-9223372036854775808`, `0`, `9223372036854775807`, `NULL` | 边界值一致 |
| TYPE-005 | 无符号整数 | `TINYINT UNSIGNED` | `0`, `255`, `NULL` | 不变负数，不溢出 |
| TYPE-006 | 无符号整数 | `SMALLINT UNSIGNED` | `0`, `65535`, `NULL` | 边界值一致 |
| TYPE-007 | 无符号整数 | `INT UNSIGNED` | `0`, `4294967295`, `NULL` | 边界值一致 |
| TYPE-008 | 无符号整数 | `BIGINT UNSIGNED` | `0`, `18446744073709551615`, `NULL` | 不能丢精度 |
| TYPE-009 | 浮点 | `FLOAT` | `-1.5`, `0`, `1.2345`, 极大/极小值 | 允许浮点表示误差，但 load 后查询值符合类型语义 |
| TYPE-010 | 浮点 | `DOUBLE` | `-1.5`, `0`, `1.234567890123`, 极大/极小值 | 精度和科学计数法可恢复 |
| TYPE-011 | 精确数 | `DECIMAL(p,s)` | `0.00`, `-999.99`, `999.99`, 高精度小数 | 不丢 scale，不转科学计数法 |
| TYPE-012 | bit | `BIT`, `BIT(1)`, `BIT(8)`, `BIT(64)` | `b'0'`, `b'1'`, `0xFF`, 最大位宽 | dump 表达可被 load 识别 |
| TYPE-013 | 定长字符串 | `CHAR(n)` | 空串、短串、尾部空格、中文 | 尾部空格处理符合 MO 语义 |
| TYPE-014 | 变长字符串 | `VARCHAR(n)` | 空串、逗号、双引号、单引号、反斜杠、换行、中文、emoji | CSV 引号和转义正确 |
| TYPE-015 | 二进制字符串 | `BINARY(n)` | `0x00`, `0xFF`, 混合二进制 | 不能被文本编码破坏 |
| TYPE-016 | 二进制字符串 | `VARBINARY(n)` | 不同长度二进制 | load 后字节一致 |
| TYPE-017 | 大文本 | `TEXT` | 1KB、1MB、接近大字段限制、含换行/引号 | 不截断，不 OOM |
| TYPE-018 | 大二进制 | `BLOB` | 1KB、1MB、随机 bytes、含 `0x00` | 字节级 checksum 一致 |
| TYPE-019 | 枚举 | `ENUM('red','green','blue')` | `'red'`, `'green'`, `NULL`, `''` | 内部值和展示值一致 |
| TYPE-020 | 集合 | `SET('a','b','c')` | `'a'`, `'a,b'`, `''`, `NULL` | 字符串集合可恢复 |
| TYPE-021 | JSON | `JSON` | object、array、嵌套、中文、转义、数字、bool、null | JSON 字符串合法且语义一致 |
| TYPE-022 | 日期 | `DATE` | `1970-01-01`, `2024-02-29`, 边界日期, `NULL` | 日期不偏移 |
| TYPE-023 | 时间 | `TIME` | `00:00:00`, `23:59:59`, 带小数秒, `NULL` | 精度一致 |
| TYPE-024 | 日期时间 | `DATETIME`, `DATETIME(0/3/6)` | 无小数秒、毫秒、微秒 | 小数秒精度一致 |
| TYPE-025 | 时间戳 | `TIMESTAMP`, `TIMESTAMP(0/3/6)` | 不同时区 session 插入/查询 | dump/load 后值符合目标时区语义 |
| TYPE-026 | year | `YEAR` | `1901`, `2000`, `2155`, `NULL` | 年份一致 |
| TYPE-027 | bool | `BOOL`, `BOOLEAN` | `true`, `false`, `0`, `1`, `NULL` | bool 表示一致 |
| TYPE-028 | uuid | `UUID` | 固定 uuid、随机 uuid、NULL | 字符串格式一致 |
| TYPE-029 | vector | `VECTOR(n)` | `[1,2,3]`, 小数向量、零向量、NULL | 维度和值一致 |
| TYPE-030 | datalink | `DATALINK` | 合法 URI、空值、特殊字符 URI | 链接值一致 |

### 4.3 列属性和约束覆盖

| ID | 约束/属性 | 建表示例 | 数据准备 | 验证点 | 期望 |
|---|---|---|---|---|---|
| CONS-001 | `NOT NULL` | `c INT NOT NULL` | 插入非空 | DDL 保留 | load 后仍不可插入 NULL |
| CONS-002 | `NULL` 默认 | `c INT NULL` | 插入 NULL/非 NULL | NULL 表达 | load 后 NULL 正确 |
| CONS-003 | `DEFAULT literal` | `c INT DEFAULT 7` | 插入默认值和显式值 | DDL 保留 | 恢复后默认值可用 |
| CONS-004 | `DEFAULT string` | `c VARCHAR(20) DEFAULT 'abc'` | 默认和特殊字符 | DDL 转义 | 恢复后默认值一致 |
| CONS-005 | `DEFAULT expr` | `c DATETIME DEFAULT NOW()` | 默认时间 | DDL 可执行 | 恢复后表达式语义一致 |
| CONS-006 | 单列主键 | `id INT PRIMARY KEY` | 正常行 | PK DDL | load 后 PK 存在 |
| CONS-007 | 表级主键 | `PRIMARY KEY(id)` | 正常行 | DDL 位置 | load 后 PK 存在 |
| CONS-008 | 复合主键 | `PRIMARY KEY(c1,c2)` | 多组合键 | 复合键 DDL | load 后唯一性一致 |
| CONS-009 | 唯一键 | `UNIQUE KEY uk(c)` | 唯一值和多个 NULL | UNIQUE DDL | load 后唯一约束存在 |
| CONS-010 | 多列唯一键 | `UNIQUE KEY uk(c1,c2)` | 组合唯一 | 组合唯一 | load 后约束存在 |
| CONS-011 | 外键 | `FOREIGN KEY(pid) REFERENCES parent(id)` | 父子表 | 建表顺序 | restore.sql 先父后子，load 不失败 |
| CONS-012 | 外键 `ON DELETE RESTRICT` | FK restrict | 父子数据 | DDL 保留 | 恢复后行为一致 |
| CONS-013 | 外键 `ON DELETE CASCADE` | FK cascade | 父子数据 | DDL 保留 | 恢复后删除父表行为一致 |
| CONS-014 | 外键 `ON DELETE SET NULL` | FK set null | 子表可 NULL | DDL 保留 | 恢复后行为一致 |
| CONS-015 | 外键 `ON UPDATE` | FK update option | 更新父键 | DDL 保留 | 恢复后行为一致 |
| CONS-016 | 自引用外键 | `parent_id REFERENCES t(id)` | 根/子节点 | 建表/load 顺序 | load 不被 FK 卡住 |
| CONS-017 | `AUTO_INCREMENT` | `id BIGINT AUTO_INCREMENT PRIMARY KEY` | 插入 NULL、显式值、大值 | 当前序列 | load 后继续 insert 的下一个值正确 |
| CONS-018 | 表级 `AUTO_INCREMENT=n` | `... AUTO_INCREMENT=100` | 默认插入 | 起始值 | DDL 保留，后续值正确 |
| CONS-019 | column comment | `c INT COMMENT '中文 comment'` | 任意数据 | 注释 | `SHOW FULL COLUMNS` 一致 |
| CONS-020 | table comment | `COMMENT='table comment'` | 任意数据 | 注释 | `SHOW CREATE TABLE` 一致 |
| CONS-021 | 列名关键字 | `` `select` INT `` | 任意数据 | 反引号 | DDL/load 正确 |
| CONS-022 | 列名特殊字符 | `` `a-b` ``, `` `中文列` `` | 任意数据 | 标识符转义 | DDL/load 正确 |
| CONS-023 | 不可恢复约束冲突 | 目标库已有冲突表 | 执行 restore.sql | 错误提示 | 失败可诊断，不静默覆盖 |

### 4.4 索引覆盖

| ID | 索引类型 | 建表/建索引 | 验证点 | 期望 |
|---|---|---|---|---|
| IDX-001 | 普通二级索引 | `CREATE INDEX idx_c ON t(c)` | DDL 是否恢复索引 | load 后索引存在 |
| IDX-002 | 多列索引 | `CREATE INDEX idx_c1_c2 ON t(c1,c2)` | DDL 顺序 | load 后索引存在 |
| IDX-003 | 唯一索引 | `CREATE UNIQUE INDEX uk_c ON t(c)` | 唯一性 | load 后唯一性生效 |
| IDX-004 | fulltext index | `CREATE FULLTEXT INDEX ...` | 索引 DDL | load 后可查询或可重建 |
| IDX-005 | vector IVFFLAT | `CREATE INDEX ... USING IVFFLAT` | 向量索引 DDL | load 后索引存在或明确重建策略 |
| IDX-006 | vector HNSW | `CREATE INDEX ... USING HNSW` | 向量索引 DDL | load 后索引存在或明确重建策略 |

## 5. 数据正确性测试

### 5.1 dump + load 标准流程

| 步骤 | 操作 | 验证 |
|---|---|---|
| 1 | 源库建 schema、插入测试数据 | 记录 `SHOW CREATE TABLE`、行数、checksum |
| 2 | 等待 checkpoint 完成，记录 `ts`、table_id、database_id、account_id | `ts` 可用于历史 dump |
| 3 | 执行 table/db/account dump | 退出码 0，日志无错误 |
| 4 | 在空目标库执行 `restore.sql` 或手工 `LOAD DATA` | load 成功 |
| 5 | 对比源库和目标库 | schema、行数、checksum、sample rows 一致 |
| 6 | 继续插入一行验证约束 | PK/UK/FK/auto_increment/default 行为一致 |

### 5.2 推荐校验 SQL

| ID | 校验项 | SQL/方法 |
|---|---|---|
| CHECK-001 | 行数 | `SELECT COUNT(*) FROM t` |
| CHECK-002 | 主键范围 | `SELECT MIN(pk), MAX(pk) FROM t` |
| CHECK-003 | 全表 checksum | 对每列规范化后 `SUM/COUNT/HASH` |
| CHECK-004 | 分桶 checksum | `GROUP BY pk % 100`，适合大表 |
| CHECK-005 | schema | `SHOW CREATE TABLE t` |
| CHECK-006 | 列元数据 | `information_schema.columns` |
| CHECK-007 | 约束 | `information_schema` + 负向插入验证 |
| CHECK-008 | 索引 | `SHOW INDEX FROM t` |
| CHECK-009 | CSV 行数 | 文件行数减 header/comment 等于可见行数 |
| CHECK-010 | 特殊字符 | 精确查询包含逗号、引号、换行的行 |

### 5.3 DML/MVCC 可见性

| ID | 场景 | 数据准备 | dump ts | 期望 |
|---|---|---|---|---|
| MVCC-001 | insert 后 checkpoint | 插入 A，checkpoint | latest | A 可见 |
| MVCC-002 | delete 后 checkpoint | 插入 A，checkpoint1；删除 A，checkpoint2 | checkpoint2 | A 不可见 |
| MVCC-003 | update 后 checkpoint | A=1，checkpoint1；更新 A=2，checkpoint2 | checkpoint2 | 只看到 A=2 |
| MVCC-004 | 历史 insert | 插入 A，checkpoint1；插入 B，checkpoint2 | checkpoint1 | 只看到 A |
| MVCC-005 | 历史 update | A=1，checkpoint1；A=2，checkpoint2 | checkpoint1 | 看到 A=1 |
| MVCC-006 | truncate | 插入数据 checkpoint1；truncate checkpoint2 | checkpoint2 | 表存在，0 行 |
| MVCC-007 | drop table | 建表插入 checkpoint1；drop checkpoint2 | checkpoint2 | db/account dump 不导出该表 |
| MVCC-008 | alter add column | checkpoint1 后 add column + insert | checkpoint2 | 新列和新值正确 |
| MVCC-009 | alter drop column | checkpoint1 后 drop column | checkpoint2 | DDL 不包含旧列 |
| MVCC-010 | alter modify/default/comment | 修改列属性 | checkpoint2 | DDL 是最新属性 |
| MVCC-011 | 长事务未提交 | 开事务插入不提交，触发 dump | latest | 未提交数据不可见 |
| MVCC-012 | dump 时并发写入 | dump 过程中持续 insert/update/delete | 固定 ts/latest | dump 对应同一快照，不混入半新半旧数据 |

## 6. Unhappy Path 详细用例

### 6.1 参数和对象错误

| ID | 场景 | 命令/操作 | 期望 |
|---|---|---|---|
| ERR-001 | 不指定导出对象 | `mo-tool ckp dump <mo-data>` | 失败，提示必须指定 table/database/account |
| ERR-002 | 同时指定 table 和 database | `--table-id=1 --database-id=2` | 失败，提示参数互斥 |
| ERR-003 | 同时指定 database 和 account | `--database-id=1 --account-id=2` | 失败，提示参数互斥 |
| ERR-004 | 非数字 table id | `--table-id=abc` | 失败，提示非法 id |
| ERR-005 | 负数 id | `--table-id=-1` | 失败，提示非法 id |
| ERR-006 | 不存在 table id | `--table-id=999999999` | 失败或明确 0 结果，不能生成伪成功 CSV |
| ERR-007 | 不存在 database id | `--database-id=999999999` | 失败或明确 `Dumped 0 tables`，行为需固定 |
| ERR-008 | 不存在 account id | `--account-id=999999999` | 失败或明确 `Dumped 0 tables`，行为需固定 |
| ERR-009 | 非法 ts 格式 | `--ts=abc` | 失败，提示 ts 格式 |
| ERR-010 | ts 早于最早 checkpoint | 指定过早 ts | 明确报错或明确选择策略 |
| ERR-011 | ts 晚于最新 checkpoint | 指定未来 ts | 明确报错或使用 latest，行为需固定 |
| ERR-012 | 非法 row-order | `--row-order=random` | 失败，提示合法值 |
| ERR-013 | `--load-script --no-load` 但未指定输出目录 | 缺少 `-o`/`--output-dir` | 失败或 stdout DDL，行为需固定 |
| ERR-014 | db/account 模式缺少 `--output-dir` | `--database-id=1 <mo-data>` | 失败，提示缺少输出目录 |
| ERR-015 | table name 不存在 | `--database-id=<dbid> --table=not_exists` | 失败并提示表不存在，不能生成空 CSV/restore.sql |
| ERR-016 | table name 歧义 | 只传 `--table=<name>`，多个 database/account 下同名 | 失败并提示需要 `--database-id`/`--account-id` 消歧 |
| ERR-017 | account 和 database 不匹配 | `--account-id=<aid1> --database-id=<dbid_of_aid2>` | 失败或导出 0 表，日志必须明确说明无匹配对象 |
| ERR-018 | account 和 table 不匹配 | `--account-id=<aid1> --table-id=<table_of_aid2>` | 失败，不能跨租户误导出 |
| ERR-019 | `--table-id` 与 `--table` 指向不同表 | 同时传冲突对象 | 失败并提示参数冲突 |
| ERR-020 | `--jobs=0` | db/account batch dump | 明确拒绝或等价默认值，行为固定 |
| ERR-021 | `--jobs` 为负数/非数字 | `--jobs=-1` / `--jobs=abc` | 失败，提示非法 jobs |
| ERR-022 | `--jobs` 过大 | `--jobs=10000` | 有上限或资源保护，不能 OOM/hang |
| ERR-023 | `--fs-name` 不存在 | 指定不存在 fileservice | 失败并提示 fileservice 名称 |
| ERR-024 | `--fs-config` 文件不存在/格式错误 | 指定错误 config | 失败并提示 config 读取/解析错误 |

### 6.2 文件系统和对象存储错误

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| FS-001 | mo-data 路径不存在 | 指向不存在目录 | 失败，错误包含路径 |
| FS-002 | mo-data 不是目录 | 指向普通文件 | 失败，错误清楚 |
| FS-003 | mo-data 权限不足 | 去掉读权限 | 失败，不 panic |
| FS-004 | 输出目录不存在 | 指向新目录 | 自动创建或明确失败，行为固定 |
| FS-005 | 输出目录不可写 | 去掉写权限 | 失败，不生成半截成功结果 |
| FS-006 | 输出文件已存在 | `-o existing.csv` | 覆盖/失败策略明确 |
| FS-007 | 输出路径是目录但期望文件 | table CSV `-o <dir>` | 失败，提示路径类型错误 |
| FS-008 | 输出路径是文件但期望目录 | load-script `-o <file>` | 失败，提示路径类型错误 |
| FS-009 | 磁盘空间不足 | 使用受限空间目录 | 失败，错误可诊断，部分文件标记清楚 |
| FS-010 | 中途 kill 进程 | dump 大表时 kill | 不留下被误判为完整的 `restore.sql` |
| FS-011 | 传入 mo-data 上层目录 | 传 `$MO_DATA` 而不是 `$MO_DATA/shared` | 失败信息可诊断，例如明确无 checkpoint 或提示正确 fileservice 根目录 |
| FS-012 | 传入 ckp 子目录 | 传 `$MO_DATA/shared/ckp` | 失败并提示目录层级不正确 |
| FS-013 | 输出目录父路径不存在 | `-o /not/exist/out` | 自动创建完整父目录或明确失败，行为固定 |
| FS-014 | 输出目录中已有半截旧文件 | 复用上次失败的输出目录 | 覆盖/跳过/失败策略明确，不能混入旧 CSV |
| FS-015 | 输出目录和输入目录相同 | `-o` 指向 checkpoint 数据目录内 | 拒绝或强警告，避免污染源数据 |
| FS-016 | CSV 文件名冲突 | 不同表名清洗后同名 | 文件名需唯一，不能互相覆盖 |
| FS-017 | 文件名特殊字符 | 表名包含空格、斜杠、中文、反引号 | CSV 文件名安全，restore.sql 引用正确 |
| S3-001 | S3 endpoint 错误 | 错误 endpoint | 失败超时可控 |
| S3-002 | AK/SK 错误 | 错误凭证 | 失败，鉴权错误明确 |
| S3-003 | bucket 不存在 | 错误 bucket | 失败，bucket/path 信息明确 |
| S3-004 | 网络中断 | dump 中断网络 | 失败或重试后失败，不能 hang |
| S3-005 | 远端对象缺失 | 删除部分 checkpoint object | 失败，不 panic |
| S3-006 | `--s3` 参数不完整 | 缺 bucket/endpoint/key-prefix 等 | 失败，提示缺少字段 |
| S3-007 | backend 不支持 | `--backend=OSS` | 失败，提示合法 backend |
| S3-008 | key-prefix 错误 | 指向不存在前缀 | 失败，不能误判为空 checkpoint |
| S3-009 | S3 权限只读/无 list 权限 | 凭证无法 list/get | 失败信息区分 list/get 权限问题 |

### 6.3 checkpoint/metadata 损坏

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| CORR-001 | checkpoint 文件缺失 | 删除一个 metadata 文件 | 失败，提示缺失对象 |
| CORR-002 | checkpoint 文件截断 | 截断文件 | 失败，不 panic |
| CORR-003 | object 文件损坏 | 修改内容 | 失败或 checksum 错误明确 |
| CORR-004 | 表元数据存在但数据 object 缺失 | 删除表数据 object | 失败，不导出伪空表 |
| CORR-005 | schema metadata 异常 | 人工构造非法 schema | 失败，错误定位到对象/table |
| CORR-006 | DDL 无法重新执行 | 特殊约束或版本差异 | restore.sql 中标记或失败清晰 |
| CORR-007 | 无可用 checkpoint | 空 `shared/ckp` 或未生成 checkpoint | 失败并提示 no checkpoint timestamp，不 panic |
| CORR-008 | 只有 GC checkpoint | 仅存在 `shared/gc` 相关文件 | 失败信息明确，不能把 gc 文件当数据 checkpoint |
| CORR-009 | checkpoint chain 断裂 | 删除中间 meta 文件 | 失败并定位断裂区间 |
| CORR-010 | checkpoint ts 边界文件存在但数据缺失 | meta 存在、object 不存在 | 失败，不导出部分成功表为完整成功 |
| CORR-011 | catalog 可读但用户表 object 损坏 | list databases 成功、dump 表失败 | batch dump 最终退出码非 0，并列出失败表 |
| CORR-012 | DDL metadata 缺失索引 | 源表有二级/向量索引 | restore.sql 应保留索引；缺失时 checksum 可过但 DDL 校验失败 |

### 6.4 生成 SQL/DDL 错误

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| SQL-ERR-001 | `parallel 'true'` 位置错误 | `parallel` 生成在 `IGNORE 1 LINES` 前 | load 报 parser error；工具应生成合法顺序：`IGNORE 1 LINES` 后再 `parallel 'true'` |
| SQL-ERR-002 | header 与 `IGNORE 1 LINES` 不匹配 | 带 `--header` 但 SQL 未忽略 header | load 后首行被当数据或报错，应避免 |
| SQL-ERR-003 | 无 header 却生成 `IGNORE 1 LINES` | 不带 `--header --load-script` | load 丢第一行，应避免 |
| SQL-ERR-004 | 表/列关键字未转义 | 表名/列名为 SQL keyword | restore.sql 可执行 |
| SQL-ERR-005 | 表/列名包含反引号 | 标识符中有反引号 | restore.sql 正确 escape |
| SQL-ERR-006 | 字符串 default/comment 未转义 | comment/default 含引号、换行 | DDL 可执行且元数据一致 |
| SQL-ERR-007 | vector index 丢失 | 源表有 IVFFLAT/HNSW index | 恢复后 `SHOW CREATE TABLE` 保持索引定义 |
| SQL-ERR-008 | 二级索引丢失 | 源表有普通/唯一/fulltext index | 恢复后索引存在 |
| SQL-ERR-009 | 分区定义丢失 | 源表为 partition table | 恢复后分区 DDL 一致 |
| SQL-ERR-010 | FK 建表顺序不合法 | 子表 DDL 早于父表 | restore.sql 能成功执行 |
| SQL-ERR-011 | LOAD DATA 路径不可访问 | restore.sql 使用生成机器绝对路径，目标 MO 在另一机器 | load 失败应易诊断；文档需说明路径要求 |
| SQL-ERR-012 | `--meta-comments` 生成注释影响 load | CSV 头部有 `--` 注释 | restore.sql 应正确跳过注释或禁止直接 load |

### 6.5 load 恢复错误

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| LOAD-ERR-001 | 目标库已存在同名库 | 执行 restore.sql | `CREATE DATABASE IF NOT EXISTS` 行为明确 |
| LOAD-ERR-002 | 目标表已存在 | 执行 restore.sql | 不静默混入旧数据 |
| LOAD-ERR-003 | CSV 文件缺失 | 删除一个 CSV 后执行 SQL | load 失败，定位缺失文件 |
| LOAD-ERR-004 | CSV header 和 SQL 不匹配 | 修改 header | load 失败或数据对比失败 |
| LOAD-ERR-005 | CSV 内容被截断 | 截断 CSV | load 失败或 checksum 不一致 |
| LOAD-ERR-006 | FK 建表顺序错误 | 父子表恢复 | restore.sql 应正确排序 |
| LOAD-ERR-007 | auto_increment 恢复后继续写 | load 后插入默认 id | id 不冲突，序列推进正确 |
| LOAD-ERR-008 | 普通租户权限不足 | 普通租户账号无 create/load 权限 | load 失败，错误明确 |
| LOAD-ERR-009 | 恢复系统库到普通租户 | load `mo_catalog`/`system` 等系统库 | 不建议执行；若执行需失败清晰，不能破坏租户元数据 |
| LOAD-ERR-010 | 目标租户已有同名库但表不完整 | restore.sql 继续执行 | 不能混入旧数据；建议测试 drop 后恢复和未 drop 恢复两种行为 |
| LOAD-ERR-011 | load 中途 kill mysql 客户端 | 大表 load 中断 | 目标库处于可诊断状态，重试策略明确 |
| LOAD-ERR-012 | load 中途重启 MO | 恢复过程中重启 CN/TN | 失败可诊断，不能报成功 |
| LOAD-ERR-013 | load 磁盘空间不足 | 目标 MO 数据盘写满 | load 失败，错误明确 |
| LOAD-ERR-014 | load 后 checksum 不一致 | 人工修改 CSV 一行 | 校验能发现，记录定位方式 |
| LOAD-ERR-015 | load 后 DDL 一致但索引不可用 | `SHOW CREATE` 有索引但查询/插入报错 | 索引恢复需做行为验证 |

### 6.6 并发和资源异常

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| RES-001 | 多个 dump 同时读同一 checkpoint | 并发启动多个 table/database dump | 不互相污染，性能下降可接受 |
| RES-002 | dump 和 checkpoint GC 并发 | dump 时后台 GC 删除旧 object | 固定 ts dump 不受影响；失败时错误明确 |
| RES-003 | dump 和源库继续写入并发 | latest dump 期间持续写入 | dump 基于同一快照，不混入半新半旧数据 |
| RES-004 | 内存限制较低 | 使用 cgroup/容器限制内存 | 工具限流或失败清晰，不 OOM kill |
| RES-005 | CPU 限制较低 | 降低 CPU quota | 可完成，性能指标记录 |
| RES-006 | 输出盘 IO 慢 | 使用低速盘/限速盘 | 不 hang，进度日志持续输出 |
| RES-007 | 超大 `--row-order=lexical` | 大表 lexical 排序 | 内存风险可控，必要时明确拒绝或提示 |
| RES-008 | 进度日志异常 | 大表长时间无输出 | 需要周期性 progress，便于判断是否 hang |

## 7. 性能和大数据测试

| ID | 场景 | 数据规模 | 命令 | 指标 | 期望 |
|---|---|---|---|---|---|
| PERF-001 | 单表小规模 | 1 万行 | table dump | 耗时、大小 | 冒烟通过 |
| PERF-002 | 单表中规模 | 100 万行 | table dump | rows/s、MB/s、CPU/RSS | 达到基线 |
| PERF-003 | 单表大规模 | 1000 万行 | table dump | rows/s、RSS 峰值 | 内存稳定，不 OOM |
| PERF-004 | 超大表 | 1 亿行或 100GB+ | table dump | 总耗时、磁盘、稳定性 | 可完成，产物可 load |
| PERF-005 | 宽表 | 500/1000 列 | table dump | schema 生成、CSV 宽度 | DDL 和数据正确 |
| PERF-006 | 大字段表 | TEXT/BLOB/JSON 大值 | table dump | 内存、文件大小 | 不截断，不 OOM |
| PERF-007 | 多表库 | 100/1000 张表 | database dump | 总耗时、单表耗时 | 不中断，日志清楚 |
| PERF-008 | 多库租户 | 10/100 database | account dump | 总耗时、目录结构 | 全部导出 |
| PERF-009 | storage vs lexical | 同一大表 | 两种 row-order | 排序开销 | lexical 正确且性能可接受 |
| PERF-010 | S3/MinIO | 大表/多表 | 远端 mo-data | 网络吞吐、重试 | 可完成或失败清晰 |
| PERF-011 | dump + load 端到端 | 大表/多表 | restore.sql | RTO、总耗时 | 数据一致 |

## 8. 3.0-dev 到 4.0-dev 兼容性测试

| ID | 源数据 | 操作 | dump 工具 | dump ts | load 目标 | 期望 |
|---|---|---|---|---|---|---|
| COMP-001 | 3.0-dev | 建全类型/全约束测试库 | 3.0-dev | 3.0 checkpoint | 3.0-dev | baseline 通过 |
| COMP-002 | 3.0-dev mo-data | 升级前直接 dump | 4.0-dev | 3.0 checkpoint | 4.0-dev | 4.0 工具可读旧 checkpoint |
| COMP-003 | 升级后 mo-data | 3.0 数据升级到 4.0 | 4.0-dev | 3.0 checkpoint | 4.0-dev | 历史快照正确 |
| COMP-004 | 升级后 mo-data | 4.0 继续 insert/update/delete | 4.0-dev | 4.0 checkpoint | 4.0-dev | 新快照正确 |
| COMP-005 | 升级后 mo-data | 不带 ts dump latest | 4.0-dev | latest | 4.0-dev | latest 正确 |
| COMP-006 | 3.0 dump CSV/SQL | 直接导入 4.0 | 无 | 无 | 4.0-dev | CSV/DDL 兼容 |
| COMP-007 | 3.0 不支持/4.0 新增类型 | 分别建表验证 | 4.0-dev | old/new | 4.0-dev | 旧类型可读，新类型可 dump |
| COMP-008 | 3.0 alter 后升级 | add/drop/modify column | 4.0-dev | old/new | 4.0-dev | schema 版本链正确 |

## 9. 回归缺口补充专项库

回归数据优先，但它不一定覆盖 checkpoint dump 需要的所有边界。建议只对缺口准备 4 个专项 database，避免把测试工作变成重复造数：

| database | 内容 | 用途 |
|---|---|---|
| `ckp_types` | 所有数据类型，每组类型独立表 + 一张全类型宽表 | 类型 dump/load 正确性 |
| `ckp_constraints` | PK/UK/FK/default/not null/auto_increment/comment/index | DDL 和约束恢复 |
| `ckp_tables` | 普通表、空表、临时表、视图、外部表、分区表、cluster by | 表形态覆盖 |
| `ckp_mvcc_perf` | DML 历史快照、大表、多表、多库 | MVCC、性能、稳定性 |

## 10. 通过准则

| 类别 | 通过标准 |
|---|---|
| 功能 | 所有 happy path 命令退出码 0，产物路径和内容符合预期 |
| 数据 | dump + load 后 schema、行数、checksum、关键样本行一致 |
| 约束 | PK/UK/FK/default/auto_increment/comment/index 恢复后行为一致 |
| 表类型 | 支持的表类型可恢复；不支持导出的对象必须明确跳过并记录 |
| 异常 | unhappy path 有明确错误，不 panic，不产生误导性成功文件 |
| 性能 | 大数据场景达到约定基线，无 OOM、无 hang、无不可控临时文件 |
| 兼容 | 3.0-dev checkpoint 在 4.0-dev 指定 ts/latest 场景下恢复正确 |

## 11. 参考依据

- MatrixOne Data Types Overview：官方文档列出整数、浮点、bit、字符串、JSON、日期时间、bool、decimal、UUID、vector、datalink 等类型。
- MatrixOne CREATE TABLE：官方语法包含 temporary table、column definition、primary key、foreign key、auto_increment、comment、partition、cluster by 等。
- MatrixOne CREATE EXTERNAL TABLE：官方语法包含 localfile、S3、Parquet、Hive partition Parquet 外表。
- MatrixOne CREATE CLUSTER TABLE：官方说明 cluster table 在 sys 租户创建，并在其他租户可见。
