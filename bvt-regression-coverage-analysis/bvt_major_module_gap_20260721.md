# BVT 大模块与现有回归覆盖缺口

分析日期：2026-07-21

## 1. 结论

这份文档按“大模块”口径整理 MatrixOne BVT 已覆盖、但现有其他回归没有明确覆盖或只间接覆盖的内容。

当前检查的其他回归包括：

- TKE nightly：SSB、TPCH、load data、TPCC、sysbench1000w、concurrent、fulltext、CDC、HNSW/IVF、motr
- 单机 nightly：backup、SSB、TPCH、load data、TPCC、sysbench1000w、scenario、vector、CDC、MySQL CDC
- snapshot 专项
- PITR 专项
- big-data 专项
- motr：transaction、GC/checkpoint、CDC、snapshot/PITR、vector、fulltext、prepare、multitenant/RBAC、DDL/schema、optimizer、load/export、git4data、issue regression

核心结论：

1. BVT 当前有 72 个顶层模块、约 1109 个 `.sql/.test` 用例。
2. 现有回归重点覆盖性能链路和少数专项能力，不是 BVT 大模块的完整子集。
3. 缺口最大的不是 fulltext/vector/snapshot/PITR 这类已有专项，而是 SQL 语义兼容、权限安全细节、发布订阅、扩展能力、外部 stage、系统观测元信息等模块。

## 2. 大模块缺口汇总

| 优先级 | BVT 大模块 | BVT 涉及目录 | BVT 用例规模 | 其他回归覆盖情况 | 缺口结论 |
| --- | --- | --- | ---: | --- | --- |
| P0 | SQL 语义与类型/函数兼容 | `function`, `dtype`, `operator`, `expression`, `geo`, `array`, `pg_cast`, `charset_collation`, `time_window` | 389 | big-data 覆盖 math/string/date/regexp/bitmap 等少量大表查询；TPCH/SSB/sysbench 间接覆盖部分表达式 | 缺少细粒度 SQL 语义兼容回归，尤其 geospatial、array、类型边界、cast、collation |
| P0 | 发布订阅 | `publication_subscription` | 9 | 未在 TKE/单机/snapshot/PITR/big-data/motr 中看到明确专项 | 发布、订阅、中文库表、订阅变更等链路需要补 |
| P0 | 扩展与可编程能力 | `procedure`, `udf`, `plugin` | 6 | 未看到明确专项 | 存储过程、Starlark、UDF、plugin 加载/执行链路缺回归 |
| P1 | 权限、安全与账号访问控制 | `zz_accesscontrol`, `security`, `sql_inject`, `tenant` | 68 | motr 有 `08_multitenant_rbac`，snapshot/PITR 涉及多账号；但 BVT 权限面更宽 | password、SQL inject、ip whitelist、account restricted、grant/truncate 等细节缺覆盖 |
| P1 | Stage/外部数据/查询结果落盘 | `stage`, `save_query_result`, `sql_source_type` | 11 | big-data 有 parquet export stage；motr 有 load/export | external stage、writable external table、remove stage files、save query result、SQL source type 没有完整专项 |
| P1 | DDL/对象语义兼容 | `ddl`, `database`, `table`, `view`, `sequence`, `foreign_key`, `fake_pk`, `auto_increment`, `temporary`, `comment`, `keyword`, `replace_statement`, `set`, `sample` | 196 | motr 有 `09_ddl_schema`，big-data 有 DDL/DML，大场景会间接覆盖 | 基础对象语义不是完整覆盖，sequence、foreign key、fake pk、temporary、comment/keyword 仍建议抽核心 |
| P1 | 查询语义结构 | `join`, `subquery`, `window`, `cte`, `recursive_cte`, `distinct`, `union` | 35 | TPCH/big-data 覆盖 join/window 等性能场景；motr optimizer 有部分 CTE/issue case | 缺少按语义组织的 join/subquery/window/recursive CTE 等稳定回归 |
| P1 | 系统变量、查询元信息与观测 | `system_variable`, `statement_query_type`, `zz_statement_query_type`, `query_result`, `result_count`, `metadata`, `system`, `log`, `task` | 41 | 未看到明确专项；prepare 已由 motr 覆盖，但 statement/query type 不等价于 prepare | query type、result count、query result、system variable、metadata/log/task 等观测类功能缺覆盖 |
| P2 | 查询执行与计划缓存细节 | `qexec`, `plan_cache`, `hint`, `analyze` | 11 | motr optimizer 和 big-data spill 场景有间接覆盖 | plan cache、qexec group/sort spill、hint/analyze 细节不完整 |
| P2 | 云侧/集成适配 | `mo_cloud`, `dataXtest`, `tenxcloud_xx` | 5 | 未看到明确专项 | cloud information_schema、mo_cloud、DataX、TenxCloud 适配类用例缺覆盖 |
| P2 | 分布式事务/内部链路细节 | `disttae`, `optimistic`, `pessimistic_transaction` | 81 | motr transaction、TPCC/sysbench 覆盖事务主链路 | BVT 中 disttae/乐观/悲观事务细节可能仍需和 motr 做差异比对 |

## 3. 大模块下的小模块缺口

### 3.1 SQL 语义与类型/函数兼容

总判断：这是 BVT 中体量最大的能力面，其他回归有查询场景的间接覆盖，但缺少按 SQL 语义拆分的稳定回归。

| 小模块 | BVT 目录 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| 函数语义 | `function` | big-data 覆盖 math/string/date/regexp/bitmap 等少量函数类 | 函数边界值、错误路径、隐式类型转换、JSON/decimal/time/string 等细粒度函数语义 |
| 类型系统 | `dtype` | TPCH/sysbench/big-data 会间接碰到部分类型 | 类型边界、cast 规则、类型比较、NULL/默认值、异常输入 |
| 操作符/表达式 | `operator`, `expression` | 查询场景间接覆盖 | 复杂表达式、运算符优先级、混合类型表达式、错误路径 |
| 地理空间 | `geo` | 未看到明确专项 | geometry 构造、GeoJSON、geohash、buffer、binary/unary geo functions |
| Array 能力 | `array` | vector 回归覆盖 ANN，但不等价于 array 语义 | array 基础语义、array index、array KNN、array 与向量索引边界 |
| 兼容语法 | `pg_cast`, `charset_collation` | 未看到明确专项 | PostgreSQL cast 语法、charset/collation 基础/高级/错误路径 |
| 时间窗口 | `time_window` | big-data 有 date 类查询 | time window 语义本身缺专项 |

### 3.2 发布订阅

总判断：发布订阅是独立功能链路，当前其他回归未看到明确覆盖，属于最清晰的缺口。

| 小模块 | BVT 目录/用例 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| 基础发布订阅 | `publication_subscription/pub_sub*.sql` | 未看到明确专项 | create publication、create subscription、订阅数据可见性 |
| 兼容与边界 | `pub_sub_chinese_db_table.sql` | 未看到明确专项 | 中文库表、特殊命名、异常订阅路径 |
| 变更链路 | `pub_sub_improvement*.sql`, `publish_subscribe.sql` | 未看到明确专项 | 发布对象变更、订阅刷新、清理链路 |

### 3.3 扩展与可编程能力

总判断：procedure/UDF/plugin 在 BVT 有冒烟，但 nightly/motr 没有形成稳定专项。

| 小模块 | BVT 目录/用例 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| 存储过程 | `procedure/procedure.sql` | 未看到明确专项 | 创建、执行、参数、异常、权限边界 |
| Starlark | `procedure/starlark*.sql` | 未看到明确专项 | Starlark SQL 调用、执行失败、外部依赖拆分 |
| UDF | `udf/udf.sql` | 未看到明确专项 | UDF 创建/调用/删除最小链路 |
| Plugin | `plugin/plugin.sql` | 未看到明确专项 | plugin 加载、使用、清理、失败路径 |

### 3.4 权限、安全与账号访问控制

总判断：motr 已有 RBAC 大方向，但 BVT 权限安全细节更多，不能认为已完整覆盖。

| 小模块 | BVT 目录 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| 多租户/RBAC | `tenant`, `zz_accesscontrol` | motr `08_multitenant_rbac`、snapshot/PITR 多账号 | 需要和 motr 做 case diff，确认角色/用户/账号操作缺口 |
| 账号访问限制 | `zz_accesscontrol/account_restricted.sql`, `connection_management/ip_whitelist.sql` | 未看到明确专项 | account restricted、ip whitelist、连接管理 |
| 权限授权细节 | `zz_accesscontrol/grant_*.sql` | motr RBAC 部分覆盖 | grant truncate、role grant/revoke、跨账号权限边界 |
| 密码安全 | `security/password.sql` | 未看到明确专项 | 密码策略、错误密码、密码变更路径 |
| SQL 注入 | `sql_inject/sql_inject.test` | 未看到明确专项 | 注入攻击输入、预期拦截/错误路径 |

### 3.5 Stage/外部数据/查询结果落盘

总判断：big-data 和 motr 覆盖了 load/export 的一部分，但 BVT 中 stage 相关对象和查询结果落盘没有完整专项。

| 小模块 | BVT 目录/用例 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| External stage | `stage/external_stage*.sql` | big-data 有 parquet export stage | external stage 创建、列映射、读写路径 |
| Writable external table | `stage/writable_external*.sql` | 部分 load/export 间接覆盖 | writable external table、CSV options、写入校验 |
| Stage 文件管理 | `stage/remove_stage_files.sql` | 未看到明确专项 | remove stage files、路径清理、权限边界 |
| 查询结果落盘 | `save_query_result/save_query_result.sql` | 未看到明确专项 | save query result 基础链路和异常路径 |
| SQL 来源类型 | `sql_source_type/sql_source_type.sql` | 未看到明确专项 | SQL source type 标记和查询校验 |

### 3.6 DDL/对象语义兼容

总判断：DDL/schema 有 motr 和大场景间接覆盖，但 BVT 中很多对象级语义仍缺少专项。

| 小模块 | BVT 目录 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| 基础对象 | `ddl`, `database`, `table`, `view` | motr `09_ddl_schema`、big-data DDL | 与 motr 做差异比对后补特殊语法和错误路径 |
| Sequence | `sequence` | 未看到明确专项 | create/alter sequence、nextval/currval、边界值 |
| Foreign key | `foreign_key` | scenario 有 alter/drop FK 并发，DDL 可能间接覆盖 | FK check、self reference、disable foreign key check、issue case |
| Fake PK/Auto increment | `fake_pk`, `auto_increment` | TPCC/sysbench 间接覆盖 auto_increment | fake primary key、auto increment 多列/边界/重载缓存 |
| Temporary/Replace/Set | `temporary`, `replace_statement`, `set` | big-data 有 replace into CTAS，sysbench/TPCC 间接覆盖 | temporary table、replace 语义、set 语句边界 |
| 兼容细节 | `comment`, `keyword`, `sample` | 未看到明确专项 | comment 语法、关键字兼容、sample 语法 |

### 3.7 查询语义结构

总判断：TPCH/big-data 覆盖的是查询性能和大数据路径，不等价于 BVT 的查询语义专项。

| 小模块 | BVT 目录 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| Join | `join` | TPCH/big-data 覆盖 inner/left/full outer join | join 语义边界、特殊 ON 条件、NULL 行为 |
| Subquery | `subquery` | motr issue regression 有零散 issue | correlated subquery、update/delete 子查询、异常路径 |
| Window | `window` | big-data 有 window function | 排序、partition、frame、类型边界 |
| CTE/Recursive CTE | `cte`, `recursive_cte` | motr optimizer 有部分 CTE | recursive CTE、循环/终止条件、复杂引用 |
| Distinct/Union | `distinct`, `union` | 查询场景间接覆盖 | distinct/union 语义、去重、类型兼容 |

### 3.8 系统变量、查询元信息与观测

总判断：这类模块偏系统可观测和查询元数据，现有性能/专项回归基本不会系统性覆盖。

| 小模块 | BVT 目录 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| 系统变量 | `system_variable` | 未看到明确专项 | 跨账号变量、lower_case_table_names、remote var expr、event scheduler |
| Statement/query type | `statement_query_type`, `zz_statement_query_type` | prepare 已有 motr，但不等价 | query type、query tcp、query version、SQL source type、错误语句分类 |
| 查询结果元信息 | `query_result`, `result_count` | 未看到明确专项 | query result、query result cloud、result count |
| 系统元数据 | `metadata`, `system`, `log`, `task` | 未看到明确专项 | metadata 查询、system/log/task 表或函数行为 |

### 3.9 查询执行与计划缓存细节

总判断：optimizer 有专项，但 qexec/plan cache/hint/analyze 这些执行细节还缺少明确覆盖。

| 小模块 | BVT 目录 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| Plan cache | `plan_cache` | 未看到明确专项 | plan cache 开关、复用、失效 |
| QExec | `qexec` | big-data 有 spill sort/hash join 间接覆盖 | group、sort spill 的小型稳定语义回归 |
| Hint/Analyze | `hint`, `analyze` | motr optimizer 间接覆盖 | hint 生效/不生效、analyze 统计信息路径 |

### 3.10 云侧/集成适配

总判断：这类能力容易依赖环境，BVT 有用例但其他回归没有稳定专项。

| 小模块 | BVT 目录 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| MO Cloud | `mo_cloud` | 未看到明确专项 | cloud information_schema、mo_cloud 相关系统视图 |
| DataX | `dataXtest` | 未看到明确专项 | DataX 集成链路，需要确认环境依赖 |
| TenxCloud | `tenxcloud_xx` | 未看到明确专项 | TenxCloud 适配类 SQL，需要确认是否仍有效 |

### 3.11 分布式事务/内部链路细节

总判断：事务主链路已有 motr/TPCC/sysbench 覆盖，但 BVT 的内部实现细节需要和 motr 再做差异比对。

| 小模块 | BVT 目录 | 其他回归已有覆盖 | 还缺什么 |
| --- | --- | --- | --- |
| 悲观事务 | `pessimistic_transaction` | motr `01_transaction`、TPCC/sysbench | 和 motr 做 case diff，补死锁、锁等待、异常路径缺口 |
| 乐观事务 | `optimistic` | motr `01_transaction` 间接覆盖 | 冲突检测、提交失败、重试边界 |
| DistTAE | `disttae` | 事务/大场景间接覆盖 | disttae 特有语义和内部链路回归 |

## 4. 最值得优先补的“大模块”

### 4.1 SQL 语义与类型/函数兼容

BVT 已覆盖内容：

- 函数：`function`，244 个 `.sql/.test`
- 类型：`dtype`，47 个 `.sql/.test`
- 操作符/表达式：`operator`, `expression`
- geospatial：`geo`
- array/array index：`array`
- cast/collation：`pg_cast`, `charset_collation`

现有其他回归覆盖情况：

- big-data 只覆盖部分大表查询函数，如 math、string、date、regexp、bitmap。
- TPCH/SSB/sysbench 会间接跑到表达式、join、类型，但目标是性能/大查询，不是细粒度 SQL 语义。

缺口：

- geospatial 基本没有专项回归。
- array 语义和 array index 没有明确专项。
- 类型边界、错误路径、隐式/显式转换、collation、PostgreSQL cast 兼容没有完整回归。
- 函数模块体量最大，不能认为 big-data 的几类函数测试覆盖了 BVT 的函数面。

建议：

- 第一批先补 `geo`、`array`、`charset_collation`、`pg_cast`。
- `function` 和 `dtype` 不建议整包搬运，建议按高风险函数和 issue 历史抽核心 case。

### 4.2 发布订阅

BVT 已覆盖内容：

- `publication_subscription/pub_sub.sql`
- `publication_subscription/pub_sub2.sql`
- `publication_subscription/pub_sub3.sql`
- `publication_subscription/pub_sub4.sql`
- `publication_subscription/pub_sub_chinese_db_table.sql`
- `publication_subscription/publish_subscribe.sql`

现有其他回归覆盖情况：

- 未看到 TKE、单机、snapshot、PITR、big-data、motr 中有明确发布订阅专项。

缺口：

- publication/subscription 创建、订阅、变更、中文库表、异常路径没有 nightly/motr 稳定覆盖。

建议：

- 作为 P0 补到 motr，单独建 publication/subscription suite 或放到 cross-dimension/issue regression 中。

### 4.3 扩展与可编程能力

BVT 已覆盖内容：

- `procedure/procedure.sql`
- `procedure/starlark.sql`
- `procedure/starlark_llm.sql`
- `procedure/starlark_sql.sql`
- `udf/udf.sql`
- `plugin/plugin.sql`

现有其他回归覆盖情况：

- 未看到明确 procedure/UDF/plugin 专项。

缺口：

- 存储过程创建/执行、Starlark 调用、UDF、plugin 加载与清理缺少稳定回归。

建议：

- 抽最小可稳定运行 case 补入 motr。
- 如果 `starlark_llm` 依赖外部服务，需要拆分为可 nightly 稳定执行和需手工/环境依赖两类。

### 4.4 权限、安全与账号访问控制

BVT 已覆盖内容：

- `tenant`：37 个 `.sql/.test`
- `zz_accesscontrol`：29 个 `.sql/.test`
- `security/password.sql`
- `sql_inject/sql_inject.test`

现有其他回归覆盖情况：

- motr `08_multitenant_rbac` 覆盖多租户/RBAC。
- snapshot/PITR 中有多账号恢复链路。

缺口：

- BVT 中 access control 面比 motr RBAC 更宽，包括 ip whitelist、account restricted、grant truncate、alter/drop account/user/role 等。
- password 和 SQL injection 没有看到明确专项。

建议：

- 先把 `zz_accesscontrol` 和 motr `08_multitenant_rbac` 做 case diff。
- 优先补：password、SQL inject、ip whitelist、account restricted、grant/truncate。

### 4.5 Stage/外部数据/查询结果落盘

BVT 已覆盖内容：

- `stage/export_format.sql`
- `stage/external_stage.sql`
- `stage/external_stage_columns.sql`
- `stage/remove_stage_files.sql`
- `stage/writable_external_table.sql`
- `stage/writable_external_csv_options.sql`
- `save_query_result/save_query_result.sql`
- `sql_source_type/sql_source_type.sql`

现有其他回归覆盖情况：

- big-data 覆盖 parquet export stage。
- motr `11_load_export` 覆盖部分 load/export。

缺口：

- external stage、writable external table、remove stage files、save query result、SQL source type 没有看到完整专项覆盖。

建议：

- 作为 load/export suite 的扩展补入 motr。
- 需要先确认 nightly 环境对象存储权限和路径清理策略。

### 4.6 DDL/对象语义兼容

BVT 已覆盖内容：

- `ddl`, `database`, `table`, `view`
- `sequence`, `foreign_key`, `fake_pk`, `auto_increment`
- `temporary`, `comment`, `keyword`, `replace_statement`, `set`, `sample`

现有其他回归覆盖情况：

- motr `09_ddl_schema` 覆盖 DDL/schema。
- big-data 有 DDL/DML 大表场景。
- TPCC/sysbench 间接覆盖 table/index/auto_increment。

缺口：

- 当前回归对 DDL/对象能力是“大场景覆盖 + 部分 motr”，不是 BVT 对象语义全集。
- sequence、foreign key、fake pk、temporary、comment、keyword 这些兼容细节仍缺明确专项。

建议：

- 不建议搬运完整 DDL/DML BVT。
- 建议先抽 sequence、foreign key、fake pk、temporary、comment/keyword 的核心 case。

### 4.7 查询语义结构

BVT 已覆盖内容：

- `join`
- `subquery`
- `window`
- `cte`
- `recursive_cte`
- `distinct`
- `union`

现有其他回归覆盖情况：

- TPCH、SSB、big-data 都会覆盖 join/window/聚合类查询。
- motr optimizer 有部分 CTE 和 issue regression。

缺口：

- 这些回归偏性能或 issue 单点，不等价于系统性语义覆盖。
- recursive CTE、subquery、distinct/union 等基础语义建议保留稳定回归。

建议：

- 按语义抽小集合补入 motr optimizer 或 semantic regression。

### 4.8 系统变量、查询元信息与观测

BVT 已覆盖内容：

- `system_variable`
- `statement_query_type`
- `zz_statement_query_type`
- `query_result`
- `result_count`
- `metadata`
- `system`
- `log`
- `task`

现有其他回归覆盖情况：

- motr 有 prepare statement，但 prepare 不等价于 statement/query type。
- 未看到 query result、result count、SQL source type、system variable、metadata/log/task 的明确专项。

缺口：

- query type、query tcp/version、result count、query result cloud、system variable 跨账号等缺少明确回归。

建议：

- 合并成“query metadata / system metadata”小 suite。
- 优先补 `statement_query_type`、`zz_statement_query_type`、`query_result`、`result_count`、`system_variable`。

### 4.9 云侧/集成适配

BVT 已覆盖内容：

- `mo_cloud`
- `dataXtest`
- `tenxcloud_xx`

现有其他回归覆盖情况：

- 未看到明确专项。

缺口：

- cloud information_schema、mo_cloud、DataX、TenxCloud 适配类能力缺少稳定回归。

建议：

- 先确认这些 case 对外部环境的依赖。
- 可稳定执行的 SQL 先补入 motr；依赖外部系统的保留为独立集成回归。

## 5. 已有覆盖比较明确的大模块

下面这些大模块已经有较明确的专项，不建议作为“未覆盖大模块”优先项：

| BVT 大模块 | BVT 目录 | 其他回归覆盖来源 |
| --- | --- | --- |
| 全文检索 | `fulltext` | TKE fulltext、motr `06_fulltext_index`、big-data load fulltext |
| 向量检索 | `vector` | TKE HNSW/IVF、单机 vector、motr `05_vector_index` |
| snapshot/PITR | `snapshot`, `pitr` | snapshot workflow、PITR workflow、motr `04_snapshot_pitr` |
| prepare statement | `prepare` | motr `07_prepare_statement` |
| git4data/data branch | `git4data` | motr `12_git4data`、snapshot data branch |
| load data/load export | `load_data` | TKE/单机 load data、big-data、motr `11_load_export` |
| CDC | BVT 无单独同名大目录，其他回归已有 | TKE T+n CDC、单机 CDC/MySQL CDC、motr `03_cdc` |
| benchmark/performance | `benchmark` | TKE/单机 SSB、TPCH、TPCC、sysbench |

## 6. 建议给领导看的简版

可以概括成下面这句话：

> BVT 里除了现有回归已重点覆盖的 fulltext、vector、snapshot/PITR、prepare、git4data、load data、CDC、性能链路之外，还有几类大模块没有被其他回归完整覆盖：SQL 语义与函数/类型兼容、发布订阅、procedure/UDF/plugin 扩展能力、权限安全细节、stage/外部数据/查询结果落盘、DDL 对象兼容细节、查询语义结构、系统变量/查询元信息/观测、云侧和外部集成适配。建议优先补 publication_subscription、geo、procedure/UDF/plugin、zz_accesscontrol/security/sql_inject、stage/save_query_result、statement_query_type/query_result/system_variable。
