# MatrixOne 测试报告

功能测试、性能测试、回归测试的总结文档。

## 报告列表

| 日期 | 报告 | 说明 |
|------|------|------|
| 2026-08-17 | [MongoDB External Table 测试设计](mongodb-external-table-test-design/README.md) | Issue #26229：MongoDB 原生外部表的表类型、列约束、事务、权限、恢复与交叉覆盖矩阵 |
| 2026-08-12 | [Iceberg 外部表功能测试设计](iceberg-external-table-test-design/README.md) | Issue #23359：REST Catalog、跨引擎对账、snapshot/delete/DML、Nessie ref、维护、资源与安全边界 |
| 2026-06-12 | [Checkpoint Dump 工具测试记录](checkpoint-dump-test/checkpoint_dump_test_record_20260612.md) | 基于 129 服务器回归 `mo-data` 的 database 级 dump、restore.sql load、parallel 修复验证和行数校验 |
| 2026-06-11 | [Checkpoint Dump 工具测试方案](checkpoint-dump-test/checkpoint_dump_test_plan.md) | `mo-tool ckp dump` 功能、全表类型、全数据类型、约束、unhappy path、性能、dump + load 正确性、3.0-dev 到 4.0-dev 兼容性测试 |
| 2026-05-15 | [MO TPC-DS 测试](tpcds-test-20260515/README.md) | 11 个 issues 验证，含 TPC-DS 1G 对比、lockservice 稳定性、parquet load、SQL 语义修复 |
| 2026-05-13 | [Hive Partitioned Parquet 外部表](hive-partition-parquet/README.md) | PR #24320 功能/性能/稳定性测试，含 MO vs ClickHouse 对比 |
