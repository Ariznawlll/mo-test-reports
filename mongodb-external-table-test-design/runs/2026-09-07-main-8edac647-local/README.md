# MongoDB External Table 本地回归记录

本目录保存 Issue [matrixorigin/matrixone#26229](https://github.com/matrixorigin/matrixone/issues/26229) 在最新官方 `main` 上的一轮本地回归证据。该结果仅代表本目录列出的本地执行范围，不替代 TKE、NESR cutover、big-data、recovery、stability 或 Chaos 验收。

## 执行基线

| 项目 | 值 |
|---|---|
| 执行日期 | 2026-09-07 |
| MatrixOne 分支 | `main` |
| MatrixOne SHA | `8edac64737db2633c250a527cffdf04707cd8c21` |
| MatrixOne 部署 | macOS 本地单进程集群 |
| MongoDB | 8.0.12，单节点 ReplicaSet，SCRAM-SHA-256，majority read concern，只读测试用户 |
| E2E 入口 | `env -u GOROOT make test-mongodb-e2e-local` |
| Unit/CGO 入口 | `.agents/skills/mo-dev/scripts/mo-cgo-test` |
| Issue 评论 | [阶段性本地复测记录](https://github.com/matrixorigin/matrixone/issues/26229#issuecomment-5569740993) |

测试入口为每轮 E2E 分配随机端口和临时 Secret；本目录未保存 URI、账号、密码、证书、容器日志或其他敏感运行时数据。

## E2E 结果

`make test-mongodb-e2e-local` 独立执行 3 次，每轮均退出 0、`status=passed`、24 个场景。每轮的结构化结果分别保存在：

- [`ci_20260907T104050Z/report.json`](ci_20260907T104050Z/report.json)
- [`ci_20260907T104314Z/report.json`](ci_20260907T104314Z/report.json)
- [`ci_20260907T104450Z/report.json`](ci_20260907T104450Z/report.json)

三份 runner 原始报告内容一致，SHA-256 均为 `fbe0cd536e6660dad2435084b0d0767dafaf8cb2421a632a99695c841eeb0f43`。仓库归档时统一补充了文件末尾换行，归档文件 SHA-256 均为 `e321988d88503202c4a5a88f0b2f23416618192b284233c1315af3b536d41b10`；详见 [`SHA256SUMS`](SHA256SUMS)。JSON 解析后的结构和值与 runner 原始报告一致。每轮记录的 transfer reduction 为 raw scan 5 documents、reducing pipeline 1 document。

覆盖内容包括：

- Secret-backed DDL、SHOW/EXPLAIN 脱敏和非管理员边界；
- Relaxed Extended JSON、固定 BINARY padding、NULL/缺失字段和严格转换失败；
- projection/filter pushdown、低精度 temporal residual、prepared text/binary reuse；
- 常量 `__mo_query` filter、允许列表 aggregation pipeline、非法查询 fail-closed；
- `INSERT ... SELECT`、TimeWin/GAPFILL、原子聚合/watermark、bounded replay；
- decoded vector budget、multi-batch cancel/recovery、credential rotation、connection disable/enable；
- `TRUNCATE` 只读拒绝以及拒绝后 MongoDB source 保持不变。

## 白盒复核

同一 SHA 上的执行记录：

```text
pkg/sql/mongodb                         count=3: ok
pkg/sql/colexec/mongoscan               count=3: ok
pkg/sql/plan Mongo(DB|Scan)             count=3: ok
pkg/sql/mongodb                         race count=1: ok
pkg/sql/colexec/mongoscan               race count=1: ok
test/mongodb Python fixture/template    11 tests: OK
mapping/DDL rejection focused tests     count=3: ok
```

mapping/DDL focused tests验证缺少必填项、重复/未知 option、非法 namespace/path、`max_parallelism != 1`、非法 conversion、重复 path/conversion、不支持的 scalar type、`SET`、非 NULL `DEFAULT`、`AUTO_INCREMENT` 和 `GENERATED` 均 fail-closed。

首次完整 `make test-mongodb-unit` 在并行链接阶段因本机磁盘空间耗尽失败。清理仅由本轮构建产生的临时文件后，目标包使用仓库 CGO wrapper 串行复跑成功；该失败属于执行环境，不计为 MatrixOne 产品失败。

## 资源清理

三轮 E2E 结束后检查：

```text
temporary Docker containers = 0
temporary Docker volumes    = 0
temporary Docker networks   = 0
temporary mo-service        = 0
temporary credential dirs   = 0
```

## 结论与剩余范围

本轮本地 E2E 和白盒回归没有发现新的产品缺陷。#27346 的 `TRUNCATE` 黑盒回归符合预期；#27347/#27348 当前在 mapping/DDL 白盒路径中拒绝，公开 SQL 黑盒 DDL 仍需单独复测。

以下范围尚未由本目录结果覆盖：完整 24 类型交叉矩阵、TLS/SRV、真实多租户、MongoDB 多成员和网络/getMore 故障、Snapshot/PITR、NESR 四 collection 状态机、客户峰值 big-data、长期稳定性和 Chaos。因此本记录不形成 Issue #26229 的完整通过结论。
