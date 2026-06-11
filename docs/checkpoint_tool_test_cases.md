# Checkpoint Dump 工具详细测试用例设计

## 1. 测试目标

验证 `mo-tool ckp dump` 在不同导出粒度、表类型、数据类型、列约束、索引/分区、DML/MVCC、异常输入、大数据量和跨版本升级场景下的正确性、性能和稳定性。

核心结论不能只以“命令执行成功”为准，必须验证：

- dump 产物完整：CSV、目录结构、`restore.sql`、日志、退出码符合预期。
- load 后数据正确：schema、行数、checksum、NULL/空字符串、特殊字符、类型精度一致。
- 失败路径清晰：错误信息明确，不产生容易误判为成功的半截文件。
- 兼容升级可靠：3.0-dev 产生的 checkpoint 在 4.0-dev 中可按预期 dump 和恢复。

## 2. 测试对象和命令矩阵

### 2.1 导出粒度

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

### 2.2 参数组合

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

## 3. Schema 覆盖测试

### 3.1 表类型覆盖

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

### 3.2 数据类型覆盖

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

### 3.3 列属性和约束覆盖

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

### 3.4 索引覆盖

| ID | 索引类型 | 建表/建索引 | 验证点 | 期望 |
|---|---|---|---|---|
| IDX-001 | 普通二级索引 | `CREATE INDEX idx_c ON t(c)` | DDL 是否恢复索引 | load 后索引存在 |
| IDX-002 | 多列索引 | `CREATE INDEX idx_c1_c2 ON t(c1,c2)` | DDL 顺序 | load 后索引存在 |
| IDX-003 | 唯一索引 | `CREATE UNIQUE INDEX uk_c ON t(c)` | 唯一性 | load 后唯一性生效 |
| IDX-004 | fulltext index | `CREATE FULLTEXT INDEX ...` | 索引 DDL | load 后可查询或可重建 |
| IDX-005 | vector IVFFLAT | `CREATE INDEX ... USING IVFFLAT` | 向量索引 DDL | load 后索引存在或明确重建策略 |
| IDX-006 | vector HNSW | `CREATE INDEX ... USING HNSW` | 向量索引 DDL | load 后索引存在或明确重建策略 |

## 4. 数据正确性测试

### 4.1 dump + load 标准流程

| 步骤 | 操作 | 验证 |
|---|---|---|
| 1 | 源库建 schema、插入测试数据 | 记录 `SHOW CREATE TABLE`、行数、checksum |
| 2 | 等待 checkpoint 完成，记录 `ts`、table_id、database_id、account_id | `ts` 可用于历史 dump |
| 3 | 执行 table/db/account dump | 退出码 0，日志无错误 |
| 4 | 在空目标库执行 `restore.sql` 或手工 `LOAD DATA` | load 成功 |
| 5 | 对比源库和目标库 | schema、行数、checksum、sample rows 一致 |
| 6 | 继续插入一行验证约束 | PK/UK/FK/auto_increment/default 行为一致 |

### 4.2 推荐校验 SQL

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

### 4.3 DML/MVCC 可见性

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

## 5. Unhappy Path 详细用例

### 5.1 参数和对象错误

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

### 5.2 文件系统和对象存储错误

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
| S3-001 | S3 endpoint 错误 | 错误 endpoint | 失败超时可控 |
| S3-002 | AK/SK 错误 | 错误凭证 | 失败，鉴权错误明确 |
| S3-003 | bucket 不存在 | 错误 bucket | 失败，bucket/path 信息明确 |
| S3-004 | 网络中断 | dump 中断网络 | 失败或重试后失败，不能 hang |
| S3-005 | 远端对象缺失 | 删除部分 checkpoint object | 失败，不 panic |

### 5.3 checkpoint/metadata 损坏

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| CORR-001 | checkpoint 文件缺失 | 删除一个 metadata 文件 | 失败，提示缺失对象 |
| CORR-002 | checkpoint 文件截断 | 截断文件 | 失败，不 panic |
| CORR-003 | object 文件损坏 | 修改内容 | 失败或 checksum 错误明确 |
| CORR-004 | 表元数据存在但数据 object 缺失 | 删除表数据 object | 失败，不导出伪空表 |
| CORR-005 | schema metadata 异常 | 人工构造非法 schema | 失败，错误定位到对象/table |
| CORR-006 | DDL 无法重新执行 | 特殊约束或版本差异 | restore.sql 中标记或失败清晰 |

### 5.4 load 恢复错误

| ID | 场景 | 操作 | 期望 |
|---|---|---|---|
| LOAD-ERR-001 | 目标库已存在同名库 | 执行 restore.sql | `CREATE DATABASE IF NOT EXISTS` 行为明确 |
| LOAD-ERR-002 | 目标表已存在 | 执行 restore.sql | 不静默混入旧数据 |
| LOAD-ERR-003 | CSV 文件缺失 | 删除一个 CSV 后执行 SQL | load 失败，定位缺失文件 |
| LOAD-ERR-004 | CSV header 和 SQL 不匹配 | 修改 header | load 失败或数据对比失败 |
| LOAD-ERR-005 | CSV 内容被截断 | 截断 CSV | load 失败或 checksum 不一致 |
| LOAD-ERR-006 | FK 建表顺序错误 | 父子表恢复 | restore.sql 应正确排序 |
| LOAD-ERR-007 | auto_increment 恢复后继续写 | load 后插入默认 id | id 不冲突，序列推进正确 |

## 6. 性能和大数据测试

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

## 7. 3.0-dev 到 4.0-dev 兼容性测试

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

## 8. 最小全覆盖测试库建议

建议准备 4 个 database，便于拆分风险：

| database | 内容 | 用途 |
|---|---|---|
| `ckp_types` | 所有数据类型，每组类型独立表 + 一张全类型宽表 | 类型 dump/load 正确性 |
| `ckp_constraints` | PK/UK/FK/default/not null/auto_increment/comment/index | DDL 和约束恢复 |
| `ckp_tables` | 普通表、空表、临时表、视图、外部表、分区表、cluster by | 表形态覆盖 |
| `ckp_mvcc_perf` | DML 历史快照、大表、多表、多库 | MVCC、性能、稳定性 |

## 9. 通过准则

| 类别 | 通过标准 |
|---|---|
| 功能 | 所有 happy path 命令退出码 0，产物路径和内容符合预期 |
| 数据 | dump + load 后 schema、行数、checksum、关键样本行一致 |
| 约束 | PK/UK/FK/default/auto_increment/comment/index 恢复后行为一致 |
| 表类型 | 支持的表类型可恢复；不支持导出的对象必须明确跳过并记录 |
| 异常 | unhappy path 有明确错误，不 panic，不产生误导性成功文件 |
| 性能 | 大数据场景达到约定基线，无 OOM、无 hang、无不可控临时文件 |
| 兼容 | 3.0-dev checkpoint 在 4.0-dev 指定 ts/latest 场景下恢复正确 |

## 10. 参考依据

- MatrixOne Data Types Overview：官方文档列出整数、浮点、bit、字符串、JSON、日期时间、bool、decimal、UUID、vector、datalink 等类型。
- MatrixOne CREATE TABLE：官方语法包含 temporary table、column definition、primary key、foreign key、auto_increment、comment、partition、cluster by 等。
- MatrixOne CREATE EXTERNAL TABLE：官方语法包含 localfile、S3、Parquet、Hive partition Parquet 外表。
- MatrixOne CREATE CLUSTER TABLE：官方说明 cluster table 在 sys 租户创建，并在其他租户可见。
