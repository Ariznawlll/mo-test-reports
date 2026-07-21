# MatrixOne BVT 与现有回归覆盖差异分析

分析日期：2026-07-21

## 1. 覆盖缺口总览

先看状态，再看证据。以下数量严格按 72 个 BVT 顶层目录统计：

| 状态 | 目录数 | 一眼结论 | 代表能力 |
| --- | ---: | --- | --- |
| **未覆盖** | 29 | BVT 已有测试，其他回归未找到直接测试 | Geo/Array/Cast/Collation、Time Window、Plan Cache、Sequence/Fake PK/Comment/Keyword/Sample、扩展能力、安全限制、查询元信息、结果落盘、云侧集成 |
| **部分覆盖** | 31 | 已覆盖主链路，但 BVT 中仍有明确边界未覆盖 | 普通/二级索引、全文索引、向量索引、SQL 函数类型、查询语义、DDL、Load Data、Stage、发布订阅、RBAC、Metadata、ANALYZE |
| **待逐项核对** | 6 | 已有同类大场景，尚未和 BVT case 逐项比较 | DML、DistTAE、乐观/悲观事务、Feature Limit、Util |
| **覆盖较完整** | 6 | 已有直接专项，本轮不作为优先补充项 | Optimizer、Snapshot、PITR、Git4Data、Prepare、Benchmark |

### 1.1 未覆盖

以下内容在 BVT 中已有测试，但在当前 motr 和 nightly 基线中未找到直接回归：

| 大模块 | 明确缺少的测试内容 | BVT 目录 | 建议补充位置 |
| --- | --- | --- | --- |
| SQL 类型与兼容语义 | Geo 函数与数据格式、Array 基础语义和 Array Index、PostgreSQL Cast、Charset/Collation 边界与错误路径 | `geo`, `array`, `pg_cast`, `charset_collation` | motr SQL semantic/optimizer suite |
| 独立 SQL/执行语义 | Time Window、Plan Cache | `time_window`, `plan_cache` | motr SQL semantic/optimizer suite |
| DDL 对象细节 | Sequence、Fake PK、Comment、Reserved/Non-reserved Keyword、Sample | `sequence`, `fake_pk`, `comment`, `keyword`, `sample` | 扩展 motr `09_ddl_schema` |
| 扩展与可编程能力 | Procedure、Starlark、UDF、Plugin 的创建、执行、清理和失败路径 | `procedure`, `udf`, `plugin` | 新建轻量 programmability suite；外部服务依赖单独拆分 |
| 安全与访问限制 | Password、SQL Injection、IP Whitelist、Account Restricted | `security`, `sql_inject`、部分 `zz_accesscontrol` | 扩展 motr `08_multitenant_rbac` |
| 查询类型与系统观测 | System Variable、Statement/Query Type、Query Result、Result Count、System/Log/Task 查询 | `system_variable`, `statement_query_type`, `zz_statement_query_type`, `query_result`, `result_count`, `system`, `log`, `task` | 新建轻量 query/system metadata suite |
| 查询结果与来源标记 | Save Query Result、SQL Source Type | `save_query_result`, `sql_source_type` | 扩展 motr `11_load_export` 或 metadata suite |
| 云侧和外部集成 | MO Cloud 系统视图、DataX、TenxCloud 适配 | `mo_cloud`, `dataXtest`, `tenxcloud_xx` | 先确认环境依赖，再放入 motr 或独立集成回归 |

### 1.2 部分覆盖

以下内容不能写成“已覆盖”：现有回归只覆盖了主链路，右侧内容仍然缺少直接测试。

| 大模块 | 已有覆盖 | 仍缺内容 | BVT 目录 |
| --- | --- | --- | --- |
| 普通、二级与复合索引 | motr DDL/Optimizer 和 issue regression 覆盖部分普通、唯一、复合、Covering、Master Index 及 Index Hint | Create/Alter/Drop、Prefix Index、元数据、DML 一致性、事务冲突和更多类型组合尚未与 BVT 完整对齐 | `ddl`, `dml`, `optimizer`, `optimistic`, `pessimistic_transaction`, `temporary` 等目录中的 index case |
| 全文索引 | motr `06_fulltext_index` 有 48 个测试，覆盖 DDL、分词、检索模式、评分、DML、事务、JSON、Pushdown；issue 25546 覆盖 GoJieba TopK；TKE 有大数据链路 | **GoJieba Parser 的完整 DDL/Natural/Boolean/DML 矩阵**、Datalink 文档索引、三类 membership pushdown、index-plugin dispatch/catalog smoke 未找到完整直接回归 | `fulltext`（12 个 SQL 文件） |
| 向量索引 | motr `05_vector_index` 有 43 个测试，TKE 覆盖 HNSW/IVF 和 pre/post filter，并覆盖 Reindex、内存搜索等主链路 | Adaptive auto/retry、多 CN Search、membership/pre-bloomfilter、IVFPQ/CAGRA 实验参数和 plugin/catalog smoke 仍需补充或逐项核对 | `vector`（21 个 SQL 文件） |
| Load Data | TKE/单机 Load Data 和 motr `11_load_export` 覆盖 CSV/JSON/Parquet 主链路 | Array/Vector、跨类型转换、精度、NULL/Escape 和错误路径未与 21 个 BVT 文件逐项对齐 | `load_data` |
| SQL 函数、类型和表达式 | big-data/TPCH 等场景执行部分 math、string、date、regexp、bitmap 和常用类型 | 边界值、错误路径、隐式转换和混合类型表达式 | `function`, `dtype`, `operator`, `expression` |
| 发布订阅 | motr 覆盖 publication 权限及 issue 25601 的发布、订阅和 ADD COLUMN 链路 | 中文库表、异常路径、发布对象持续变更、订阅刷新和清理边界 | `publication_subscription` |
| Stage | motr 覆盖 Stage 创建、导入导出、Remove Files 和 Parquet Round-trip | External Stage Columns、Writable External Table、CSV Options、权限和错误路径 | `stage` |
| DDL 与对象语义 | motr DDL/schema、big-data、并发场景和 PITR Checkpoint Dump S3 覆盖主链路 | 部分 Foreign Key、Auto Increment、特殊语法和错误边界 | `ddl`, `database`, `table`, `view`, `foreign_key`, `auto_increment`, `replace_statement`, `set` |
| Temporary Table | motr 覆盖会话隔离、临时表 FK 错误和 Auto Increment issue | 事务行为、更多对象语义和异常路径 | `temporary` |
| RBAC 与多租户 | motr 覆盖角色、用户、权限矩阵、Grant Truncate 和账号主链路 | `zz_accesscontrol` 中尚未和 motr 对齐的跨账号、Grant/Revoke 和账号生命周期边界 | `tenant`、部分 `zz_accesscontrol` |
| ANALYZE、执行和 Hint | motr optimizer 有直接 ANALYZE；big-data 有部分 spill 场景 | Hint、QExec 小型 spill 语义、统计信息失效和计划变化 | `analyze`, `hint`, `qexec` |
| 查询语义 | TPCH、big-data、motr optimizer 和 issue regression 覆盖常见 Join、Window 和 CTE 场景 | Recursive CTE、复杂 Subquery、Distinct/Union 及细粒度 NULL/类型边界 | `join`, `subquery`, `window`, `cte`, `recursive_cte`, `distinct`, `union` |
| Metadata | motr Scenario 直接查询 `information_schema.statistics` | Information Schema 和 Statistics 的 BVT 两个文件没有完整稳定对应 | `metadata` |

### 1.3 待逐项核对

| 大模块 | 为什么不能直接判断 | 下一步 |
| --- | --- | --- |
| DML | TPCC、sysbench、big-data 和 issue regression 广泛执行 DML，但不代表覆盖 BVT 的 56 个文件 | 按 Insert/Update/Delete/Replace/异常路径与 BVT 逐项比较 |
| 分布式事务 | motr transaction、TPCC 和 sysbench 覆盖事务主链路，但 DistTAE、乐观/悲观事务内部路径不透明 | 比较死锁、锁等待、冲突、提交失败和重试 case |
| Feature Limit 与 Util | `feature_limit` 可能是限制声明，`util` 偏测试辅助，不能直接按业务模块补回归 | 先确认用例有效性和归属，再决定是否补充 |

### 1.4 覆盖较完整

| 大模块 | 直接覆盖来源 |
| --- | --- |
| Optimizer | motr `10_optimizer` |
| Snapshot/PITR | snapshot workflow、PITR workflow、motr `04_snapshot_pitr` |
| Git4Data/Data Branch | motr `12_git4data`、snapshot data branch |
| Prepare Statement | motr `07_prepare_statement` |
| Benchmark/Performance | TKE/单机 SSB、TPCH、TPCC、sysbench |

“覆盖较完整”不表示和 BVT 逐条相同，只表示已有直接专项，本轮不作为优先补充项。CDC 虽有独立回归，但不属于本次 72 个 BVT 顶层目录的统计范围。

## 2. BVT 功能全量清单

这张表不再按目录名压缩功能，而是按研发关注的数据库能力列出 BVT 主要覆盖项。索引类能力单独拆分，避免隐藏在 DDL、Optimizer 或 Vector 等目录中。

| 大模块 | BVT 主要覆盖的小功能 | BVT 位置 | 状态 | 其他回归覆盖与剩余工作 |
| --- | --- | --- | --- | --- |
| SQL 函数 | 数学、字符串、日期时间、JSON、正则、聚合、窗口、Bitmap 等函数及错误边界 | `function` | 部分覆盖 | big-data/TPCH 执行部分常用函数；需按高风险函数抽取边界与错误 case |
| 数据类型与表达式 | 数值、Decimal、字符、二进制、JSON、Enum、类型转换、运算符和复杂表达式 | `dtype`, `operator`, `expression` | 部分覆盖 | 常见类型被大场景使用；类型边界、隐式转换和混合表达式未完整覆盖 |
| Time Window | Time Window 查询语义 | `time_window` | 未覆盖 | 日期查询只构成间接覆盖，未找到直接专项 |
| Geo/Array/Cast/Collation | GeoJSON/Geometry/Geohash、Array 语义与索引、PostgreSQL Cast、Charset/Collation | `geo`, `array`, `pg_cast`, `charset_collation` | 未覆盖 | 未找到直接专项 |
| 查询语义 | Join、Subquery、Window、CTE/Recursive CTE、Distinct、Union | `join`, `subquery`, `window`, `cte`, `recursive_cte`, `distinct`, `union` | 部分覆盖 | TPCH/big-data/Optimizer 覆盖常见形态；复杂语义边界仍缺 |
| Optimizer | Explain、Join/Index 选择、Runtime Filter、统计估算和改写 | `optimizer` | 覆盖较完整 | motr `10_optimizer` 有直接专项 |
| 执行、统计与 Hint | QExec Spill、Hint、ANALYZE | `qexec`, `hint`, `analyze` | 部分覆盖 | ANALYZE 和部分 Spill 已覆盖；Hint、统计失效仍缺 |
| Plan Cache | Plan Cache 复用和失效 | `plan_cache` | 未覆盖 | 未找到直接专项 |
| 普通与特殊索引 | 普通/唯一/二级/复合/Covering/Prefix/Master Index，Create/Alter/Drop、元数据、DML 一致性、Hint/Range/Order | 分散在 `ddl`, `dml`, `optimizer`, `optimistic`, `pessimistic_transaction`, `temporary` | 部分覆盖 | motr 有 DDL/Optimizer 和多个 issue case；需要建立独立索引矩阵并与 BVT 逐项核对 |
| 全文索引 | DDL/隐藏表、Default/Ngram/GoJieba/JSON/JSONValue/Datalink Parser、Natural/Boolean Mode、TF-IDF/BM25、Join/Union/Aggregate、DML/事务、Pushdown/Membership、Plugin | `fulltext` | 部分覆盖 | motr/TKE 覆盖核心矩阵；GoJieba 仅确认 TopK issue 路径，完整 Parser 矩阵及 Datalink、三类 membership filter、plugin/catalog smoke 仍缺 |
| 向量类型与向量索引 | Vector 类型/函数/距离，IVF_FLAT、Reindex、Pre/Post/Auto Filter、Retry、多 CN、Membership、内存/持久化路径、IVFPQ/CAGRA 参数、Plugin | `vector` | 部分覆盖 | BVT 目录不含 HNSW case；motr/TKE 覆盖 IVF/HNSW 主链路，Auto/Retry、多 CN、membership/pre-bloom、IVFPQ/CAGRA、plugin 需补充或核对 |
| Database/Table/View DDL | Database、Table、View、Alter、Set、Replace 等对象语义 | `database`, `table`, `view`, `ddl`, `set`, `replace_statement` | 部分覆盖 | motr DDL/schema 和大场景覆盖基础链路；特殊语法与错误路径未完整覆盖 |
| DDL 兼容细节 | Sequence、Fake PK、Comment、Keyword、Sample | `sequence`, `fake_pk`, `comment`, `keyword`, `sample` | 未覆盖 | 未找到直接专项 |
| 约束与对象特性 | Foreign Key、Auto Increment、Temporary Table | `foreign_key`, `auto_increment`, `temporary` | 部分覆盖 | FK、临时表和 Auto Increment 有部分直接 case；更多边界仍缺 |
| DML | Insert、Update、Delete、Replace、Truncate、批量和异常路径 | `dml` | 待逐项核对 | TPCC/sysbench/big-data 广泛执行 DML，但未与 56 个 BVT 文件逐项对齐 |
| 分布式事务 | DistTAE、乐观/悲观事务、锁等待、死锁、冲突、提交/回滚和重试 | `disttae`, `optimistic`, `pessimistic_transaction` | 待逐项核对 | motr transaction、TPCC、sysbench 覆盖主链路；内部异常路径需逐项比较 |
| 多租户与 RBAC | Account/User/Role 生命周期、Grant/Revoke、跨账号和对象权限 | `tenant`, `zz_accesscontrol` | 部分覆盖 | motr `08_multitenant_rbac` 覆盖主矩阵；剩余 case 需 diff |
| 安全与访问限制 | Password、SQL Injection、IP Whitelist、Account Restricted | `security`, `sql_inject`、部分 `zz_accesscontrol` | 未覆盖 | 未找到直接专项 |
| Snapshot/PITR | Account/Database/Table 级创建、恢复、权限和对象一致性 | `snapshot`, `pitr` | 覆盖较完整 | Snapshot/PITR workflow 和 motr `04_snapshot_pitr` 直接覆盖 |
| Publication/Subscription | 发布、订阅、权限、对象变更、中文标识和清理 | `publication_subscription` | 部分覆盖 | motr 有权限及 issue 25601；完整发布订阅矩阵仍缺 |
| Load Data | CSV/JSON/Parquet、Array/Vector、类型转换、精度、NULL/Escape 和错误路径 | `load_data` | 部分覆盖 | TKE/单机和 motr 覆盖主链路；21 个 BVT 文件尚未逐项映射 |
| Stage/外部表 | Stage DDL、导入导出、Remove Files、External/Writable Table 和 CSV Options | `stage` | 部分覆盖 | Stage 主链路和 Parquet Round-trip 已覆盖；External/Writable 和权限错误仍缺 |
| 查询结果与来源标记 | Save Query Result、Query Result/Count、SQL Source Type | `save_query_result`, `query_result`, `result_count`, `sql_source_type` | 未覆盖 | 未找到稳定直接专项 |
| Prepare Statement | Prepare/Execute/Deallocate、参数、DDL/DML 和异常路径 | `prepare` | 覆盖较完整 | motr `07_prepare_statement` 直接覆盖 |
| Procedure/UDF/Plugin | Procedure、Starlark、UDF、Plugin 的创建、调用、权限、清理和失败路径 | `procedure`, `udf`, `plugin` | 未覆盖 | 未找到稳定直接专项 |
| Git4Data/Data Branch | Branch、Checkout、Merge、Diff 和 Snapshot Data Branch | `git4data` | 覆盖较完整 | motr `12_git4data` 和 Snapshot Data Branch 直接覆盖 |
| 系统变量与查询观测 | System Variable、Statement/Query Type、System/Log/Task 查询 | `system_variable`, `statement_query_type`, `zz_statement_query_type`, `system`, `log`, `task` | 未覆盖 | 未找到稳定直接专项 |
| Information Schema Metadata | Information Schema 和 Statistics | `metadata` | 部分覆盖 | motr Scenario 会查询 Statistics；BVT 两个文件未完整对应 |
| 云侧与外部集成 | MO Cloud 系统视图、DataX、TenxCloud | `mo_cloud`, `dataXtest`, `tenxcloud_xx` | 未覆盖 | 需先确认环境依赖和用例有效性 |
| Benchmark/Performance | Benchmark SQL 及 SSB/TPCH/TPCC/sysbench 主链路 | `benchmark` | 覆盖较完整 | TKE/单机性能回归直接覆盖 |
| Feature Limit 与测试工具 | 功能限制声明和 BVT 辅助能力 | `feature_limit`, `util` | 待逐项核对 | 先确认是否属于稳定业务回归范围 |

## 3. 分析口径与基线

| 仓库 | 分支 | Commit |
| --- | --- | --- |
| `matrixorigin/matrixone` | `main` | `c3a679182e0f73dae9c20174f1d592a8dbd81c0f` |
| `matrixorigin/motr` | `main` | `bbec419938fcb8b0aaae6e44681b16d84ef7fa17` |
| `matrixorigin/mo-nightly-regression` | `main` | `7ce925c07e76fb77b8938756395cbe680032d9d4` |

BVT 在该基线下包含 72 个顶层目录、1109 个 `.sql/.test` 测试文件。这里统计的是文件数量，不等同于 SQL 断言数量或业务场景数量。

检查的其他回归包括：

- TKE nightly：SSB、TPCH、Load Data、TPCC、sysbench、并发、全文检索、CDC、HNSW/IVF、ANLI、motr。
- 单机 nightly：backup、SSB、TPCH、Load Data、TPCC、sysbench、scenario、Vector、CDC、MySQL CDC。
- Snapshot、PITR、big-data 专项。
- motr：transaction、GC/checkpoint、CDC、Snapshot/PITR、Vector、Fulltext、Prepare、Multitenant/RBAC、DDL/schema、Optimizer、Load/Export、Git4Data、cross-dimension 和 issue regression。

状态判断只使用可在 motr case 或 workflow 中确认的直接证据。“在性能场景中执行过”不等于完整覆盖；无法确认具体差异的模块标记为“待逐项核对”。

## 4. BVT 72 个目录逐项覆盖清单

以下逐项列出 `test/distributed/cases` 的全部 72 个顶层目录。文件数只统计 `.sql/.test`；每个目录只出现一次，总计 1109 个文件。

### 4.1 SQL 函数、类型与表达式（9 个目录）

| BVT 目录 | 文件数 | 目录内主要 case | 状态 | 已有回归 | 仍缺或需核对 |
| --- | ---: | --- | --- | --- | --- |
| `function` | 244 | 数学、字符串、日期时间、JSON、聚合、Bitmap、窗口及 `mo_ctl` 等函数 | 部分覆盖 | big-data、TPCH 和业务场景执行部分常用函数 | 需按函数类别核对边界值、错误路径和隐式转换 |
| `dtype` | 47 | 整数、Decimal/Decimal256、字符/二进制、日期精度、Enum、Datalink 等类型 | 部分覆盖 | 性能和 Load 场景使用常见类型 | Decimal256、Enum、Datalink、精度和边界矩阵未系统覆盖 |
| `operator` | 21 | 算术、位运算、比较、逻辑、NULL、LIKE/REGEXP、Row Constructor | 部分覆盖 | 查询场景执行常见运算符 | MySQL 兼容矩阵、无符号数、时序和 NULL 边界需补 |
| `expression` | 9 | CASE、CTE Filter Pushdown、Interval、Set Variable、溢出回归 | 部分覆盖 | Optimizer 和查询场景覆盖部分表达式 | Interval、UInt64 溢出和组合表达式未形成专项 |
| `geo` | 24 | Geometry/GeoJSON/Geohash、Buffer、SRID、S2/H3、空间关系和有效性 | 未覆盖 | 未找到 Geo 专项 | 整个目录缺直接回归 |
| `array` | 4 | Array 基础语义、Array Index、Array KNN | 未覆盖 | Vector 回归不等价于 Array | 4 个文件均需直接覆盖 |
| `pg_cast` | 1 | PostgreSQL Cast 兼容语法 | 未覆盖 | 未找到直接专项 | `cast.sql` 缺回归 |
| `charset_collation` | 3 | Charset/Collation 基础、高级和错误路径 | 未覆盖 | 未找到直接专项 | 3 个文件均缺回归 |
| `time_window` | 1 | Time Window 查询语义 | 未覆盖 | 日期查询只构成间接覆盖 | `time_window.sql` 缺直接回归 |

### 4.2 查询、Optimizer 与执行（13 个目录）

| BVT 目录 | 文件数 | 目录内主要 case | 状态 | 已有回归 | 仍缺或需核对 |
| --- | ---: | --- | --- | --- | --- |
| `join` | 12 | Inner/Left/Right/Full/Mark/Single/Apply Join、约束、类型和 Spill | 部分覆盖 | TPCH、big-data、motr Optimizer 覆盖常见 Join | Full/Mark/Single/Apply 语义和 Spill 需逐项核对 |
| `subquery` | 7 | FROM/IN/EXISTS/ANY、嵌套聚合、NULL 和 Runtime Filter | 部分覆盖 | TPCH、Optimizer 和 issue case 覆盖部分形态 | NULL、相关子查询和嵌套聚合边界仍缺 |
| `window` | 10 | Window、Value Window、Cube/Rollup、JSON ArrayAgg、Alias/Filter | 部分覆盖 | big-data 和 TPCH 有 Window 场景 | Frame、NULL、Alias 和组合语义需 diff |
| `cte` | 1 | 普通 CTE | 部分覆盖 | motr Optimizer 有 CTE case | 与 `cte.sql` 逐项核对 |
| `recursive_cte` | 3 | Recursive CTE、递归 Insert | 部分覆盖 | 仅有少量 CTE 间接覆盖 | 递归终止、循环、Insert 路径缺直接专项 |
| `distinct` | 1 | DISTINCT 语义 | 部分覆盖 | 查询场景会执行 DISTINCT | `distinct.sql` 边界未单独核对 |
| `union` | 1 | UNION 语义 | 部分覆盖 | 查询和 Fulltext 场景会执行 UNION | `union.sql` 类型兼容和去重边界需核对 |
| `optimizer` | 24 | Explain、Join Order、Index、Runtime Filter、Pushdown、Shuffle、Top | 覆盖较完整 | motr `10_optimizer` 有直接专项 | 仍需按 24 个文件做细粒度映射 |
| `qexec` | 2 | Group 执行和 Sort Spill | 部分覆盖 | big-data 有 Spill 场景 | 两个小型语义 case 未确认直接对应 |
| `plan_cache` | 1 | Plan Cache 复用和失效 | 未覆盖 | 未找到直接专项 | `plan_cache.test` 缺回归 |
| `hint` | 6 | SQL Hint、CTE Hint、Database/Object Remap 和 Session Rewrite | 部分覆盖 | motr 有 Index Hint issue case | CTE/Remap/Session Rewrite 未完整覆盖 |
| `analyze` | 2 | ANALYZE Statement 和 Physical Plan Explain | 部分覆盖 | motr Optimizer 有直接 ANALYZE | 统计失效、复杂对象和物理计划差异需核对 |
| `benchmark` | 39 | TPCH DDL/Load/Q1-Q22 和 TPCDS issue case | 覆盖较完整 | TKE/单机性能回归直接覆盖 | BVT 与性能脚本版本仍需定期同步 |

### 4.3 DDL、对象与 DML（15 个目录）

| BVT 目录 | 文件数 | 目录内主要 case | 状态 | 已有回归 | 仍缺或需核对 |
| --- | ---: | --- | --- | --- | --- |
| `ddl` | 56 | Database/Table/Alter/Constraint/Partition、普通/唯一/二级/Prefix Index、元数据 | 部分覆盖 | motr `09_ddl_schema`、Optimizer、并发和 issue case | 56 个文件尚未逐项映射，Index DDL+DML 是重点 |
| `database` | 7 | Create/Drop、Config、System Table、Create Table Like | 部分覆盖 | motr DDL 和各大场景频繁创建数据库 | Config、System Table 和错误边界需核对 |
| `table` | 27 | 普通/Cluster/Temporary/External Table、Parquet/Hive、Truncate | 部分覆盖 | motr DDL/Load、big-data 覆盖部分 Table/External Table | Parquet 跨类型、Hive Partition、Temporary Index 等不完整 |
| `view` | 10 | Create/Alter/Replace/System View、Subquery View | 部分覆盖 | motr DDL 和 RBAC 有 View case | ANY/EXISTS/IN View、System View 和替换边界需核对 |
| `sequence` | 6 | Create/Alter Sequence、Nextval/Currval 和函数 | 未覆盖 | 未找到 Sequence 专项 | 6 个文件均缺直接回归 |
| `foreign_key` | 17 | FK Check、Self Reference、多层 FK、Show Columns 和历史 issue | 部分覆盖 | motr DDL、并发和 issue 24946 覆盖部分 FK | Self Reference、多层、Check 开关矩阵需 diff |
| `fake_pk` | 1 | Fake Primary Key | 未覆盖 | 未找到直接专项 | `fake.sql` 缺回归 |
| `auto_increment` | 2 | Auto Increment 基础和多列/边界 | 部分覆盖 | TPCC/sysbench 和 motr issue 10834 覆盖部分路径 | BVT 两个文件需逐项核对 |
| `temporary` | 6 | Temporary Table 基础、高级、Index、限制、操作和 Session 隔离 | 部分覆盖 | motr DDL 覆盖 Session、FK 错误和 Auto Increment | Advanced、Limitation、Index 和事务边界不完整 |
| `comment` | 2 | Table/Column Comment 语法 | 未覆盖 | 未找到直接专项 | 2 个文件缺回归 |
| `keyword` | 2 | Reserved/Non-reserved Keyword | 未覆盖 | 未找到直接专项 | 2 个兼容文件缺回归 |
| `replace_statement` | 2 | REPLACE 基础和 Irregular Index | 部分覆盖 | motr issue 24945/24946 等覆盖 Replace 问题 | 通用语义和 Irregular Index 需核对 |
| `set` | 4 | SET、SET Operator、SET TRANSACTION、User Target | 部分覆盖 | 事务和业务场景会执行 SET | Operator/User Target 和错误边界未形成专项 |
| `sample` | 2 | SAMPLE 语法和函数 | 未覆盖 | 未找到直接专项 | 2 个文件缺回归 |
| `dml` | 56 | Insert/Update/Delete/Replace/Select/Show、Checkpoint 和 Workspace | 待逐项核对 | TPCC、sysbench、big-data 和 issue regression 广泛执行 DML | 需按 56 个文件及七个子目录逐项映射 |

### 4.4 权限、多租户与事务（7 个目录）

| BVT 目录 | 文件数 | 目录内主要 case | 状态 | 已有回归 | 仍缺或需核对 |
| --- | ---: | --- | --- | --- | --- |
| `zz_accesscontrol` | 29 | Account/User/Role、Grant、View Security、Password、IP Whitelist、Restricted Account | 部分覆盖 | motr `08_multitenant_rbac` 覆盖 RBAC 和 Grant Truncate | Password Management、IP Whitelist、Restricted Account 及复杂 View 权限不完整 |
| `security` | 1 | Password 安全行为 | 未覆盖 | 未找到直接专项 | `password.sql` 缺回归 |
| `sql_inject` | 1 | SQL Injection 输入与错误行为 | 未覆盖 | 未找到直接专项 | `sql_inject.test` 缺回归 |
| `tenant` | 37 | Account、Cluster Table、Cache、Role/User/Privilege、Pub/Sub 权限 | 部分覆盖 | motr RBAC、Snapshot/PITR 覆盖多账号主链路 | 37 个文件与 RBAC suite 尚未完整映射 |
| `disttae` | 12 | Range/Block/Partition/Workspace Filter、PK Index Filter、Table Stats | 待逐项核对 | 大场景会触发 DistTAE | 内部 Reader/Filter 和 Stats 路径缺稳定直接对应 |
| `optimistic` | 22 | Atomicity、Autocommit、Isolation、WW Conflict、Rollback、Unique Secondary Index | 待逐项核对 | motr Transaction 覆盖乐观事务主链路 | 需比较 22 个文件的冲突、回滚和索引一致性 |
| `pessimistic_transaction` | 47 | Atomicity/Isolation、DDL Retry、Lock/Conflict、Clone、Fulltext/Vector/Snapshot 和 Index | 待逐项核对 | motr Transaction、TPCC 和专项 suite 覆盖部分主链路 | 47 个文件包含跨模块组合，需要逐文件 diff |

### 4.5 数据保护、特殊索引与数据流转（11 个目录）

| BVT 目录 | 文件数 | 目录内主要 case | 状态 | 已有回归 | 仍缺或需核对 |
| --- | ---: | --- | --- | --- | --- |
| `snapshot` | 77 | Cluster/Account/Database/Table Snapshot、FK、View、Pub/Sub、系统表和恢复到新账号 | 覆盖较完整 | Snapshot workflow 和 motr `04_snapshot_pitr` 直接覆盖 | 仍需与 77 个文件定期同步新增 case |
| `pitr` | 6 | PITR 基础、继承、Account Clause 和 Hive Partition External Table | 覆盖较完整 | PITR workflow 和 motr `04_snapshot_pitr` 直接覆盖 | 新增 External Table/Account 语法需保持同步 |
| `git4data` | 70 | Branch Diff/Merge/Edge/Privilege/Unhappy Path 和 Clone | 覆盖较完整 | motr `12_git4data`、Snapshot Data Branch 直接覆盖 | 70 个文件与 motr 版本需定期 diff |
| `fulltext` | 12 | Default/Ngram/GoJieba/JSON/JSONValue/Datalink Parser、TF-IDF/BM25、检索模式、Join、Pushdown、Membership、Plugin、PK Update | 部分覆盖 | motr `06_fulltext_index` 48 个测试，TKE Fulltext 大数据链路及多个 issue case | **Jieba Parser 必须单列核对**；Datalink、三类 Membership Filter、Plugin/Catalog Smoke 未找到直接对应 |
| `vector` | 21 | Vector 函数/类型、IVF_FLAT、L2/IP/Cosine、Reindex、Pre/Post/Auto、Retry、多 CN、Membership、内存路径、IVFPQ/CAGRA 参数、Plugin | 部分覆盖 | motr `05_vector_index` 43 个测试，TKE IVF/HNSW 和 Pre/Post Filter | BVT 不含 HNSW case；Auto/Retry、多 CN、Membership/Pre-bloom、IVFPQ/CAGRA、Plugin 需补充或核对 |
| `prepare` | 8 | Prepare/Execute、Numeric Context、Auto Increment、FK Cache、LIKE、Transaction、Update Join | 覆盖较完整 | motr `07_prepare_statement` 直接覆盖 | 需确认新加的 FK Cache 和 Update Join case 已同步 |
| `load_data` | 21 | CSV/JSONLine/Parquet、Array/Vector、类型转换、精度、NULL/Escape 和错误路径 | 部分覆盖 | TKE/单机 Load Data、motr `11_load_export` 覆盖主链路 | Array/Vector、跨类型转换和精度 case 未逐项映射 |
| `stage` | 9 | Stage DDL、Export Format、External Stage/Columns、Remove Files、Writable External Table | 部分覆盖 | motr 覆盖 Stage Round-trip、Remove Files 和 Parquet | External Columns、Writable Table、CSV Options 和权限错误仍缺 |
| `save_query_result` | 1 | Save Query Result | 未覆盖 | 未找到直接专项 | `save_query_result.sql` 缺回归 |
| `sql_source_type` | 1 | SQL Source Type 标记 | 未覆盖 | 未找到直接专项 | `sql_source_type.sql` 缺回归 |
| `publication_subscription` | 9 | Publication/Subscription、权限、中文库表、对象变更和清理 | 部分覆盖 | motr RBAC 和 issue 25601 覆盖权限与 ADD COLUMN | 9 个文件的中文、异常和持续变更矩阵不完整 |

### 4.6 可编程能力、系统元信息与外部集成（17 个目录）

| BVT 目录 | 文件数 | 目录内主要 case | 状态 | 已有回归 | 仍缺或需核对 |
| --- | ---: | --- | --- | --- | --- |
| `procedure` | 4 | Procedure、Starlark、Starlark SQL 和 LLM | 未覆盖 | 未找到稳定专项 | 外部依赖拆分后补充 4 个文件 |
| `udf` | 1 | UDF 创建、调用和删除 | 未覆盖 | 未找到直接专项 | `udf.sql` 缺回归 |
| `plugin` | 1 | Plugin 加载、使用和清理 | 未覆盖 | 未找到直接专项 | `plugin.sql` 缺回归 |
| `system_variable` | 7 | Event Scheduler、Lower Case Table Names、Remote Expr、同/跨账号变量 | 未覆盖 | 未找到稳定专项 | 7 个文件均缺直接回归 |
| `statement_query_type` | 6 | Statement/Query Type、Prepare、错误语句和回归 | 未覆盖 | 未找到稳定专项 | 6 个文件均缺直接回归 |
| `zz_statement_query_type` | 9 | Query Type/TCP/Version、Result Count、SQL Source Type 和错误分类 | 未覆盖 | 未找到稳定专项 | 9 个文件均缺直接回归 |
| `query_result` | 2 | Query Result 和 Cloud Query Result | 未覆盖 | 未找到稳定专项 | 2 个文件缺回归 |
| `result_count` | 1 | Result Count | 未覆盖 | 未找到直接专项 | `result_count.sql` 缺回归 |
| `metadata` | 2 | Information Schema 和 Statistics | 部分覆盖 | motr Scenario 会查询 `information_schema.statistics` | 两个 BVT 文件没有完整稳定对应 |
| `system` | 1 | System 表或函数行为 | 未覆盖 | 未找到直接专项 | `system.sql` 缺回归 |
| `log` | 12 | Log/Metric/Span/Statement 列、Query CU/Stats/TCP/Version/Hotspot | 未覆盖 | 未找到稳定专项 | 12 个观测元信息文件缺回归 |
| `task` | 1 | SQL Task | 未覆盖 | 未找到直接专项 | `sql_task.sql` 缺回归 |
| `mo_cloud` | 2 | MO Cloud 和 Cloud Information Schema | 未覆盖 | 未找到稳定专项 | 先确认独立部署可执行性 |
| `dataXtest` | 1 | DataX 集成 | 未覆盖 | 未找到直接专项 | 依赖 DataX 环境，需单独集成回归 |
| `tenxcloud_xx` | 2 | TenxCloud 和 JSON 适配 | 未覆盖 | 未找到直接专项 | 先确认功能仍有效及环境依赖 |
| `feature_limit` | 6 | Branch/Snapshot Quota、Function Privilege、参数和 Runtime Registry Check | 待逐项核对 | 部分限制可能由产品配置验证 | 先确认用例有效性和是否适合 nightly |
| `util` | 4 | CHECK、DECLARE、DO、Fault 辅助语法 | 待逐项核对 | 偏测试辅助能力 | 先确认业务归属，再决定是否补充 |

目录校验：`9 + 13 + 15 + 7 + 11 + 17 = 72`；文件数校验：全部目录合计 `1109`。

## 5. 未覆盖详细说明

### 5.1 SQL 类型与函数兼容

| 小模块 | BVT 目录/用例 | 已有回归 | 未覆盖内容 |
| --- | --- | --- | --- |
| 地理空间 | `geo/*.sql` | 未发现 geo 专项 | geometry、GeoJSON、geohash、buffer、binary/unary geo functions |
| Array | `array/array.sql`, `array/array_index*.sql` | vector 回归覆盖 ANN，但不等价于 array | array 基础语义、array index、array KNN 及边界 |
| Cast/Collation | `pg_cast/cast.sql`, `charset_collation/*.sql` | 未发现直接专项 | PostgreSQL cast、charset/collation 基础、高级和错误路径 |
| Time Window | `time_window/time_window.sql` | 日期查询只构成间接覆盖 | Time Window 语义缺直接专项 |

`function`、`dtype`、`operator` 和 `expression` 已有场景覆盖，归入“部分覆盖”，见 6.2。

### 5.2 执行和 DDL 单项

| 小模块 | BVT 目录/用例 | 未覆盖内容 |
| --- | --- | --- |
| Plan Cache | `plan_cache/plan_cache.test` | 复用、失效和 DDL 后行为 |
| Sequence | `sequence` | Create/Alter、Nextval/Currval 和函数 |
| Fake PK | `fake_pk/fake.sql` | Fake Primary Key 语义 |
| Comment/Keyword/Sample | `comment`, `keyword`, `sample` | Comment、保留字兼容和 Sample 语义 |

### 5.3 扩展与可编程能力

| 小模块 | BVT 用例 | 未覆盖内容 |
| --- | --- | --- |
| Procedure | `procedure/procedure.sql` | 创建、执行、参数、异常和权限边界 |
| Starlark | `procedure/starlark*.sql` | SQL 调用、执行失败和外部依赖拆分 |
| UDF | `udf/udf.sql` | 创建、调用、删除和失败路径 |
| Plugin | `plugin/plugin.sql` | 加载、使用、清理和失败路径 |

`starlark_llm` 可能依赖外部服务，应拆分为可 nightly 稳定执行的核心 case 和需要专用环境的集成 case。

### 5.4 安全与访问限制

motr `08_multitenant_rbac` 已覆盖多租户、角色、用户、权限矩阵和 `GRANT TRUNCATE`。仍未覆盖的是：

- `security/password.sql`：密码策略、错误密码和密码变更路径。
- `sql_inject/sql_inject.test`：注入输入和预期拦截/错误行为。
- `zz_accesscontrol/connection_management/ip_whitelist.sql`：IP whitelist 和连接管理。
- `zz_accesscontrol/account_restricted.sql`：账号 restricted 状态和访问行为。

角色 grant/revoke、跨账号权限和账号生命周期仍需对 `zz_accesscontrol` 与 motr RBAC 做 case diff，不能直接列为未覆盖。

### 5.5 查询、结果和系统元信息

| 小模块 | BVT 目录 | 确认缺口 |
| --- | --- | --- |
| 系统变量 | `system_variable` | 跨账号变量、`lower_case_table_names`、remote var expr、event scheduler |
| Statement/query type | `statement_query_type`, `zz_statement_query_type` | query type、query tcp/version、错误语句分类 |
| 查询结果 | `query_result`, `result_count`, `save_query_result` | query result/cloud、result count、结果落盘和异常路径 |
| SQL 来源 | `sql_source_type` | SQL source type 标记和查询校验 |
| 系统观测 | `system`, `log`, `task` | system/log/task 表或函数行为 |

这些能力很少由性能回归触发，适合合并为一个轻量的 `query/system metadata` suite。`metadata` 已在 motr Scenario 中有直接查询，归入“部分覆盖”，但两个 BVT 文件仍需补齐。

### 5.6 云侧和外部集成

`mo_cloud`、`dataXtest` 和 `tenxcloud_xx` 未发现稳定专项，但不能直接全部搬入 motr：

- `mo_cloud` 先确认系统视图在独立部署环境是否可执行。
- `dataXtest` 先确认 DataX 服务、数据源和凭据依赖。
- `tenxcloud_xx` 先确认用例是否仍对应当前产品能力。

可脱离外部服务运行的 SQL 放入 motr，依赖外部平台的用例保留为独立集成回归。

## 6. 部分覆盖与待逐项核对

### 6.1 索引能力

| 索引类型 | BVT 覆盖项 | 已确认的其他回归 | 仍缺或待核对 |
| --- | --- | --- | --- |
| 普通/二级/复合索引 | 普通、唯一、二级、复合、Covering、Prefix、Master Index；DDL、元数据、DML、事务、Hint/Range/Order | motr DDL/Optimizer 和 issue regression 覆盖多类复合/Covering/Master Index 问题 | BVT case 分散在多个目录，尚未形成完整映射；Prefix、元数据、DDL+DML+事务组合需重点 diff |
| 全文索引 | 12 个 SQL 文件覆盖 Default/Ngram/GoJieba/JSON/JSONValue/Datalink Parser、检索模式、评分、DML/事务、Join/Pushdown/Membership 和 Plugin | motr `06_fulltext_index` 有 48 个测试；TKE 覆盖 Load/Create/Search/Delete/Update；issue 24731/24964/25546/25617 覆盖 Join、TopK 和 PK Update | issue 25546 只证明 GoJieba TopK，`gojieba.sql` 的 DDL/Natural/Boolean/Aggregate/DML 完整矩阵仍需核对；Datalink、三类 membership filter、plugin/catalog smoke 未找到直接 case |
| 向量索引 | 21 个 SQL 文件覆盖 Vector 函数/类型、IVF_FLAT、过滤模式、Retry、多 CN、Membership、内存路径、IVFPQ/CAGRA 参数、Plugin/Reindex | motr `05_vector_index` 有 43 个测试；TKE 覆盖 HNSW/IVF/pre-post filter；motr 覆盖 Reindex、内存/Committed Search 和部分 issue | BVT 目录不含 HNSW；Adaptive Auto/Retry、多 CN、membership/pre-bloom、IVFPQ/CAGRA 参数、plugin/catalog smoke 仍需补充或逐项核对 |

因此全文索引和向量索引应标记为“部分覆盖”，不能仅因存在专项 suite 就标记为“覆盖较完整”。

### 6.2 SQL 函数、类型与表达式

big-data、TPCH 和性能场景会执行部分常用函数、类型和表达式，但没有系统覆盖边界值、错误路径、隐式转换和混合类型表达式。该模块体量较大，不建议整包复制；应依据历史 issue 和风险抽取稳定 case。

### 6.3 发布订阅

已确认 motr 覆盖：

- `suites/08_multitenant_rbac/t/s-3_10.test`：非管理员 publication 管理权限。
- `suites/14_issue_regression/t/issue_25601_publication_add_column.test`：创建 publication、订阅数据库、源表 ADD COLUMN 后订阅可见性。

BVT 仍包含中文库表、发布对象变更、订阅刷新、异常创建和清理等内容。发布订阅应标记为“部分覆盖”，下一步对 `publication_subscription/*.sql` 做逐文件 diff。

### 6.4 Stage、外部表与结果落盘

已确认 motr 覆盖：

- `suites/11_load_export/t/s-3_10.test`：stage 创建、导出、导入和 remove files。
- `suites/11_load_export/t/s-3_15.test`：Parquet stage round-trip。

仍需补充 external stage columns、writable external table、CSV options、远端对象存储权限和错误路径。`save_query_result` 与 `sql_source_type` 仍未覆盖。

### 6.5 DDL、Temporary Table 与权限细节

已确认 motr 覆盖：

- `suites/09_ddl_schema/t/hr-5.test`：临时表会话隔离。
- `suites/09_ddl_schema/t/tc-11.test`：临时表 foreign key 的预期错误。
- `suites/14_issue_regression/t/issue_10834_temporary_auto_increment.test`：临时表 auto increment issue。
- `suites/08_multitenant_rbac/t/s-4_1.test`：`GRANT TRUNCATE` 和 truncate 权限执行。
- `suites/14_issue_regression/t/issue_24946_replace_child_fk.test`：replace 与 foreign key issue。

因此 temporary table、grant truncate 和 foreign key 不能列为完全未覆盖。Sequence、Fake PK、Comment/Keyword/Sample 未找到直接专项，已单独归入“未覆盖”。

### 6.6 ANALYZE、执行与 Hint

motr `10_optimizer` 已有多条直接 `ANALYZE` 用例。剩余差异主要是：

- `hint`：hint 生效、不生效和错误提示。
- `qexec`：group/sort spill 的小型稳定语义回归。
- `analyze`：复杂对象、统计信息失效和计划变化边界。

### 6.7 PITR Checkpoint Dump S3

PITR workflow 中的 `CHECKPOINT DUMP S3 WITH PITR DATA` 会：

- 准备类型、约束、索引、分区、CTAS、空表和 DML 历史等覆盖数据。
- 触发 checkpoint，并从共享 COS/S3 路径读取 checkpoint 元数据。
- 使用 `mo-tool ckp dump` 按 database、table、account 粒度导出。
- 在新账号中执行恢复，并比较 DDL、行数、聚合指标和抽样数据。

这说明类型和 DDL 已有“checkpoint 导出/恢复一致性”覆盖，但它验证的是恢复保真度，不会执行 BVT 中全部函数、类型转换和错误语义，因此不能替代 SQL 语义回归。

### 6.8 DML、查询语义和事务

这三类能力在现有大场景中出现频率很高，但“跑到了”不等于覆盖完整：

- `dml` 需要和 TPCC、sysbench、big-data、motr issue regression 做逐文件或语句类别 diff。
- join/window/CTE 在 TPCH、big-data 和 optimizer 中有直接场景，recursive CTE、复杂 subquery、distinct/union 仍需抽取核心 case。
- `disttae`、`optimistic`、`pessimistic_transaction` 需要和 motr `01_transaction` 比较死锁、锁等待、冲突、提交失败和重试边界。

## 7. 回归补充建议

优先级同时考虑业务影响、历史问题、现有覆盖、环境依赖和运行成本，不按 BVT 文件数量直接排序。

| 批次 | 建议补充内容 | 原因 |
| --- | --- | --- |
| 第一批 | `geo`, `array`, `pg_cast`, `charset_collation` | 缺口明确、环境依赖低、SQL 兼容风险高 |
| 第一批 | password、SQL injection、IP whitelist、account restricted | 安全影响高，当前缺少直接专项 |
| 第一批 | `save_query_result`, `sql_source_type`, `system_variable`, `query_result`, `result_count` | 用例体量小，适合形成稳定轻量 suite |
| 第一批 | 全文索引 GoJieba 完整 Parser 矩阵、Datalink、membership filter、plugin/catalog smoke | GoJieba 仅确认 issue 25546 TopK 路径，其余 BVT case 在 motr/TKE 未找到完整对应 |
| 第二批 | publication/subscription 剩余矩阵 | 已有基础和 issue 覆盖，适合在现有 motr case 上扩展 |
| 第二批 | plan cache、hint、qexec | 对计划与执行稳定性重要，可补到 optimizer 或 cross-dimension |
| 第二批 | procedure、UDF、plugin 和可独立运行的 Starlark | 缺口明确，但需要先确认功能启用方式和依赖 |
| 第二批 | 向量索引 Auto/Retry、多 CN、membership/pre-bloom、IVFPQ/CAGRA、plugin | BVT 新增和高级路径较多，motr/TKE 尚未看到完整对应 |
| Case diff 后决定 | 普通/二级/复合索引、`function`, `dtype`, `dml`, DDL/Object、transaction | 体量大且已有大量间接或专项覆盖，不适合整包搬运 |
| 环境确认后决定 | `mo_cloud`, `dataXtest`, `tenxcloud_xx`, `starlark_llm` | 依赖外部平台或服务，需避免 nightly 不稳定 |

建议新增 motr case 时优先复用现有 suite：

- SQL 语义和执行类放入 `10_optimizer`、`13_cross_dimension` 或新建轻量 semantic suite。
- 安全和账号访问类扩展 `08_multitenant_rbac`。
- Stage 和结果落盘扩展 `11_load_export`。
- 发布订阅可扩展 `08_multitenant_rbac`，或按独立能力建立 suite。
- 单点历史问题继续放入 `14_issue_regression`，但不能用 issue case 替代完整功能矩阵。

## 8. 证据索引

### 8.1 BVT

- [MatrixOne BVT cases](https://github.com/matrixorigin/matrixone/tree/main/test/distributed/cases)
- [BVT Fulltext Index](https://github.com/matrixorigin/matrixone/tree/main/test/distributed/cases/fulltext)：12 个 SQL 文件。
- [BVT GoJieba Parser](https://github.com/matrixorigin/matrixone/blob/main/test/distributed/cases/fulltext/gojieba.sql)：DDL、Natural/Boolean Mode、Aggregate、DML 等完整矩阵。
- [BVT Vector Index](https://github.com/matrixorigin/matrixone/tree/main/test/distributed/cases/vector)：21 个 SQL 文件。
- 普通/二级/复合索引 case 分散在 `ddl`、`dml`、`optimizer`、`optimistic`、`pessimistic_transaction`、`temporary` 等目录。

### 8.2 motr

- [motr suites](https://github.com/matrixorigin/motr/tree/main/suites)
- `05_vector_index`：43 个 Vector Index 测试。
- `06_fulltext_index`：48 个 Fulltext Index 测试。
- `14_issue_regression/t/issue_24731_fulltext_join.test`：全文索引 Join。
- `14_issue_regression/t/issue_24964_fulltext_topk_stability.test`、`issue_25546_fulltext_common_term_topk.test`：全文索引 TopK。
- `issue_25546_fulltext_common_term_topk.test` 只证明 GoJieba TopK 路径，不能替代 BVT `gojieba.sql` 的完整 Parser 回归。
- `14_issue_regression/t/issue_25617_sync_irregular_pk_update.test`：Fulltext/IVF 同步索引的主键更新限制。
- `14_issue_regression/t/issue_23965_secondary_index_order_limit.test`、`issue_25460_covering_index_stale_count.test`、`issue_25586_master_index_limit_offset.test`：二级/Covering/Master Index。
- `08_multitenant_rbac/t/s-3_10.test`：publication 权限。
- `08_multitenant_rbac/t/s-4_1.test`：权限矩阵和 grant truncate。
- `09_ddl_schema/t/hr-5.test`、`tc-11.test`：temporary table。
- `11_load_export/t/s-3_10.test`、`s-3_15.test`：Stage round-trip。
- `14_issue_regression/t/issue_25601_publication_add_column.test`：发布订阅变更。
- `14_issue_regression/t/issue_10834_temporary_auto_increment.test`：临时表 auto increment。

### 8.3 Nightly workflows

- [TKE nightly](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/nightly-regression-tke-new.yaml)
- TKE nightly 中 `fulltext_index_test` 覆盖 Load/Create/Search/Delete/Update，`hnsw_index_test` 和 `ivf_pre_post_filter` 覆盖向量索引大数据链路。
- [单机 nightly](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/branch-nightly-regression-new.yml)
- [Snapshot](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/snapshot_backup_restore_main.yml)
- [PITR](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/pitr-backup-restore-regression-main.yml)
- [Big Data](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/big-data-test.yml)

## 9. 结论边界

- 本报告对 BVT 使用目录和测试文件口径，对其他回归使用 workflow、suite 和 test 文件口径，不表示 SQL 断言级覆盖率。
- “部分覆盖”表示已经找到直接证据，但没有证明覆盖全部 BVT 行为。
- “未覆盖”表示在当前基线内未发现直接覆盖；仓库新增 case 后需要更新本文基线和结论。
- 普通索引、Fulltext、Vector、`function`、`dtype`、DML、DDL、transaction 等大模块仍需 case-level diff，不能仅依据目录名或已有 suite 判断完整覆盖。
- 环境相关用例需要先确认可执行性、凭据、数据清理和运行成本，再纳入 nightly。
