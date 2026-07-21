# MatrixOne BVT 与现有回归覆盖差异分析

分析日期：2026-07-21

## 1. 覆盖缺口总览

先看状态，再看证据。当前结论按“是否能在其他回归中找到直接测试”分为四类：

| 状态 | 一眼结论 | 能力范围 |
| --- | --- | --- |
| **未覆盖** | BVT 已有测试，其他回归未找到直接测试 | Geo/Array/Cast/Collation、扩展能力、安全限制、查询元信息、结果落盘、云侧集成 |
| **部分覆盖** | 已覆盖主链路，但 BVT 中仍有明确边界未覆盖 | 普通/二级索引、全文索引、向量索引、SQL 函数类型、发布订阅、Stage、DDL、Temporary Table、RBAC、ANALYZE、查询语义 |
| **待逐项核对** | 已有同类大场景，尚未和 BVT case 逐项比较 | DML、分布式事务、feature limit |
| **覆盖较完整** | 已有直接专项，本轮不作为优先补充项 | Optimizer、Snapshot/PITR、Git4Data、Prepare、Load Data、Benchmark |

### 1.1 未覆盖

以下内容在 BVT 中已有测试，但在当前 motr 和 nightly 基线中未找到直接回归：

| 大模块 | 明确缺少的测试内容 | BVT 目录 | 建议补充位置 |
| --- | --- | --- | --- |
| SQL 类型与兼容语义 | Geo 函数与数据格式、Array 基础语义和 Array Index、PostgreSQL Cast、Charset/Collation 边界与错误路径 | `geo`, `array`, `pg_cast`, `charset_collation` | motr SQL semantic/optimizer suite |
| 扩展与可编程能力 | Procedure、Starlark、UDF、Plugin 的创建、执行、清理和失败路径 | `procedure`, `udf`, `plugin` | 新建轻量 programmability suite；外部服务依赖单独拆分 |
| 安全与访问限制 | Password、SQL Injection、IP Whitelist、Account Restricted | `security`, `sql_inject`、部分 `zz_accesscontrol` | 扩展 motr `08_multitenant_rbac` |
| 查询类型与系统元信息 | System Variable、Statement/Query Type、Query Result、Result Count、Metadata、System/Log/Task 查询 | `system_variable`, `statement_query_type`, `zz_statement_query_type`, `query_result`, `result_count`, `metadata`, `system`, `log`, `task` | 新建轻量 query/system metadata suite |
| 查询结果与来源标记 | Save Query Result、SQL Source Type | `save_query_result`, `sql_source_type` | 扩展 motr `11_load_export` 或 metadata suite |
| 云侧和外部集成 | MO Cloud 系统视图、DataX、TenxCloud 适配 | `mo_cloud`, `dataXtest`, `tenxcloud_xx` | 先确认环境依赖，再放入 motr 或独立集成回归 |

### 1.2 部分覆盖

以下内容不能写成“已覆盖”：现有回归只覆盖了主链路，右侧内容仍然缺少直接测试。

| 大模块 | 已有覆盖 | 仍缺内容 | BVT 目录 |
| --- | --- | --- | --- |
| 普通、二级与复合索引 | motr DDL/Optimizer 和 issue regression 覆盖部分普通、唯一、复合、Covering、Master Index 及 Index Hint | Create/Alter/Drop、Prefix Index、元数据、DML 一致性、事务冲突和更多类型组合尚未与 BVT 完整对齐 | `ddl`, `dml`, `optimizer`, `optimistic`, `pessimistic_transaction`, `temporary` 等目录中的 index case |
| 全文索引 | motr `06_fulltext_index` 有 48 个测试，覆盖 DDL、分词、检索模式、评分、DML、事务、JSON、Pushdown；TKE 有大数据全文索引链路 | Datalink 文档索引、cbitmap/CRoaring/CBloomFilter membership pushdown、index-plugin dispatch/catalog smoke 未找到直接回归 | `fulltext`（12 个 SQL 文件） |
| 向量索引 | motr `05_vector_index` 有 43 个测试，TKE 覆盖 HNSW/IVF 和 pre/post filter，并覆盖 Reindex、内存搜索等主链路 | Adaptive auto/retry、多 CN Search、membership/pre-bloomfilter、IVFPQ/CAGRA 实验参数和 plugin/catalog smoke 仍需补充或逐项核对 | `vector`（21 个 SQL 文件） |
| SQL 函数、类型和表达式 | big-data/TPCH 等场景执行部分 math、string、date、regexp、bitmap 和常用类型 | 边界值、错误路径、隐式转换、混合类型表达式和 Time Window 语义 | `function`, `dtype`, `operator`, `expression`, `time_window` |
| 发布订阅 | motr 覆盖 publication 权限及 issue 25601 的发布、订阅和 ADD COLUMN 链路 | 中文库表、异常路径、发布对象持续变更、订阅刷新和清理边界 | `publication_subscription` |
| Stage | motr 覆盖 Stage 创建、导入导出、Remove Files 和 Parquet Round-trip | External Stage Columns、Writable External Table、CSV Options、权限和错误路径 | `stage` |
| DDL 与对象语义 | motr DDL/schema、big-data、并发场景和 PITR Checkpoint Dump S3 覆盖主链路 | Sequence、Fake PK、部分 Foreign Key、特殊语法和错误边界 | `ddl`, `database`, `table`, `view`, `sequence`, `foreign_key`, `fake_pk`, `auto_increment`, `comment`, `keyword`, `replace_statement`, `set`, `sample` |
| Temporary Table | motr 覆盖会话隔离、临时表 FK 错误和 Auto Increment issue | 事务行为、更多对象语义和异常路径 | `temporary` |
| RBAC 与多租户 | motr 覆盖角色、用户、权限矩阵、Grant Truncate 和账号主链路 | `zz_accesscontrol` 中尚未和 motr 对齐的跨账号、Grant/Revoke 和账号生命周期边界 | `tenant`、部分 `zz_accesscontrol` |
| ANALYZE、执行和计划缓存 | motr optimizer 有直接 ANALYZE；big-data 有部分 spill 场景 | Plan Cache 复用/失效、Hint、QExec 小型 spill 语义、统计信息失效和计划变化 | `analyze`, `plan_cache`, `hint`, `qexec` |
| 查询语义 | TPCH、big-data、motr optimizer 和 issue regression 覆盖常见 Join、Window 和 CTE 场景 | Recursive CTE、复杂 Subquery、Distinct/Union 及细粒度 NULL/类型边界 | `join`, `subquery`, `window`, `cte`, `recursive_cte`, `distinct`, `union` |

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
| Load Data | TKE/单机 Load Data、motr `11_load_export` |
| Benchmark/Performance | TKE/单机 SSB、TPCH、TPCC、sysbench |

“覆盖较完整”不表示和 BVT 逐条相同，只表示已有直接专项，本轮不作为优先补充项。CDC 虽有独立回归，但不属于本次 72 个 BVT 顶层目录的统计范围。

## 2. BVT 功能全量清单

这张表不再按目录名压缩功能，而是按研发关注的数据库能力列出 BVT 主要覆盖项。索引类能力单独拆分，避免隐藏在 DDL、Optimizer 或 Vector 等目录中。

| 大模块 | BVT 主要覆盖的小功能 | BVT 位置 | 状态 | 其他回归覆盖与剩余工作 |
| --- | --- | --- | --- | --- |
| SQL 函数 | 数学、字符串、日期时间、JSON、正则、聚合、窗口、Bitmap 等函数及错误边界 | `function` | 部分覆盖 | big-data/TPCH 执行部分常用函数；需按高风险函数抽取边界与错误 case |
| 数据类型与表达式 | 数值、Decimal、字符、二进制、JSON、Enum、类型转换、运算符、复杂表达式、Time Window | `dtype`, `operator`, `expression`, `time_window` | 部分覆盖 | 常见类型被大场景使用；类型边界、隐式转换和混合表达式未完整覆盖 |
| Geo/Array/Cast/Collation | GeoJSON/Geometry/Geohash、Array 语义与索引、PostgreSQL Cast、Charset/Collation | `geo`, `array`, `pg_cast`, `charset_collation` | 未覆盖 | 未找到直接专项 |
| 查询语义 | Join、Subquery、Window、CTE/Recursive CTE、Distinct、Union | `join`, `subquery`, `window`, `cte`, `recursive_cte`, `distinct`, `union` | 部分覆盖 | TPCH/big-data/Optimizer 覆盖常见形态；复杂语义边界仍缺 |
| Optimizer | Explain、Join/Index 选择、Runtime Filter、统计估算和改写 | `optimizer` | 覆盖较完整 | motr `10_optimizer` 有直接专项 |
| 执行、统计与计划缓存 | QExec Spill、Plan Cache、Hint、ANALYZE | `qexec`, `plan_cache`, `hint`, `analyze` | 部分覆盖 | ANALYZE 和部分 Spill 已覆盖；Plan Cache、Hint、统计失效仍缺 |
| 普通与特殊索引 | 普通/唯一/二级/复合/Covering/Prefix/Master Index，Create/Alter/Drop、元数据、DML 一致性、Hint/Range/Order | 分散在 `ddl`, `dml`, `optimizer`, `optimistic`, `pessimistic_transaction`, `temporary` | 部分覆盖 | motr 有 DDL/Optimizer 和多个 issue case；需要建立独立索引矩阵并与 BVT 逐项核对 |
| 全文索引 | DDL/隐藏表、Default/Ngram/GoJieba/JSON/JSONValue/Datalink Parser、Natural/Boolean Mode、TF-IDF/BM25、Join/Union/Aggregate、DML/事务、Pushdown/Membership、Plugin | `fulltext` | 部分覆盖 | motr/TKE 覆盖核心矩阵；Datalink、三类 membership filter、plugin/catalog smoke 是当前可见缺口 |
| 向量类型与向量索引 | Vector 类型/函数/距离，IVF_FLAT/HNSW/IVFPQ、Reindex、Pre/Post/Auto Filter、Retry、多 CN、Membership、内存/持久化路径、Plugin | `vector` | 部分覆盖 | motr/TKE 覆盖 IVF/HNSW 主链路；Auto/Retry、多 CN、membership/pre-bloom、IVFPQ/CAGRA、plugin 需补充或核对 |
| Database/Table/View DDL | Database、Table、View、Alter、Comment、Keyword、Set、Sample、Replace 等对象语义 | `database`, `table`, `view`, `ddl`, `comment`, `keyword`, `set`, `sample`, `replace_statement` | 部分覆盖 | motr DDL/schema 和大场景覆盖基础链路；特殊语法与错误路径未完整覆盖 |
| 约束与对象特性 | Primary/Fake PK、Foreign Key、Auto Increment、Sequence、Temporary Table | `fake_pk`, `foreign_key`, `auto_increment`, `sequence`, `temporary` | 部分覆盖 | FK、临时表和 Auto Increment 有部分直接 case；Sequence、Fake PK 和更多边界仍缺 |
| DML | Insert、Update、Delete、Replace、Truncate、批量和异常路径 | `dml` | 待逐项核对 | TPCC/sysbench/big-data 广泛执行 DML，但未与 56 个 BVT 文件逐项对齐 |
| 分布式事务 | DistTAE、乐观/悲观事务、锁等待、死锁、冲突、提交/回滚和重试 | `disttae`, `optimistic`, `pessimistic_transaction` | 待逐项核对 | motr transaction、TPCC、sysbench 覆盖主链路；内部异常路径需逐项比较 |
| 多租户与 RBAC | Account/User/Role 生命周期、Grant/Revoke、跨账号和对象权限 | `tenant`, `zz_accesscontrol` | 部分覆盖 | motr `08_multitenant_rbac` 覆盖主矩阵；剩余 case 需 diff |
| 安全与访问限制 | Password、SQL Injection、IP Whitelist、Account Restricted | `security`, `sql_inject`、部分 `zz_accesscontrol` | 未覆盖 | 未找到直接专项 |
| Snapshot/PITR | Account/Database/Table 级创建、恢复、权限和对象一致性 | `snapshot`, `pitr` | 覆盖较完整 | Snapshot/PITR workflow 和 motr `04_snapshot_pitr` 直接覆盖 |
| Publication/Subscription | 发布、订阅、权限、对象变更、中文标识和清理 | `publication_subscription` | 部分覆盖 | motr 有权限及 issue 25601；完整发布订阅矩阵仍缺 |
| Load Data | CSV/JSON/Parquet、S3/本地、批量加载和错误路径 | `load_data` | 覆盖较完整 | TKE/单机 Load Data 和 motr `11_load_export` 直接覆盖 |
| Stage/外部表 | Stage DDL、导入导出、Remove Files、External/Writable Table 和 CSV Options | `stage` | 部分覆盖 | Stage 主链路和 Parquet Round-trip 已覆盖；External/Writable 和权限错误仍缺 |
| 查询结果与来源标记 | Save Query Result、Query Result/Count、SQL Source Type | `save_query_result`, `query_result`, `result_count`, `sql_source_type` | 未覆盖 | 未找到稳定直接专项 |
| Prepare Statement | Prepare/Execute/Deallocate、参数、DDL/DML 和异常路径 | `prepare` | 覆盖较完整 | motr `07_prepare_statement` 直接覆盖 |
| Procedure/UDF/Plugin | Procedure、Starlark、UDF、Plugin 的创建、调用、权限、清理和失败路径 | `procedure`, `udf`, `plugin` | 未覆盖 | 未找到稳定直接专项 |
| Git4Data/Data Branch | Branch、Checkout、Merge、Diff 和 Snapshot Data Branch | `git4data` | 覆盖较完整 | motr `12_git4data` 和 Snapshot Data Branch 直接覆盖 |
| 系统变量与观测元信息 | System Variable、Statement/Query Type、Metadata、System/Log/Task 查询 | `system_variable`, `statement_query_type`, `zz_statement_query_type`, `metadata`, `system`, `log`, `task` | 未覆盖 | 未找到稳定直接专项 |
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

## 4. BVT 完整目录清单

下面按能力域归并全部 72 个 BVT 顶层目录。每个目录只归入一个能力域，文件数合计为 1109。

| 能力域 | BVT 顶层目录 | 文件数 | 覆盖状态 | 现有回归和剩余缺口 |
| --- | --- | ---: | --- | --- |
| SQL 函数、类型与表达式 | `function`, `dtype`, `operator`, `expression`, `geo`, `array`, `pg_cast`, `charset_collation`, `time_window` | 354 | 部分覆盖 | big-data 覆盖部分 math/string/date/regexp/bitmap；geo、array、cast、collation 和大量边界仍未覆盖 |
| 查询语义结构 | `join`, `subquery`, `window`, `cte`, `recursive_cte`, `distinct`, `union` | 35 | 部分覆盖 | TPCH/big-data/motr optimizer 有场景覆盖，细粒度语义仍需抽取稳定 case |
| Optimizer | `optimizer` | 24 | 覆盖较完整 | motr `10_optimizer` 有直接专项；需要按 BVT 文件继续做细粒度核对 |
| 执行、计划缓存和统计信息 | `qexec`, `plan_cache`, `hint`, `analyze` | 11 | 部分覆盖 | ANALYZE 已有直接覆盖，big-data 有 spill 场景；plan cache、hint 和小型 qexec 边界仍缺 |
| DDL 与对象语义 | `ddl`, `database`, `table`, `view`, `sequence`, `foreign_key`, `fake_pk`, `auto_increment`, `temporary`, `comment`, `keyword`, `replace_statement`, `set`, `sample` | 144 | 部分覆盖 | motr DDL/schema、并发、big-data 和 checkpoint dump 覆盖主链路；对象级边界不完整 |
| DML | `dml` | 56 | 待逐项核对 | TPCC、sysbench、big-data 和 issue regression 广泛执行 DML，但尚未和 BVT 的 56 个文件逐项比对 |
| 权限、安全与多租户 | `zz_accesscontrol`, `security`, `sql_inject`, `tenant` | 68 | 部分覆盖 | motr RBAC 覆盖角色、用户、权限矩阵和 grant truncate；password、SQL injection、IP whitelist、account restricted 缺直接专项 |
| 事务与内部链路 | `disttae`, `optimistic`, `pessimistic_transaction` | 81 | 待逐项核对 | motr transaction、TPCC、sysbench 覆盖事务主链路，内部实现和异常路径需逐项比对 |
| Snapshot/PITR | `snapshot`, `pitr` | 83 | 覆盖较完整 | snapshot workflow、PITR workflow 和 motr `04_snapshot_pitr` 直接覆盖 |
| Git4Data/Data Branch | `git4data` | 70 | 覆盖较完整 | motr `12_git4data` 和 snapshot data branch 直接覆盖 |
| 全文与向量检索 | `fulltext`, `vector` | 33 | 部分覆盖 | motr/TKE 覆盖核心矩阵，但 Datalink、membership/plugin、Vector Auto/Retry、多 CN、IVFPQ/CAGRA 等 BVT case 仍缺或待核对 |
| Prepare Statement | `prepare` | 8 | 覆盖较完整 | motr `07_prepare_statement` 直接覆盖 |
| Load、Stage 与结果落盘 | `load_data`, `stage`, `save_query_result`, `sql_source_type` | 32 | 部分覆盖 | load/export 和 Stage 主链路已有覆盖；save query result、SQL source type 及部分 external/writable stage 仍缺 |
| 发布订阅 | `publication_subscription` | 9 | 部分覆盖 | motr 已有 publication 权限和 issue 25601，BVT 的完整发布订阅矩阵未覆盖 |
| 扩展与可编程能力 | `procedure`, `udf`, `plugin` | 6 | 未覆盖 | 未发现 procedure、Starlark、UDF、plugin 稳定专项 |
| 系统变量、查询元信息与观测 | `system_variable`, `statement_query_type`, `zz_statement_query_type`, `query_result`, `result_count`, `metadata`, `system`, `log`, `task` | 41 | 未覆盖 | 未发现覆盖这些能力面的稳定专项 |
| 云侧和外部集成 | `mo_cloud`, `dataXtest`, `tenxcloud_xx` | 5 | 未覆盖 | 需要先确认环境依赖和用例有效性，再决定放入 motr 或独立集成回归 |
| Benchmark/Performance | `benchmark` | 39 | 覆盖较完整 | TKE/单机 SSB、TPCH、TPCC、sysbench 覆盖性能主链路 |
| 限制项与测试工具 | `feature_limit`, `util` | 10 | 待逐项核对 | `feature_limit` 需确认是否应转为稳定回归；`util` 更偏测试辅助，不宜直接作为业务模块统计缺口 |

分组文件数校验：`354 + 35 + 24 + 11 + 144 + 56 + 68 + 81 + 83 + 70 + 33 + 8 + 32 + 9 + 6 + 41 + 5 + 39 + 10 = 1109`。

## 5. 未覆盖详细说明

### 5.1 SQL 类型与函数兼容

| 小模块 | BVT 目录/用例 | 已有回归 | 未覆盖内容 |
| --- | --- | --- | --- |
| 地理空间 | `geo/*.sql` | 未发现 geo 专项 | geometry、GeoJSON、geohash、buffer、binary/unary geo functions |
| Array | `array/array.sql`, `array/array_index*.sql` | vector 回归覆盖 ANN，但不等价于 array | array 基础语义、array index、array KNN 及边界 |
| Cast/Collation | `pg_cast/cast.sql`, `charset_collation/*.sql` | 未发现直接专项 | PostgreSQL cast、charset/collation 基础、高级和错误路径 |

`function`、`dtype`、`operator`、`expression` 和 `time_window` 已有场景覆盖，归入“部分覆盖”，见 6.2。

### 5.2 扩展与可编程能力

| 小模块 | BVT 用例 | 未覆盖内容 |
| --- | --- | --- |
| Procedure | `procedure/procedure.sql` | 创建、执行、参数、异常和权限边界 |
| Starlark | `procedure/starlark*.sql` | SQL 调用、执行失败和外部依赖拆分 |
| UDF | `udf/udf.sql` | 创建、调用、删除和失败路径 |
| Plugin | `plugin/plugin.sql` | 加载、使用、清理和失败路径 |

`starlark_llm` 可能依赖外部服务，应拆分为可 nightly 稳定执行的核心 case 和需要专用环境的集成 case。

### 5.3 安全与访问限制

motr `08_multitenant_rbac` 已覆盖多租户、角色、用户、权限矩阵和 `GRANT TRUNCATE`。仍未覆盖的是：

- `security/password.sql`：密码策略、错误密码和密码变更路径。
- `sql_inject/sql_inject.test`：注入输入和预期拦截/错误行为。
- `zz_accesscontrol/connection_management/ip_whitelist.sql`：IP whitelist 和连接管理。
- `zz_accesscontrol/account_restricted.sql`：账号 restricted 状态和访问行为。

角色 grant/revoke、跨账号权限和账号生命周期仍需对 `zz_accesscontrol` 与 motr RBAC 做 case diff，不能直接列为未覆盖。

### 5.4 查询、结果和系统元信息

| 小模块 | BVT 目录 | 确认缺口 |
| --- | --- | --- |
| 系统变量 | `system_variable` | 跨账号变量、`lower_case_table_names`、remote var expr、event scheduler |
| Statement/query type | `statement_query_type`, `zz_statement_query_type` | query type、query tcp/version、错误语句分类 |
| 查询结果 | `query_result`, `result_count`, `save_query_result` | query result/cloud、result count、结果落盘和异常路径 |
| SQL 来源 | `sql_source_type` | SQL source type 标记和查询校验 |
| 系统观测 | `metadata`, `system`, `log`, `task` | metadata 查询及 system/log/task 表或函数行为 |

这些能力很少由性能回归触发，适合合并为一个轻量的 `query/system metadata` suite。

### 5.5 云侧和外部集成

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
| 全文索引 | 12 个 SQL 文件覆盖 DDL、Parser、检索模式、评分、DML/事务、Join/Pushdown/Membership、Datalink、Plugin | motr `06_fulltext_index` 有 48 个测试；TKE 覆盖 Load/Create/Search/Delete/Update 大数据链路；issue 24731/24964/25546/25617 覆盖 Join、TopK 和 PK Update | Datalink 文档索引、cbitmap/CRoaring/CBloomFilter membership pushdown、plugin dispatch/catalog smoke 未找到直接 case |
| 向量索引 | 21 个 SQL 文件覆盖 Vector 函数/类型、IVF、过滤模式、Retry、多 CN、Membership、内存路径、IVFPQ/CAGRA、Plugin/Reindex | motr `05_vector_index` 有 43 个测试；TKE 覆盖 HNSW/IVF/pre-post filter；motr 覆盖 Reindex、内存/Committed Search 和部分 issue | Adaptive Auto/Retry、多 CN、membership/pre-bloom、IVFPQ/CAGRA 实验参数、plugin/catalog smoke 仍需补充或逐项核对 |

因此全文索引和向量索引应标记为“部分覆盖”，不能仅因存在专项 suite 就标记为“覆盖较完整”。

### 6.2 SQL 函数、类型与表达式

big-data、TPCH 和性能场景会执行部分常用函数、类型和表达式，但没有系统覆盖边界值、错误路径、隐式转换、混合类型表达式和 Time Window 语义。该模块体量较大，不建议整包复制；应依据历史 issue 和风险抽取稳定 case。

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

因此 temporary table、grant truncate 和 foreign key 不能列为完全未覆盖。sequence、fake PK、comment/keyword/sample 及更多错误路径仍需补充。

### 6.6 ANALYZE、执行与计划缓存

motr `10_optimizer` 已有多条直接 `ANALYZE` 用例。剩余差异主要是：

- `plan_cache`：开关、复用、失效和 DDL 后行为。
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
| 第一批 | 全文索引 Datalink、membership filter、plugin/catalog smoke | BVT 已有明确 case，motr `06_fulltext_index` 和 TKE 未找到直接对应 |
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
- [BVT Vector Index](https://github.com/matrixorigin/matrixone/tree/main/test/distributed/cases/vector)：21 个 SQL 文件。
- 普通/二级/复合索引 case 分散在 `ddl`、`dml`、`optimizer`、`optimistic`、`pessimistic_transaction`、`temporary` 等目录。

### 8.2 motr

- [motr suites](https://github.com/matrixorigin/motr/tree/main/suites)
- `05_vector_index`：43 个 Vector Index 测试。
- `06_fulltext_index`：48 个 Fulltext Index 测试。
- `14_issue_regression/t/issue_24731_fulltext_join.test`：全文索引 Join。
- `14_issue_regression/t/issue_24964_fulltext_topk_stability.test`、`issue_25546_fulltext_common_term_topk.test`：全文索引 TopK。
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
