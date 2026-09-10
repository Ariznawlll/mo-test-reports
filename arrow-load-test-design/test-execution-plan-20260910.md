# Arrow IPC LOAD 完整验证执行计划

**目标：** 按 MatrixOne #23684 研发 review comment（5597540449）执行可复现的 Arrow IPC LOAD 验证，并为每项记录实际命令、拓扑、配置、Oracle 和状态；不得将未运行的资产或 CI 视为通过。

**基线：** 官方 `main`；当前交付合同为三个 Arrow gate 默认关闭，显式 opt-in 后允许加载。

## 执行任务

- [ ] **CFG：默认关闭与 opt-in。** 在 1-CN 真实 MySQL 协议上运行同一 File fixture：无配置必须拒绝且目标表零行；显式开启三个 gate 后成功加载，并以行数、ID 范围/总和、NULL、基数 Oracle 断言。每个控制重复 3 次。
- [ ] **TYPE：File/Stream 与压缩/边界。** 执行 `arrowio` UT：File/Stream × LZ4/ZSTD、字典、坏压缩 metadata、decoded body 上限、合法零行/非法零字节、尾部 EOS 损坏、schema/metadata/body/batch/statement capacity N-1/N/N+1；检查失败后 lease/pending/active 清零。
- [ ] **OBJ：本地 MinIO 对象变化。** 验证非 versioning 下 ETag 变化回滚；versioning 下锁定 v1、写入 v2 后仍读 v1 的成功控制；删除 v1 后失败；以及单 Stream GET 已获得 v1 后更新 latest key 的控制。MinIO 缺失必须显式标为环境阻塞，不能以 Skip 计通过。
- [ ] **TXN：提交阶段与事务状态。** 执行已存在的 admission/生命周期故障注入与公开事务 case；分别断言 pre-publish 终止后零新增、确认 commit 后全量、ACK 不确定窗口的全有/全无，以及 `BEGIN → INSERT → failed LOAD` 后的前序写入和 COMMIT/ROLLBACK 语义。
- [ ] **CONN：异常恢复。** 分别覆盖 gate 拒绝、权限拒绝、服务端 KILL QUERY、客户端 context cancel、客户端断连；使用固定连接或 connection ID 断言适用协议合同，并以正确观察会话/重连后的成功控制检查数据和清理。
- [ ] **DIST：双 CN 证据。** 在 2-CN 真实集群执行 PARALLEL File LOAD；检查所有列和每个 shard 的参与 CN/覆盖证据。注入一个进入执行的远端 shard 晚失败，断言所有 shard 回滚。
- [ ] **MEM：零拷贝生命周期。** 执行 retained record 经过 reader Close、下一 batch/Reset/Free、COW、分配失败和最后 owner Release 的 UT；分别断言旧 view/原 backing/capacity，不能只看最终 pinned=0。
- [ ] **OBS：指标口径。** 对成功、reader 晚失败/rollback、gate/planner 拒绝和重启分别采样 rows/batches/errors/lease 指标；按 reader publish 而非 commit 语义比对。
- [ ] **NIGHTLY：100M 固定 COS 回归。** 在已合并的 Big Data asset PR 与 main 调度 PR 均可用后，运行 3-CN Nightly，记录 run URL、实际 CN 数、耗时、峰值资源与完整 Oracle。

## 退出条件

只有所有任务有可检查证据，且普通路径 3/3、并发/竞态路径按场景重复次数满足要求时，才可以在 #23684 发布测试结论。任何环境 Skip、未合并工作流、未运行的 MinIO/TKE 或未验证的断言必须保留为待测项。

## 2026-09-10 本地执行记录（非最终结论）

**被测版本：** `matrixorigin/matrixone` 官方 `main`，commit `269d59addd032d20897cc4d86f58de3e387a6d76`。  
**拓扑：** 独立嵌入式 1-CN / 2-CN 集群；MinIO 用例使用本机已安装的 MinIO 二进制启动，不复用失效的共享 Docker 容器。  
**构建环境：** macOS arm64；为隔离 worktree 构建仓库规定的静态 C 依赖后执行。未在命令、日志或报告中记录对象存储凭据。

| 任务 | 已执行证据 | 状态 | 尚缺的研发要求 |
|---|---|---|---|
| CFG | `TestArrowLoadGateDisabled` 和 `TestArrowLoadGateS3Disabled` 各重复 3 次，均通过；总耗时 68.058s。显式开启路径包含在 BVT 中，BVT 1/1 通过。 | 部分完成 | 显式 opt-in 成功路径尚未按相同 Oracle 重复 3 次。 |
| TYPE | `go test ./pkg/sql/colexec/external/arrowio -count=1 -v` 通过，0.816s；覆盖 File/Stream × LZ4/ZSTD、字典、EOS、解压大小/metadata/body/schema 限制、条件读取、lease/retain 与 fuzz seed。 | 部分完成 | 系统级 File/Stream fixture 和所有 N-1/N/N+1 容量边界尚未逐项形成执行证据。 |
| OBJ | 1-CN BVT 1/1 通过，19.511s，真实本地 MinIO 路径实际执行而非 Skip；底层 conditional identity UT 也通过。 | 部分完成 | 尚未在真实 versioned/non-versioned MinIO 执行 ETag 变化、v1/v2 固定、删除 v1、Stream GET 后更新 key 的四个控制。 |
| TXN | BVT 包含约束/损坏输入回滚、显式事务、双会话隔离、提交阶段注入失败与重试，1/1 通过；rollout/drain 3/3 通过，71.735s。 | 部分完成 | rollout 用例当前接受“原子提交或原子回滚”，不能证明研发要求的 pre-publish 窗口必须零新增；ACK 不确定窗口和 `BEGIN → INSERT → failed LOAD` 的精确语义仍需独立证据。 |
| CONN | gate 拒绝已执行。 | 未完成 | 权限拒绝、服务端 KILL QUERY、客户端 cancel、客户端断连及相应 connection ID/重连控制均未覆盖。 |
| DIST | `TestArrowLoadMultiCN` 在独立 2-CN 集群重复 3 次，全部通过，37.607s；每次检查行数、distinct ID 和 ID 范围。 | 部分完成 | 没有每个 shard 的参与 CN 证据，也没有“远端 shard 已进入执行后晚失败、全部回滚”的用例。 |
| MEM | Arrow I/O 生命周期 UT 1/1 通过；`TestArrowLoadForceMaterializeFallback` 3/3 通过，36.576s，验证 borrow 与强制 materialize 的 payload/copy 指标差异。 | 部分完成 | 仍需把 COW、最后 owner Release 与 allocation 断言整理为研发要求的可审计证据表。 |
| OBS | materialize 用例验证两个 payload/copy counter 的预期增量。 | 未完成 | rows/batches/errors/lease 在 reader publish、rollback、planner/gate 拒绝和重启后的完整口径尚未验证。 |
| NIGHTLY | 固定 100M COS asset 的 Big Data 回归定义已合并；main 调度 PR 仍未合并，未触发 TKE/Nightly。 | 未完成 | 3-CN run URL、实际 CN 数、资源/耗时与完整 Oracle。 |

**本轮结论：** 已执行的本地用例均通过，未发现可复现产品失败；但研发 comment 的 OBJ/CONN/DIST/OBS 等关键验收项尚无完整证据，不能宣布 feature 测试完成或无风险。
