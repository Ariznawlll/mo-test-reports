# MatrixOne BVT 与回归覆盖差异分析

分析日期：2026-07-21

## 1. 背景与结论

本次分析目标是梳理 MatrixOne 主库 BVT 中已经沉淀的重要功能模块，并和现有 nightly 回归、专项回归、motr issue 回归做交叉，找出“BVT 里有，但现有回归里没有明确专项覆盖”的模块，供后续补充回归用例时排序。

结论如下：

1. 当前 nightly 回归并不是默认整包跑 BVT。TKE 复用 workflow 支持 `bvt` 参数，但主入口 `nightly-regression-tke-new.yaml` 默认 `Test_list` 中没有 `bvt`。
2. 现有回归主要覆盖性能和专项链路：SSB、TPCH、TPCC、sysbench、load data、CDC、fulltext、vector、snapshot、PITR、big-data、motr issue regression 等。
3. BVT 中仍有一批独立 SQL 功能模块，在现有回归中没有看到明确专项覆盖，建议优先补入 motr 或单独回归入口。
4. 对于 `function`、`dtype`、`operator`、`join`、`subquery`、`window` 等基础 SQL 能力，现有 TPCH/big-data 会间接覆盖一部分，但不能等价于 BVT 细粒度语义覆盖，建议后续抽取核心语义补到 motr。

## 2. 数据来源与统计口径

### 2.1 BVT 来源

BVT 用例来源：

- [matrixorigin/matrixone/test/distributed/cases](https://github.com/matrixorigin/matrixone/tree/main/test/distributed/cases)

统计口径：

- 统计 main 分支 `test/distributed/cases` 下的顶层目录。
- 统计 `.sql`、`.test`、`.result` 文件数量。
- 以 `.sql`/`.test` 数量作为模块用例规模参考。

当前 BVT 顶层模块数：72 个。

当前 BVT `.sql`/`.test` 用例数：1109 个。

### 2.2 motr 来源

motr 用例来源：

- [matrixorigin/motr](https://github.com/matrixorigin/motr)

当前 motr suite 覆盖方向：

| suite | 覆盖方向 | 文件数 |
| --- | --- | ---: |
| `01_transaction` | 事务 | 52 |
| `02_gc_checkpoint_flush` | GC/checkpoint/flush | 70 |
| `03_cdc` | CDC | 41 |
| `04_snapshot_pitr` | snapshot/PITR | 91 |
| `05_vector_index` | vector index | 43 |
| `06_fulltext_index` | fulltext index | 48 |
| `07_prepare_statement` | prepare statement | 77 |
| `08_multitenant_rbac` | 多租户/RBAC | 25 |
| `09_ddl_schema` | DDL/schema | 32 |
| `10_optimizer` | optimizer | 25 |
| `11_load_export` | load/export | 30 |
| `12_git4data` | git4data | 64 |
| `13_cross_dimension` | cross dimension | 7 |
| `14_issue_regression` | issue regression | 81 |
| `concurrency` | 并发冒烟 | 3 |
| `smoke` | 基础冒烟 | 3 |

### 2.3 nightly 回归来源

主要检查以下 workflow：

- TKE 回归：[nightly-regression-tke-new.yaml](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/nightly-regression-tke-new.yaml)
- 单机回归：[branch-nightly-regression-new.yml](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/branch-nightly-regression-new.yml)
- snapshot 回归：[snapshot_backup_restore_main.yml](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/snapshot_backup_restore_main.yml)
- PITR 回归：[pitr-backup-restore-regression-main.yml](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/pitr-backup-restore-regression-main.yml)
- big-data 回归：[big-data-test.yml](https://github.com/matrixorigin/mo-nightly-regression/actions/workflows/big-data-test.yml)

## 3. 现有回归明确覆盖范围

### 3.1 TKE nightly

`nightly-regression-tke-new.yaml` 默认 `Test_list`：

```text
ssb,tpch,loaddata,tpcc,sysbench1000w,concurrent_test,fulltext_index_test,tn_cdc_test,hnsw_index_test,ivf_pre_post_filter,anli_test,motr_test
```

明确覆盖：

- SSB
- TPCH
- load data
- TPCC
- sysbench 1000w
- 并发场景
- fulltext index
- T+n CDC
- HNSW/IVF vector index
- IVF pre/post filter
- Anli/vector 相关场景
- motr

说明：TKE 复用 workflow 的默认值中包含 `bvt`，但主入口默认没有把 `bvt` 传入，因此日常 TKE main nightly 不应视为默认整包跑 BVT。

### 3.2 单机 nightly

`branch-nightly-regression-new.yml` 默认 `Test_list`：

```text
backup,ssb,tpch,loaddata,tpcc,sysbench1000w,scenario_test,vector_sift128,vector_gist960,cdc_test,mysql_cdc_test
```

明确覆盖：

- backup
- SSB
- TPCH
- load data
- TPCC
- sysbench 1000w
- scenario test
- vector sift128/gist960
- MO CDC
- MySQL CDC

### 3.3 snapshot/PITR/big-data

snapshot workflow 明确覆盖：

- sys account / non-sys account restore
- account/database/table snapshot restore
- restore dropped account
- restore cluster
- db/table clone
- data branch 100M

PITR workflow 明确覆盖：

- sys / non-sys PITR restore
- checkpoint dump S3 with PITR data
- restore cluster
- restore database/table
- restore table to new table

big-data workflow 明确覆盖：

- 1Y/10Y load data
- 1Y/10Y insert
- 大表 query：aggregation、math、string、date、regexp、bykey、DDL、DML、bitmap、join、window、replace into CTAS、external hive/parquet、parquet export stage、spill sort hash join、remote var expr、parquet type conversion

## 4. 建议优先补充的 BVT 缺口模块

下面的模块判断标准是：BVT 中已有用例，且在 TKE/单机/snapshot/PITR/big-data/motr 当前默认覆盖中未看到明确同名或等价专项覆盖。

| 优先级 | BVT 模块 | `.sql/.test` 数量 | 代表用例 | 缺口判断 | 建议 |
| --- | --- | ---: | --- | --- | --- |
| P0 | `publication_subscription` | 9 | `pub_sub.sql`, `publish_subscribe.sql`, `pub_sub_chinese_db_table.sql` | 发布订阅是独立功能链路，现有回归未看到明确覆盖 | 建议优先补到 motr，覆盖发布、订阅、中文库表、订阅变更 |
| P0 | `geo` | 24 | `geo_buffer.sql`, `geo_geojson.sql`, `geo_geohash.sql`, `geo_functions_binary.sql` | geospatial 能力在 big-data 函数类中没有专项覆盖 | 建议抽核心构造、IO、GeoJSON、geohash、二元/一元函数补入 motr |
| P0 | `procedure` | 4 | `procedure.sql`, `starlark.sql`, `starlark_llm.sql`, `starlark_sql.sql` | 存储过程/Starlark 未看到 nightly 专项 | 建议补基础创建执行、SQL 调用、异常、权限边界 |
| P0 | `udf` | 1 | `udf.sql` | UDF 未看到明确回归入口 | 建议补最小可用 UDF 回归 |
| P0 | `plugin` | 1 | `plugin.sql` | plugin 未看到明确回归入口 | 建议补 plugin 加载/使用/清理基础链路 |
| P1 | `mo_cloud` | 2 | `information_schema.sql`, `mo_cloud.sql` | cloud 相关 information_schema/系统视图未看到专项 | 建议按云侧兼容能力补冒烟 |
| P1 | `dataXtest` | 1 | `dataXtest01.sql` | DataX 集成类用例未看到 nightly 专项 | 建议确认依赖环境后补入 motr 或独立集成回归 |
| P1 | `stage` | 9 | `external_stage.sql`, `writable_external_table.sql`, `remove_stage_files.sql` | big-data 有 parquet export stage，但 BVT stage/external stage 不算完整覆盖 | 建议补 external stage、writable stage、remove stage files |
| P1 | `save_query_result` | 1 | `save_query_result.sql` | 未看到明确专项 | 建议与 stage/export 类合并成 load/export 扩展回归 |
| P1 | `sql_source_type` | 1 | `sql_source_type.sql` | 未看到明确专项 | 建议与 statement/query metadata 一起补 |
| P1 | `security` | 1 | `password.sql` | motr 有 RBAC，但密码策略未看到明确覆盖 | 建议补账号密码策略基础回归 |
| P1 | `sql_inject` | 1 | `sql_inject.test` | SQL 注入用例未看到明确回归 | 建议单独纳入安全类 issue/motr 回归 |
| P1 | `zz_accesscontrol` | 29 | `alter_account.sql`, `ip_whitelist.sql`, `grant_privs_role.sql` | motr 有 multitenant/RBAC，但 access control BVT 面更宽 | 建议比对 motr `08_multitenant_rbac` 后补缺口，重点看 ip whitelist/account restricted/grant truncate |
| P2 | `plan_cache` | 1 | `plan_cache.test` | 未看到明确专项 | 建议补 plan cache 开关、复用、失效最小链路 |
| P2 | `qexec` | 2 | `group.sql`, `sort_spill.sql` | big-data 有 spill sort/hash join，但 qexec 模块未专项覆盖 | 建议保留 sort spill/group 最小回归 |
| P2 | `query_result` | 2 | `query_result.sql`, `query_result_cloud.sql` | 查询结果观测能力未看到明确专项 | 建议与 metadata 类合并补 |
| P2 | `result_count` | 1 | `result_count.sql` | 未看到明确专项 | 建议与 statement query type 合并补 |
| P2 | `statement_query_type` | 6 | `statement_query_type_*.sql`, `prepare.sql` | prepare 已有 motr，但 statement/query type 未完整覆盖 | 建议补 query type/result count/sql source type 组合 |
| P2 | `zz_statement_query_type` | 9 | `query_tcp.sql`, `query_version.sql`, `sql_source_type.sql` | 未看到完整专项 | 建议和 `statement_query_type` 合并 |
| P2 | `sequence` | 6 | `create_sequence.sql`, `alter_sequence.sql`, `seq_func.sql` | DDL/schema 间接覆盖不足 | 建议补 sequence 创建、修改、nextval/currval |
| P2 | `charset_collation` | 3 | `charset_collation_basic.sql`, `charset_collation_errors.sql` | MySQL 兼容类能力未看到明确回归 | 建议补基础/高级/错误路径 |
| P2 | `pg_cast` | 1 | `cast.sql` | PostgreSQL cast 兼容未看到明确回归 | 建议补兼容语法冒烟 |
| P2 | `array` | 4 | `array.sql`, `array_index.sql`, `array_index_knn.sql` | vector 回归覆盖 ANN，但 array 语义和 array index 未明确覆盖 | 建议补 array 基础语义和 array index |

## 5. 已有专项覆盖较明确的 BVT 模块

下面这些 BVT 模块已有较明确的专项回归或 motr suite 对应，不建议作为第一批缺口：

| BVT 模块 | 覆盖来源 | 说明 |
| --- | --- | --- |
| `fulltext` | TKE fulltext、motr `06_fulltext_index`、big-data load fulltext | 覆盖较明确 |
| `vector` | TKE HNSW/IVF、单机 vector、motr `05_vector_index` | 覆盖较明确 |
| `snapshot` | snapshot workflow、PITR workflow、motr `04_snapshot_pitr` | 覆盖较明确 |
| `pitr` | PITR workflow、motr `04_snapshot_pitr` | 覆盖较明确 |
| `prepare` | motr `07_prepare_statement` | 覆盖较明确 |
| `git4data` | motr `12_git4data`、snapshot data branch | 覆盖较明确 |
| `optimizer` | motr `10_optimizer`、TPCH/SSB 间接覆盖 | 覆盖较明确 |
| `load_data` | TKE/单机 load data、big-data、motr `11_load_export` | 覆盖较明确 |
| `tenant` | motr `08_multitenant_rbac`、snapshot/PITR 多账号恢复 | 覆盖较明确但仍可按权限细节查漏 |
| `pessimistic_transaction` / `optimistic` | motr `01_transaction`、TPCC/sysbench | 覆盖较明确 |

## 6. 间接覆盖但不等价于 BVT 语义覆盖的模块

以下模块在 TPCH、SSB、sysbench、big-data 查询中可能会被间接覆盖，但 nightly 当前更多验证性能/大数据链路，不等价于 BVT 的细粒度语义用例。建议按 issue 历史和风险挑核心用例补入 motr。

| BVT 模块 | `.sql/.test` 数量 | 说明 |
| --- | ---: | --- |
| `function` | 244 | BVT 最大模块，big-data 覆盖 math/string/date/regexp/bitmap，但不覆盖全部函数语义 |
| `dtype` | 47 | 类型转换、边界、错误路径在性能类回归中覆盖有限 |
| `operator` | 21 | 操作符语义覆盖可能分散在查询中 |
| `expression` | 9 | 表达式细节建议抽核心 case |
| `join` | 12 | TPCH/big-data 覆盖 join 性能，但不等于 join 语义全集 |
| `subquery` | 7 | issue regression 有部分子查询问题，但建议保留核心语义 |
| `window` | 10 | big-data 有 window function，但 BVT 语义仍建议抽样 |
| `cte` / `recursive_cte` | 4 | motr optimizer 有 CTE 兼容 case，但 recursive CTE 建议单独确认 |
| `distinct` / `union` | 2 | 查询类基础语义，建议低成本补冒烟 |

## 7. 建议补充顺序

建议分三批补：

### 第一批：独立功能链路，缺口最明显

1. `publication_subscription`
2. `geo`
3. `procedure`
4. `udf`
5. `plugin`
6. `mo_cloud`
7. `dataXtest`

### 第二批：对象存储/导入导出/观测元信息

1. `stage`
2. `save_query_result`
3. `sql_source_type`
4. `query_result`
5. `result_count`
6. `statement_query_type`
7. `zz_statement_query_type`

### 第三批：安全/兼容/基础 SQL 语义

1. `security`
2. `sql_inject`
3. `zz_accesscontrol` 和 motr `08_multitenant_rbac` 做差异补齐
4. `sequence`
5. `charset_collation`
6. `pg_cast`
7. `array`
8. 从 `function`、`dtype`、`operator`、`join`、`subquery`、`window` 中抽核心语义 case

## 8. BVT 顶层模块规模附录

| BVT 模块 | `.sql/.test` 数量 | 初步覆盖判断 |
| --- | ---: | --- |
| `function` | 244 | 间接覆盖，不完整 |
| `snapshot` | 77 | 已有专项 |
| `git4data` | 70 | 已有专项 |
| `ddl` | 56 | motr/大数据间接覆盖 |
| `dml` | 56 | big-data/sysbench/TPCC 间接覆盖 |
| `dtype` | 47 | 间接覆盖，不完整 |
| `pessimistic_transaction` | 47 | 已有专项/间接覆盖 |
| `benchmark` | 39 | 已有性能回归 |
| `tenant` | 37 | 已有专项/间接覆盖 |
| `zz_accesscontrol` | 29 | 部分覆盖，建议查漏 |
| `table` | 27 | DDL/schema 间接覆盖 |
| `geo` | 24 | 缺口 |
| `optimizer` | 24 | 已有专项 |
| `optimistic` | 22 | 已有专项/间接覆盖 |
| `load_data` | 21 | 已有专项 |
| `operator` | 21 | 间接覆盖，不完整 |
| `vector` | 21 | 已有专项 |
| `foreign_key` | 17 | 部分覆盖，建议抽样 |
| `disttae` | 12 | 间接覆盖 |
| `fulltext` | 12 | 已有专项 |
| `join` | 12 | 间接覆盖，不完整 |
| `log` | 12 | 未明确专项 |
| `view` | 10 | DDL/schema 间接覆盖 |
| `window` | 10 | 间接覆盖，不完整 |
| `expression` | 9 | 间接覆盖，不完整 |
| `publication_subscription` | 9 | 缺口 |
| `stage` | 9 | 部分覆盖，建议补 |
| `zz_statement_query_type` | 9 | 缺口 |
| `array` | 4 | 缺口 |
| `procedure` | 4 | 缺口 |
| `util` | 4 | 未明确专项 |
| `charset_collation` | 3 | 缺口 |
| `recursive_cte` | 3 | 部分覆盖，建议确认 |
| `auto_increment` | 2 | sysbench/TPCC 间接覆盖 |
| `database` | 7 | DDL/schema 间接覆盖 |
| `prepare` | 7 | 已有专项 |
| `system_variable` | 7 | 部分覆盖，建议确认 |
| `subquery` | 7 | 间接覆盖，不完整 |
| `feature_limit` | 6 | 未明确专项 |
| `hint` | 6 | optimizer 间接覆盖 |
| `pitr` | 6 | 已有专项 |
| `sequence` | 6 | 缺口 |
| `statement_query_type` | 6 | 缺口 |
| `temporary` | 6 | 部分覆盖 |
| `analyze` | 2 | optimizer/统计信息间接覆盖 |
| `comment` | 2 | 未明确专项 |
| `cte` | 1 | 部分覆盖 |
| `dataXtest` | 1 | 缺口 |
| `distinct` | 1 | 间接覆盖 |
| `fake_pk` | 1 | 部分覆盖，建议抽样 |
| `keyword` | 2 | 未明确专项 |
| `metadata` | 2 | 未明确专项 |
| `mo_cloud` | 2 | 缺口 |
| `plan_cache` | 1 | 缺口 |
| `plugin` | 1 | 缺口 |
| `pg_cast` | 1 | 缺口 |
| `qexec` | 2 | 部分覆盖，建议抽样 |
| `query_result` | 2 | 缺口 |
| `replace_statement` | 2 | big-data/issue regression 间接覆盖 |
| `result_count` | 1 | 缺口 |
| `sample` | 2 | 未明确专项 |
| `save_query_result` | 1 | 缺口 |
| `security` | 1 | 缺口 |
| `set` | 4 | 部分覆盖 |
| `sql_inject` | 1 | 缺口 |
| `sql_source_type` | 1 | 缺口 |
| `system` | 1 | 未明确专项 |
| `task` | 1 | 未明确专项 |
| `tenxcloud_xx` | 2 | 未明确专项 |
| `time_window` | 1 | 未明确专项 |
| `udf` | 1 | 缺口 |
| `union` | 1 | 间接覆盖 |

## 9. 后续动作建议

建议先从 P0/P1 模块中挑选低依赖、可稳定运行的 SQL case 补入 motr。对于依赖外部环境的 `dataXtest`、`mo_cloud`、部分 `stage` case，需要先确认 nightly 环境是否具备依赖，再决定放入 motr 还是独立 workflow。

对于 `function`、`dtype` 这种大模块，不建议一次性搬运 BVT。更合适的方式是先按 issue 历史、MySQL 兼容风险、近半年变更频率抽核心用例，形成小而稳定的 motr semantic regression。
