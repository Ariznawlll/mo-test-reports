# MongoDB External Table 相关 Issue 本地验证

## 基线与环境

| 项目 | 值 |
|---|---|
| 执行日期 | 2026-09-08 |
| MatrixOne SHA | `585a38efd152fadf216c8675b7b997a35ca8deb1` |
| 二进制 SHA-256 | `9e20c75f522037c7bc08ed0ff0d19ed8b449fdd44dfa553083e018df70ad6bee` |
| MatrixOne 部署 | macOS arm64，本地单进程 1 CN / 1 TN / 1 Log |
| MongoDB | 8.0.12 macOS arm64，单节点 ReplicaSet `rs0` |
| MongoDB 连接 | SCRAM-SHA-256、majority、batch rows=2 |

运行期间远端 `main` 前进到 `92a6bceba1ee156b87dc340479aa1cd44fe56a3d`。两个 SHA 之间没有修改 `test/mongodb`、`pkg/sql/mongodb`、`pkg/sql/compile` 或 `mongoscan`；共享 JSON/eval 路径存在修改，因此本记录只对上表精确 SHA 作运行结论。

凭据均为临时随机值，只通过进程环境注入；归档不包含凭据、连接 URI 或原始服务日志。

## 结果摘要

| Issue | 本地结果 | 说明 |
|---|---:|---|
| [#27123](https://github.com/matrixorigin/matrixone/issues/27123) | 33/33 PASS | MongoDB section 省略、显式 `enable=false`、默认 endpoint deny；system 与两个独立 tenant；connection 和 external-table gate |
| [#27536](https://github.com/matrixorigin/matrixone/issues/27536) | 31/31 PASS | filter/pipeline、点路径、列重排、隐藏列、prepared 重绑、危险输入发送前拒绝、redaction、真实 getMore |
| [#27269](https://github.com/matrixorigin/matrixone/issues/27269) | 9/9 PASS | 无 SELECT 的普通表控制和 MongoDB 外表都拒绝；授权后外表返回 5 行，三套独立实例 |
| [#27266](https://github.com/matrixorigin/matrixone/issues/27266) | 外表本体 PASS；VIEW 现象不可归因 MongoDB | 新会话在撤销外表 SELECT 后 3/3 拒绝；撤销 VIEW SELECT 后 MongoDB VIEW 与普通 VIEW 都仍可读，属于通用 VIEW 权限语义/路径 |
| [#28341](https://github.com/matrixorigin/matrixone/issues/28341) | FAIL | 同 SHA 扩展矩阵仍为 strict error 正确返回、metric `26 -> 26` 不增长 |
| [#27068](https://github.com/matrixorigin/matrixone/issues/27068) | 独立 smoke 不满足优化目标 | 结果正确，但 10 倍历史深度 p50 约增长 9.41 倍，计划保持 `Table Scan -> Group`；该 Issue 不是 MongoDB Connector blocker |

## #27123：默认启用与安全默认值

- 完全省略 `[cn.frontend.mongodb]`：system、tenant A、tenant B 的 connection DDL 均因默认 endpoint policy 拒绝，而不是因功能 disabled 拒绝；external-table gate 继续执行到 connection lookup。三类账号各重复 3 次。
- 只配置 `allow-loopback=true`、省略 `enable`：system、tenant A、tenant B 均成功创建 connection 和 external table，连续 3 次返回 `COUNT=5, SUM=74`。
- 显式 `enable=false`：三类账号的 connection DDL 各重复 3 次均返回 disabled；三类账号的 external-table gate 也均返回 disabled。

证据：[`27123-default-deny.tsv`](27123-default-deny.tsv)、[`27123-explicit-disabled.tsv`](27123-explicit-disabled.tsv)、[`27123-omitted-enable.tsv`](27123-omitted-enable.tsv)。

未完成的 release gate：真实 SRV/TLS、多成员 ReplicaSet 广播未允许地址、配置热 reload、embedded 部署黑盒，以及面向用户/运维的正式文档。

## #27536：显式 filter/pipeline

正向覆盖连续执行 3 次：strict filter、filter + MO residual、点路径 `meta.zone`、显式投影 `__mo_query`、`$match/$group/$project` 且列映射重排、`$sort/$limit`。额外验证：

- `SELECT *` 只有 5 个可见列，`DESC` 不包含 `__mo_query`；四行 filter 结果逐行填充同一个 canonical selector。
- 同一 text PREPARE 依次绑定 pipeline、filter、pipeline，结果为 `1 / 4 / 1`，没有跨执行状态污染。当前 `test/mongodb/README.md` 中“prepared 参数 gated”描述已落后于实际行为。
- `$out`、`$lookup`、`$where`、duplicate key、错误大小写 envelope 全部拒绝；MongoDB profiler 的目标 collection find/aggregate 计数在拒绝前后保持 `23 -> 23`。
- 拒绝后普通扫描仍返回 5 行；EXPLAIN 只显示 operation 和 digest；MongoDB profiler 记录 11 次 `getMore`。

证据：[`27536-explicit-query.tsv`](27536-explicit-query.tsv)。

未完成的 acceptance gate：真实 in-flight cancel、`failCommand/getMore` 与网络中断的精确 cursor/lease delta，多 CN plan/protobuf 传播，以及传输 bytes 指标。此前同 SHA 官方 E2E 已验证 raw 5 documents、reducing pipeline 1 document，以及最终 cursor `open=close`、pool checked-out=0。

## #27266 / #27269：权限回归

每轮使用全新的 MO、MongoDB、role、user 和 VIEW，共 3 轮：

- 无 SELECT 时普通表和 MongoDB 外表都拒绝；给角色授予外表 SELECT 后返回 5 行。
- 撤销外表 SELECT 后，新会话 3/3 拒绝，#27266 的外表本体路径和 #27269 均通过。
- 同一旧会话在撤权后仍可执行 direct/prepared 查询，但普通永久表表现完全相同，判定为通用 session privilege snapshot，不是 MongoDB 特有绕过。
- 保留 base-table SELECT、只撤销 VIEW SELECT 后，新会话中 MongoDB VIEW 与普通 VIEW 都仍可读。该对照不能支持“MongoDB 专属回归”结论；若 VIEW 必须独立鉴权，应转普通 VIEW authorization 路径处理。

证据：[`permissions-run1.tsv`](permissions-run1.tsv)、[`permissions-run2.tsv`](permissions-run2.tsv)、[`permissions-run3.tsv`](permissions-run3.tsv)。

## #27068：独立 latest-per-series smoke

固定 256 个 series，历史深度为 64/320/640，总行数为 16,384 / 81,920 / 163,840。每表先预热，再测 3 次中位数：

| 表 | 行数 | 结果 | p50 | Plan |
|---|---:|---|---:|---|
| p64 | 16,384 | `(256, 16128, 4161408)` | 7.708 ms | Table Scan + Group |
| p320 | 81,920 | `(256, 81664, 20938624)` | 36.807 ms | Table Scan + Group |
| p640 | 163,840 | `(256, 163584, 41910144)` | 72.516 ms | Table Scan + Group |

结果正确，但 10 倍历史深度的 p50 比值为 `72.516 / 7.708 = 9.41`，没有出现 per-series early-stop/history skipping。证据：[`27068-latest-series-smoke.tsv`](27068-latest-series-smoke.tsv)。这只是本地 smoke，不能替代 Issue 要求的 1M/5M/10M nightly big-data。

## 历史直接相关 Issue

同 SHA 已执行的 26-case 官方 E2E 和 158-case 扩展矩阵继续覆盖：BSON/MO 数据类型、strict/try_null、NULL/missing、列约束和 DDL residue、只读 DML、永久表/临时表/VIEW/CTAS/分区表/文件外表交叉、事务、并发、多租户、边界与资源清理。由此覆盖 #27257、#27258、#27259、#27279/#27344/#27345/#27346、#27347/#27348/#27353/#27354/#27355、#27411/#27414/#27415/#27417/#27418、#28333、#28337 的主要回归路径。

仍需在 TKE/专项环境完成：TLS/SRV、ReplicaSet election、网络故障、CN crash、Snapshot/PITR、stability/Chaos、big-data，以及 #27094 所要求的稳定 PR E2E builder/gate。
