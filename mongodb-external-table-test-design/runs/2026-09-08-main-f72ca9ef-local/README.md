# MongoDB External Table 本地扩展交叉测试记录

本目录记录 Issue [matrixorigin/matrixone#26229](https://github.com/matrixorigin/matrixone/issues/26229) 在官方 `main` SHA `f72ca9efbeb3a7c673701e4a135cc6670c33cfde` 上的本地测试证据。结果包含官方 E2E 和针对表类型、列约束、数据类型、Happy/Unhappy、事务、并发、租户及可观测性的扩展矩阵，不替代 big-data、TLS/SRV、分布式故障、Snapshot/PITR、stability 或 Chaos 验收。

## 执行基线

| 项目 | 值 |
|---|---|
| 执行日期 | 2026-09-08 |
| MatrixOne SHA | `f72ca9efbeb3a7c673701e4a135cc6670c33cfde` |
| MatrixOne 二进制 SHA-256 | `9a1c4f6edd99fef19186141c9e9606e08072fdcd6174e38244ca7c7bb8735847` |
| MatrixOne 部署 | macOS arm64，本地单进程 1 CN / 1 TN |
| MongoDB | 8.0.12，单节点 ReplicaSet，SCRAM-SHA-256，majority read concern |
| Go | 1.26.5 |
| 官方入口 | `optools/mongodb_ci.bash e2e-local` |
| 扩展入口 | 同一存活集群内执行 [`local_extended_matrix.sh`](local_extended_matrix.sh) |

所有 MongoDB、system account 和 tenant 凭证均在运行时随机生成或通过 account-scoped secret reference 注入，未写入归档。归档前对 `MO_MONGODB_ACCOUNT_*_E2E_CREDENTIAL=`、明文 `Password` JSON 和带 userinfo 的 Mongo URI 扫描，命中文件数均为 0。

## 结果总览

| 套件 | 结果 | 说明 |
|---|---:|---|
| 官方 MongoDB E2E | PASS 25/25 | [`official-report.json`](official-report.json) |
| 扩展交叉矩阵 | 145 PASS / 13 FAIL，共 158 项 | [`local-matrix-summary.json`](local-matrix-summary.json)、[`local-matrix-cases.tsv`](local-matrix-cases.tsv) |
| `pkg/sql/mongodb -race` | PASS 10/10 | 串行、`-vet=off`、同一 SHA |
| `pkg/sql/colexec/mongoscan -race` | PASS 10/10 | 串行、`-vet=off`、同一 SHA |
| `pkg/sql/colexec/aggexec -race` | PASS 10/10 | 串行、`-vet=off`、同一 SHA |
| `pkg/sql/colexec/timewin -race` | PASS 10/10 | 串行、`-vet=off`、同一 SHA |
| 官方 unit 相关包 | PASS | Python 11/11；`mongodb`、`mongoscan`、`aggexec`、`timewin`、MySQL parser、`plan`、`compile`、`frontend` 均通过 |

扩展矩阵通过项覆盖：

- 当前 converter 支持的 BOOL、全部有/无符号整数、FLOAT/DOUBLE、DECIMAL64/128/256、DATE/DATETIME/TIMESTAMP、CHAR/VARCHAR/TEXT、BINARY/VARBINARY/BLOB、ObjectID 两种映射及 JSON 文档/数组/BSON wrapper；
- missing/null/undefined、strict/try_null、nested path、大小写、Unicode 宽度、标量溢出和不支持类型；
- source NULL/NOT NULL/DEFAULT、PK/UNIQUE/index/CHECK/AUTO_INCREMENT/generated/FK 禁止项、只读 DML/ALTER/TRUNCATE 和 catalog 无残留；
- 永久表、临时表及会话隔离、分区目标、View、CTAS、cluster table 权限边界、file external Join；
- 普通目标表 DEFAULT/AUTO_INCREMENT/generated/index/CLUSTER BY、PK/UNIQUE/FK/CHECK/NOT NULL 原子回滚和 REPLACE；
- CTE/subquery/UNION/GROUP/WINDOW、pipeline 64 KiB/深度/stage/sort/unwind 边界、显式事务 commit/rollback、10 路并发读取；
- system + tenant A/B 的 account-scoped secret、同名 connection/table、扫描和 catalog 隔离；
- try_null 转换指标及 cursor/pool 清理，最终 `open=134`、`close=134`、`checked_out=0`。

## 失败项归因

13 个失败均为已登记问题，没有发现第三类新缺陷：

1. [matrixorigin/matrixone#28333](https://github.com/matrixorigin/matrixone/issues/28333)：显式 filter 与普通 residual/projection/order-limit 组合的 4 种查询形态，各稳定复现 3/3，共 12 项。错误为 `ColumnExpressionExecutor.Eval` 在 `pkg/sql/colexec/evalExpression.go:1685` 越界 panic。
2. [matrixorigin/matrixone#28341](https://github.com/matrixorigin/matrixone/issues/28341)：strict 转换查询按预期失败，但 `conversion_errors_total` 仍为 `before=26, after=26`，共 1 项。

[matrixorigin/matrixone#28337](https://github.com/matrixorigin/matrixone/issues/28337) 的 `$sort` 和 `$unwind` 在当前 main 各 3/3 通过；32/33 sort fields、199/200 unwind path segments、16/17 stages 的边界也符合预期。

## 环境事件与清理

首次源码并行构建以及一次 `mongoscan -race` 编译曾因宿主磁盘空间耗尽失败，均未进入产品测试；清理本轮 Go cache 后，以串行低峰值方式复跑通过。另一次 E2E 启动被同机其它任务抢占端口，日志明确为 `bind: address already in use`；改用核验空闲的独立端口块后完整执行。本目录不把这些环境事件计为产品失败。

最终检查确认本轮 Compose container、volume、network、MO 进程、临时 credential 目录均无残留。宿主仍有测试开始前已经存在的 `mo-mongodb-local-data` volume 和 `mo-mongodb-test-net` network，本轮未删除或修改。

## 仍需非本地环境覆盖

- 千万级/宽行/高基数 big-data，以及长期 cursor、资源趋势和性能阈值；
- TLS 私有 CA、SRV/TXT、mongos、多成员 ReplicaSet 和各 read preference/read concern；
- find/getMore 网络断流、primary failover、CN/TN 故障注入和 commit-ack 不确定；
- Snapshot/PITR/backup restore、stability/Chaos；
- NESR 四 collection、客户规模和正式 cutover gate。

因此，本轮结论是“本地可执行范围已完成，并稳定暴露两个既有问题”，不是 Issue #26229 的完整发布验收通过。
