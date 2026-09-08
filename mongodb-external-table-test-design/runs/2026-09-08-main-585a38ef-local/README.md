# #28333 / #28337 最新 main 本地验证记录

本目录记录 MatrixOne Issue [#28333](https://github.com/matrixorigin/matrixone/issues/28333) 和 [#28337](https://github.com/matrixorigin/matrixone/issues/28337) 在官方 `main` SHA `585a38efd152fadf216c8675b7b997a35ca8deb1` 上的本地复测证据。

## 执行基线

| 项目 | 值 |
|---|---|
| 执行日期 | 2026-09-08 |
| MatrixOne SHA | `585a38efd152fadf216c8675b7b997a35ca8deb1` |
| MatrixOne commit | `fix(mpool): retire realloc address state before physical reuse (#28384)` |
| MatrixOne 二进制 SHA-256 | `9e20c75f522037c7bc08ed0ff0d19ed8b449fdd44dfa553083e018df70ad6bee` |
| MatrixOne 部署 | macOS arm64，本地单进程 1 CN / 1 TN |
| MongoDB | Docker 本地单节点 ReplicaSet，SCRAM-SHA-256 |
| 官方入口 | `optools/mongodb_ci.bash e2e-local`，使用上述精确 SHA 的预构建二进制 |
| 扩展入口 | 同一存活环境执行 [`local_extended_matrix.sh`](local_extended_matrix.sh) |

运行凭据均为临时随机值，未写入本归档。

## 结果

| 套件 | 结果 | 证据 |
|---|---:|---|
| 官方 MongoDB E2E | PASS 26/26 | [`official-report.json`](official-report.json) |
| 扩展交叉矩阵 | 157 PASS / 1 FAIL，共 158 项 | [`local-matrix-summary.json`](local-matrix-summary.json)、[`local-matrix-cases.tsv`](local-matrix-cases.tsv) |
| #28333 黑盒定向 | PASS 12/12 | residual measurement、residual site、projection、order-limit 四种形态各 3/3 |
| #28337 黑盒原问题 | PASS 6/6 | `$sort`、`$unwind` 各 3/3 |
| #28337 邻接边界 | PASS 8/8 | sort 32/33 fields、unwind 199/200 segments、16/17 stages、写阶段、跨 collection |
| #28337 focused UT | PASS | `pkg/sql/mongodb` 4 个相关测试，`-race -count=10` |
| #28333 focused UT | PASS | `pkg/sql/compile` 5 个 residual/projection/plan 测试，`-race -count=10` |

官方 E2E 已包含 `explicit-filter-residual` 和 `explicit-sort-and-unwind-pipeline`。目标用例运行后，普通查询基线仍为 `COUNT=5, SUM(measurement)=74`；10 路并发读取全部返回精确结果；cursor/pool 最终为 `open=135, close=135, checked_out=0`。Mongo 容器最终状态为 `RestartCount=0`、`OOMKilled=false`；MatrixOne 日志未发现 panic、fatal、OOM、越界或段错误。

扩展矩阵唯一失败为无关 Issue [#28341](https://github.com/matrixorigin/matrixone/issues/28341)：strict 转换查询按预期拒绝，但 `conversion_errors_total` 未增长（`before=26, after=26`）。该项不属于 #28333/#28337 的验收路径，不改变这两条 Issue 的通过结论。

## 修复与回归位置

- #28333：修复提交 `34aff8c5e2c8388514a194d5f5d3a5e5110cfe65`（PR #28366），官方 E2E `explicit-filter-residual`，以及 compile 层 residual filter/plan ownership UT。
- #28337：修复提交 `39225f5fbc63b44a190cdd43f954ee07d78e6cdc`（PR #28344），官方 E2E `explicit-sort-and-unwind-pipeline`，以及 user query stage validation UT。

本次验证覆盖功能正确性、非法输入、边界、并发控制和资源清理；big-data、TLS/SRV、多成员故障、Snapshot/PITR、stability/Chaos 不属于这两个缺陷的必要复现路径，仍由 MongoDB External Table 总体验收计划单独执行。
