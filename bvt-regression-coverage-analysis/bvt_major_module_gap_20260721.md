# MatrixOne BVT 与现有回归覆盖差异分析

分析日期：2026-07-21

## 1. 结论概览

本报告分析 MatrixOne BVT 已覆盖、但 TKE nightly、单机 nightly、snapshot、PITR、big-data 和 motr 尚未完整覆盖的测试内容。

### 1.1 分析基线

| 仓库 | 分支 | Commit |
| --- | --- | --- |
| `matrixorigin/matrixone` | `main` | `c3a679182e0f73dae9c20174f1d592a8dbd81c0f` |
| `matrixorigin/motr` | `main` | `bbec419938fcb8b0aaae6e44681b16d84ef7fa17` |
| `matrixorigin/mo-nightly-regression` | `main` | `7ce925c07e76fb77b8938756395cbe680032d9d4` |

BVT 在该基线下包含 72 个顶层目录、1109 个 `.sql/.test` 测试文件。这里统计的是文件数量，不等同于 SQL 断言数量或业务场景数量。

检查的其他回归包括：

- TKE nightly：SSB、TPCH、load data、TPCC、sysbench、并发、全文检索、CDC、HNSW/IVF、ANLI、motr。
- 单机 nightly：backup、SSB、TPCH、load data、TPCC、sysbench、scenario、vector、CDC、MySQL CDC。
- snapshot、PITR、big-data 专项。
- motr：transaction、GC/checkpoint、CDC、snapshot/PITR、vector、fulltext、prepare、multitenant/RBAC、DDL/schema、optimizer、load/export、git4data、cross-dimension 和 issue regression。

### 1.2 覆盖状态定义

| 覆盖状态 | 判断标准 |
| --- | --- |
| 明确缺口 | BVT 已有稳定测试，其他回归未发现对应测试 |
| 部分覆盖 | 其他回归覆盖了主链路或少量场景，但没有覆盖 BVT 的完整边界 |
| 待 case diff | 已有同类专项，仅凭目录或 suite 名称无法确认具体差异 |
| 覆盖较明确 | 已有直接专项覆盖，暂不作为优先缺口 |

“没有独立专项”不等于“完全没有覆盖”。本报告仅将能够从 motr case 或 workflow 中确认的内容标记为直接或部分覆盖，其余内容保留为待 case diff。

### 1.3 核心结论

明确缺口主要集中在以下内容：

| 能力域 | BVT 已覆盖内容 | 其他回归尚未发现的直接覆盖 |
| --- | --- | --- |
| SQL 类型与函数兼容 | `geo`, `array`, `pg_cast`, `charset_collation` | geospatial、array 基础语义与 array index、PostgreSQL cast、collation 边界和错误路径 |
| 扩展与可编程能力 | `procedure`, `udf`, `plugin` | procedure、Starlark、UDF、plugin 的稳定回归 |
| 安全与访问限制 | `security`, `sql_inject`、部分 `zz_accesscontrol` | password、SQL injection、IP whitelist、account restricted |
| 查询和系统元信息 | `system_variable`, `statement_query_type`, `zz_statement_query_type`, `query_result`, `result_count`, `metadata`, `system`, `log`, `task` | 系统变量、查询类型、结果元信息和系统观测能力的稳定专项 |
| 查询结果与来源标记 | `save_query_result`, `sql_source_type` | 查询结果落盘和 SQL source type 专项 |
| 云侧及外部集成 | `mo_cloud`, `dataXtest`, `tenxcloud_xx` | 云侧系统视图、DataX 和 TenxCloud 稳定回归 |

以下内容已有直接或间接测试，结论应为“部分覆盖”，不能再写成完全缺失：

| 能力域 | 已确认覆盖 | 仍需补充 |
| --- | --- | --- |
| 发布订阅 | motr 覆盖 publication 权限和 issue 25601 的发布、订阅、ADD COLUMN 链路 | 中文库表、异常路径、发布对象持续变更和清理边界 |
| Stage | motr 覆盖 stage 创建、导入导出、remove files 和 Parquet round-trip | external stage columns、writable external table、CSV options、权限和错误路径 |
| DDL/Object | motr DDL/schema、big-data、并发场景和 PITR checkpoint dump S3 | sequence、fake PK、部分 foreign key、特殊语法和错误边界 |
| Temporary table | motr 覆盖会话隔离、临时表 FK 错误和 auto increment issue | 其余临时表语义、事务和异常路径 |
| ANALYZE | motr optimizer 有直接 ANALYZE 用例 | 统计信息失效、计划变化和复杂对象边界 |
| 查询语义 | TPCH、big-data、motr optimizer 和 issue regression 有场景覆盖 | recursive CTE、复杂 subquery、distinct/union 等细粒度语义 |
| 分布式事务 | motr transaction、TPCC 和 sysbench 覆盖主链路 | DistTAE、乐观/悲观事务内部异常路径，需要逐项 diff |

已有覆盖比较明确的能力包括 fulltext、vector、snapshot/PITR、prepare statement、git4data、load data、CDC 和 benchmark/performance。它们不作为本轮新增回归的优先项。

## 2. BVT 模块覆盖总览

下面按能力域归并全部 72 个 BVT 顶层目录。每个目录只归入一个能力域，文件数合计为 1109。

| 能力域 | BVT 顶层目录 | 文件数 | 覆盖状态 | 现有回归和剩余缺口 |
| --- | --- | ---: | --- | --- |
| SQL 函数、类型与表达式 | `function`, `dtype`, `operator`, `expression`, `geo`, `array`, `pg_cast`, `charset_collation`, `time_window` | 354 | 部分覆盖 | big-data 覆盖部分 math/string/date/regexp/bitmap；geo、array、cast、collation 和大量边界仍是明确缺口 |
| 查询语义结构 | `join`, `subquery`, `window`, `cte`, `recursive_cte`, `distinct`, `union` | 35 | 部分覆盖 | TPCH/big-data/motr optimizer 有场景覆盖，细粒度语义仍需抽取稳定 case |
| Optimizer | `optimizer` | 24 | 覆盖较明确 | motr `10_optimizer` 有直接专项；需要按 BVT 文件继续做 case diff |
| 执行、计划缓存和统计信息 | `qexec`, `plan_cache`, `hint`, `analyze` | 11 | 部分覆盖 | ANALYZE 已有直接覆盖，big-data 有 spill 场景；plan cache、hint 和小型 qexec 边界仍缺 |
| DDL 与对象语义 | `ddl`, `database`, `table`, `view`, `sequence`, `foreign_key`, `fake_pk`, `auto_increment`, `temporary`, `comment`, `keyword`, `replace_statement`, `set`, `sample` | 144 | 部分覆盖 | motr DDL/schema、并发、big-data 和 checkpoint dump 覆盖主链路；对象级边界不完整 |
| DML | `dml` | 56 | 待 case diff | TPCC、sysbench、big-data 和 issue regression 广泛执行 DML，但尚未和 BVT 的 56 个文件逐项比对 |
| 权限、安全与多租户 | `zz_accesscontrol`, `security`, `sql_inject`, `tenant` | 68 | 部分覆盖 | motr RBAC 覆盖角色、用户、权限矩阵和 grant truncate；password、SQL injection、IP whitelist、account restricted 缺直接专项 |
| 事务与内部链路 | `disttae`, `optimistic`, `pessimistic_transaction` | 81 | 待 case diff | motr transaction、TPCC、sysbench 覆盖事务主链路，内部实现和异常路径需逐项比对 |
| Snapshot/PITR | `snapshot`, `pitr` | 83 | 覆盖较明确 | snapshot workflow、PITR workflow 和 motr `04_snapshot_pitr` 直接覆盖 |
| Git4Data/Data Branch | `git4data` | 70 | 覆盖较明确 | motr `12_git4data` 和 snapshot data branch 直接覆盖 |
| 全文与向量检索 | `fulltext`, `vector` | 33 | 覆盖较明确 | TKE fulltext/HNSW/IVF、单机 vector、motr fulltext/vector 直接覆盖 |
| Prepare Statement | `prepare` | 8 | 覆盖较明确 | motr `07_prepare_statement` 直接覆盖 |
| Load、Stage 与结果落盘 | `load_data`, `stage`, `save_query_result`, `sql_source_type` | 32 | 部分覆盖 | load/export 和 Stage 主链路已有覆盖；save query result、SQL source type 及部分 external/writable stage 仍缺 |
| 发布订阅 | `publication_subscription` | 9 | 部分覆盖 | motr 已有 publication 权限和 issue 25601，BVT 的完整发布订阅矩阵未覆盖 |
| 扩展与可编程能力 | `procedure`, `udf`, `plugin` | 6 | 明确缺口 | 未发现 procedure、Starlark、UDF、plugin 稳定专项 |
| 系统变量、查询元信息与观测 | `system_variable`, `statement_query_type`, `zz_statement_query_type`, `query_result`, `result_count`, `metadata`, `system`, `log`, `task` | 41 | 明确缺口 | 未发现覆盖这些能力面的稳定专项 |
| 云侧和外部集成 | `mo_cloud`, `dataXtest`, `tenxcloud_xx` | 5 | 明确缺口 | 需要先确认环境依赖和用例有效性，再决定放入 motr 或独立集成回归 |
| Benchmark/Performance | `benchmark` | 39 | 覆盖较明确 | TKE/单机 SSB、TPCH、TPCC、sysbench 覆盖性能主链路 |
| 限制项与测试工具 | `feature_limit`, `util` | 10 | 待 case diff | `feature_limit` 需确认是否应转为稳定回归；`util` 更偏测试辅助，不宜直接作为业务模块统计缺口 |

分组文件数校验：`354 + 35 + 24 + 11 + 144 + 56 + 68 + 81 + 83 + 70 + 33 + 8 + 32 + 9 + 6 + 41 + 5 + 39 + 10 = 1109`。

## 3. 明确缺口

### 3.1 SQL 类型与函数兼容

| 小模块 | BVT 目录/用例 | 已有回归 | 确认缺口 |
| --- | --- | --- | --- |
| 地理空间 | `geo/*.sql` | 未发现 geo 专项 | geometry、GeoJSON、geohash、buffer、binary/unary geo functions |
| Array | `array/array.sql`, `array/array_index*.sql` | vector 回归覆盖 ANN，但不等价于 array | array 基础语义、array index、array KNN 及边界 |
| Cast/Collation | `pg_cast/cast.sql`, `charset_collation/*.sql` | 未发现直接专项 | PostgreSQL cast、charset/collation 基础、高级和错误路径 |
| 函数与类型矩阵 | `function`, `dtype`, `operator`, `expression` | big-data 和性能场景只覆盖一部分 | 边界值、错误路径、隐式转换、混合类型表达式；完整范围仍需二次抽样 |

SQL 函数和类型体量较大，不建议整包复制。适合先抽取 geo、array、pg_cast、collation，再依据历史 issue 选择高风险函数和类型边界。

### 3.2 扩展与可编程能力

| 小模块 | BVT 用例 | 确认缺口 |
| --- | --- | --- |
| Procedure | `procedure/procedure.sql` | 创建、执行、参数、异常和权限边界 |
| Starlark | `procedure/starlark*.sql` | SQL 调用、执行失败和外部依赖拆分 |
| UDF | `udf/udf.sql` | 创建、调用、删除和失败路径 |
| Plugin | `plugin/plugin.sql` | 加载、使用、清理和失败路径 |

`starlark_llm` 可能依赖外部服务，应拆分为可 nightly 稳定执行的核心 case 和需要专用环境的集成 case。

### 3.3 安全与访问限制

motr `08_multitenant_rbac` 已覆盖多租户、角色、用户、权限矩阵和 `GRANT TRUNCATE`。剩余明确缺口是：

- `security/password.sql`：密码策略、错误密码和密码变更路径。
- `sql_inject/sql_inject.test`：注入输入和预期拦截/错误行为。
- `zz_accesscontrol/connection_management/ip_whitelist.sql`：IP whitelist 和连接管理。
- `zz_accesscontrol/account_restricted.sql`：账号 restricted 状态和访问行为。

角色 grant/revoke、跨账号权限和账号生命周期仍需对 `zz_accesscontrol` 与 motr RBAC 做 case diff，不能直接列为未覆盖。

### 3.4 查询、结果和系统元信息

| 小模块 | BVT 目录 | 确认缺口 |
| --- | --- | --- |
| 系统变量 | `system_variable` | 跨账号变量、`lower_case_table_names`、remote var expr、event scheduler |
| Statement/query type | `statement_query_type`, `zz_statement_query_type` | query type、query tcp/version、错误语句分类 |
| 查询结果 | `query_result`, `result_count`, `save_query_result` | query result/cloud、result count、结果落盘和异常路径 |
| SQL 来源 | `sql_source_type` | SQL source type 标记和查询校验 |
| 系统观测 | `metadata`, `system`, `log`, `task` | metadata 查询及 system/log/task 表或函数行为 |

这些能力很少由性能回归触发，适合合并为一个轻量的 `query/system metadata` suite。

### 3.5 云侧和外部集成

`mo_cloud`、`dataXtest` 和 `tenxcloud_xx` 未发现稳定专项，但不能直接全部搬入 motr：

- `mo_cloud` 先确认系统视图在独立部署环境是否可执行。
- `dataXtest` 先确认 DataX 服务、数据源和凭据依赖。
- `tenxcloud_xx` 先确认用例是否仍对应当前产品能力。

可脱离外部服务运行的 SQL 放入 motr，依赖外部平台的用例保留为独立集成回归。

## 4. 部分覆盖与待 case diff

### 4.1 发布订阅

已确认 motr 覆盖：

- `suites/08_multitenant_rbac/t/s-3_10.test`：非管理员 publication 管理权限。
- `suites/14_issue_regression/t/issue_25601_publication_add_column.test`：创建 publication、订阅数据库、源表 ADD COLUMN 后订阅可见性。

BVT 仍包含中文库表、发布对象变更、订阅刷新、异常创建和清理等内容。发布订阅应标记为“部分覆盖”，下一步对 `publication_subscription/*.sql` 做逐文件 diff。

### 4.2 Stage、外部表与结果落盘

已确认 motr 覆盖：

- `suites/11_load_export/t/s-3_10.test`：stage 创建、导出、导入和 remove files。
- `suites/11_load_export/t/s-3_15.test`：Parquet stage round-trip。

仍需补充 external stage columns、writable external table、CSV options、远端对象存储权限和错误路径。`save_query_result` 与 `sql_source_type` 仍是明确缺口。

### 4.3 DDL、Temporary Table 与权限细节

已确认 motr 覆盖：

- `suites/09_ddl_schema/t/hr-5.test`：临时表会话隔离。
- `suites/09_ddl_schema/t/tc-11.test`：临时表 foreign key 的预期错误。
- `suites/14_issue_regression/t/issue_10834_temporary_auto_increment.test`：临时表 auto increment issue。
- `suites/08_multitenant_rbac/t/s-4_1.test`：`GRANT TRUNCATE` 和 truncate 权限执行。
- `suites/14_issue_regression/t/issue_24946_replace_child_fk.test`：replace 与 foreign key issue。

因此 temporary table、grant truncate 和 foreign key 不能列为完全未覆盖。sequence、fake PK、comment/keyword/sample 及更多错误路径仍需补充。

### 4.4 ANALYZE、执行与计划缓存

motr `10_optimizer` 已有多条直接 `ANALYZE` 用例。剩余差异主要是：

- `plan_cache`：开关、复用、失效和 DDL 后行为。
- `hint`：hint 生效、不生效和错误提示。
- `qexec`：group/sort spill 的小型稳定语义回归。
- `analyze`：复杂对象、统计信息失效和计划变化边界。

### 4.5 PITR Checkpoint Dump S3

PITR workflow 中的 `CHECKPOINT DUMP S3 WITH PITR DATA` 会：

- 准备类型、约束、索引、分区、CTAS、空表和 DML 历史等覆盖数据。
- 触发 checkpoint，并从共享 COS/S3 路径读取 checkpoint 元数据。
- 使用 `mo-tool ckp dump` 按 database、table、account 粒度导出。
- 在新账号中执行恢复，并比较 DDL、行数、聚合指标和抽样数据。

这说明类型和 DDL 已有“checkpoint 导出/恢复一致性”覆盖，但它验证的是恢复保真度，不会执行 BVT 中全部函数、类型转换和错误语义，因此不能替代 SQL 语义回归。

### 4.6 DML、查询语义和事务

这三类能力在现有大场景中出现频率很高，但“跑到了”不等于覆盖完整：

- `dml` 需要和 TPCC、sysbench、big-data、motr issue regression 做逐文件或语句类别 diff。
- join/window/CTE 在 TPCH、big-data 和 optimizer 中有直接场景，recursive CTE、复杂 subquery、distinct/union 仍需抽取核心 case。
- `disttae`、`optimistic`、`pessimistic_transaction` 需要和 motr `01_transaction` 比较死锁、锁等待、冲突、提交失败和重试边界。

## 5. 回归补充建议

优先级同时考虑业务影响、历史问题、现有覆盖、环境依赖和运行成本，不按 BVT 文件数量直接排序。

| 批次 | 建议补充内容 | 原因 |
| --- | --- | --- |
| 第一批 | `geo`, `array`, `pg_cast`, `charset_collation` | 缺口明确、环境依赖低、SQL 兼容风险高 |
| 第一批 | password、SQL injection、IP whitelist、account restricted | 安全影响高，当前缺少直接专项 |
| 第一批 | `save_query_result`, `sql_source_type`, `system_variable`, `query_result`, `result_count` | 用例体量小，适合形成稳定轻量 suite |
| 第二批 | publication/subscription 剩余矩阵 | 已有基础和 issue 覆盖，适合在现有 motr case 上扩展 |
| 第二批 | plan cache、hint、qexec | 对计划与执行稳定性重要，可补到 optimizer 或 cross-dimension |
| 第二批 | procedure、UDF、plugin 和可独立运行的 Starlark | 缺口明确，但需要先确认功能启用方式和依赖 |
| Case diff 后决定 | `function`, `dtype`, `dml`, DDL/Object、transaction | 体量大且已有大量间接或专项覆盖，不适合整包搬运 |
| 环境确认后决定 | `mo_cloud`, `dataXtest`, `tenxcloud_xx`, `starlark_llm` | 依赖外部平台或服务，需避免 nightly 不稳定 |

建议新增 motr case 时优先复用现有 suite：

- SQL 语义和执行类放入 `10_optimizer`、`13_cross_dimension` 或新建轻量 semantic suite。
- 安全和账号访问类扩展 `08_multitenant_rbac`。
- Stage 和结果落盘扩展 `11_load_export`。
- 发布订阅可扩展 `08_multitenant_rbac`，或按独立能力建立 suite。
- 单点历史问题继续放入 `14_issue_regression`，但不能用 issue case 替代完整功能矩阵。

## 6. 证据索引

### 6.1 BVT

- [MatrixOne BVT cases](https://github.com/matrixorigin/matrixone/tree/main/test/distributed/cases)

### 6.2 motr

- [motr suites](https://github.com/matrixorigin/motr/tree/main/suites)
- `08_multitenant_rbac/t/s-3_10.test`：publication 权限。
- `08_multitenant_rbac/t/s-4_1.test`：权限矩阵和 grant truncate。
- `09_ddl_schema/t/hr-5.test`、`tc-11.test`：temporary table。
- `11_load_export/t/s-3_10.test`、`s-3_15.test`：Stage round-trip。
- `14_issue_regression/t/issue_25601_publication_add_column.test`：发布订阅变更。
- `14_issue_regression/t/issue_10834_temporary_auto_increment.test`：临时表 auto increment。

### 6.3 Nightly workflows

- [TKE nightly](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/nightly-regression-tke-new.yaml)
- [单机 nightly](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/branch-nightly-regression-new.yml)
- [Snapshot](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/snapshot_backup_restore_main.yml)
- [PITR](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/pitr-backup-restore-regression-main.yml)
- [Big Data](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/big-data-test.yml)

## 7. 结论边界

- 本报告对 BVT 使用目录和测试文件口径，对其他回归使用 workflow、suite 和 test 文件口径，不表示 SQL 断言级覆盖率。
- “部分覆盖”表示已经找到直接证据，但没有证明覆盖全部 BVT 行为。
- “明确缺口”表示在当前基线内未发现直接覆盖；仓库新增 case 后需要更新本文基线和结论。
- `function`、`dtype`、DML、DDL、transaction 等大模块仍需 case-level diff，不能仅依据目录名判断缺口数量。
- 环境相关用例需要先确认可执行性、凭据、数据清理和运行成本，再纳入 nightly。
