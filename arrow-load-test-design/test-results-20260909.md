# Apache Arrow IPC `LOAD DATA` 阶段测试记录（2026-09-09）

## 结论

**测试不通过。** 研发确认以 Issue comment 的 default-on 描述为验收 Oracle；候选
提交在省略配置时却将 local、S3/stage 和 distributed 三个 admission gate 默认设为
`false`，公开 SQL 因配置关闭而拒绝 Arrow LOAD。候选代码及现有回归测试都明确固化
了该错误默认值。已提交并指派研发的缺陷：
[matrixorigin/matrixone#28517](https://github.com/matrixorigin/matrixone/issues/28517)。

除默认策略外，显式 opt-in 后本地已执行范围通过。研发补充 comment 收紧后新增的
dictionary+compression、零行/空文件、精确 Stream EOS 和显式事务 prior INSERT 用例
也已在最新 main 连续 3/3 通过；versioned-object、确定性 pre-publish/commit-ACK、
物理连接恢复、per-CN 执行证据和 metrics 分层语义仍有缺口，不能把整包 PASS 表述为
这些能力已全覆盖。真实云厂商、精确 Linux 发布物、混合版本、权限与租户隔离、
规模/稳定性、Chaos 也尚未完成。

## 基线与环境

| 项目 | 值 |
|---|---|
| MatrixOne 提交 | `f0c31cd4b830be32442cf329e0a3fb08aa9c16c3` |
| 提交说明 | `feat(load): add bounded Arrow IPC ingestion path (#28145)` |
| 增量复核提交 | 最新 `main@cd04bb4c1af5bc595e2147dc645dfa754f4c395b`（包含上述实现提交） |
| 工作树 | 独立 worktree；基于最新 main 建立 `codex/arrow-load-comment-cases` 本地分支，仅修改两处 Arrow 测试资产；未使用主工作树未提交改动 |
| 平台 | macOS Darwin 23.5.0, arm64 |
| Go | 1.26.5；仓库声明 1.26.4，因此本轮不是 exact-release toolchain 证明 |
| Native 依赖 | 在同一提交执行 CGo/native dependency 构建后运行测试 |
| 集群夹具 | 1-CN/2-CN embedded cluster、真实 MySQL text protocol、本地 MinIO |

## 执行结果

| 分层 | 范围与轮次 | 结果 | 主要证据 |
|---|---|---|---|
| Component/UT | `arrowbridge`、`arrowipc`、`bufferlease`、`external/arrowio` 全包，3 轮 | PASS | File/Stream、类型/字典/NULL、压缩、limits、borrow/materialize、lease、对象 identity、畸形输入 |
| Focused UT | config、mpool、fileservice、external、compile、plan、metric 等 Arrow 相关用例，3 轮 | PASS | fail-closed 配置、planner option、worker gate、serial fallback、fanout、schema drift、条件读、关闭错误、指标注册 |
| Public-path BVT/MOTR | `pkg/tests/arrowload` 整包，3 轮 | PASS，414.376 秒 | 真实 MySQL 协议、类型矩阵、mapping、File/Stream、stage、MinIO、事务/回滚、多 CN、rollout、restart |
| 并发门禁 | 7 个 reservation/lease/account/terminal 并发用例，各 10 轮 | PASS | 并发 retain/release、commit/abort、owner attribution、terminal one-shot |
| generation 门禁 | 失败 generation、旧 record 存活、terminal owner 禁止复活，各 20 轮 | PASS | fresh-generation 与生命周期边界 |
| Race | 上述核心竞态用例，`-race` 1 轮 | PASS | 未报告 data race |
| Fuzz | `FuzzArrowIPCPlanningAndOpenNeverPanicOrLeak`，15 秒 | PASS | 9 个基线种子，21,542 次执行，新增 4 个 interesting inputs，无 panic/leak |
| Comment 增量用例 | dictionary+compression、input boundary/EOS、failed LOAD in explicit transaction，各 3 轮 | PASS | File/Stream × LZ4/ZSTD 字典；schema-only/zero-byte/缺 EOS；COMMIT/ROLLBACK 与双会话可见性 |
| 最新 main 回归 | `pkg/tests/arrowload` 整包 1 轮；`LocalMinIO` 6 个子用例额外 3 轮 | PASS | 完整 BVT 最终 PASS；MinIO 3/3 明确无 SKIP |

上述 PASS 表示对应显式 opt-in 或组件路径本身通过，不代表 Feature 总结论通过。
默认配置 Happy Path 与权威需求不符，因此总判定仍为测试不通过。

## 研发补充 comment 后的增量测试与缺口

根据[研发补充 comment](https://github.com/matrixorigin/matrixone/issues/23684#issuecomment-5597540449)，
本轮在最新 main 重新执行了能够落地的 focused case，并逐项审计现有 Oracle。

| 验收项 | 最新 main 执行结果 | 判定 |
|---|---|---|
| File/Stream × LZ4/ZSTD、dictionary delta、损坏 compression metadata、decoded-size 超限、retained compressed record | 新增 `TestIPCDictionaryCompressionForFileAndStream`，相关 `arrowio` 用例 `-count=3` 全部 PASS | dictionary+compression 组合已覆盖 File/Stream × LZ4/ZSTD，并逐 record 精确比对；Close 后 pending/active=0 |
| schema field/depth/custom metadata、wire/decoded body 限制 | 相关 `arrowio` 用例 `-count=3` 全部 PASS | 只证明现有 N/N+1 等点；尚未逐层补齐 N-1/N/N+1 和 output/statement 双边界 |
| Stream 尾部/截断与 SQL statement rollback | 新增 `InputBoundaryAtomicity/valid_records_missing_stream_eos`，与 reader EOS 用例各 3/3 PASS | 全部 record 合法、仅移除末尾 4-byte EOS 时整句失败且 seed 不变；合法对照随后精确导入两行 |
| schema-only 零行与 zero-byte/no-schema | 新增 `InputBoundaryAtomicity`，File/Stream schema-only 成功 0 行；zero-byte 拒绝且 seed 不变，3/3 PASS | 成对 public-path 边界已覆盖 |
| MinIO direct File/Stream、stage、多对象 rollback、ETag 替换、cancel | `TestArrowLoadBVT/LocalMinIO` 3/3 PASS，输出明确无 `SKIP` | 无 versioning 的同 key 替换已覆盖；versioned v1/v2/delete-v1 尚缺 |
| SDK conditional request 与 zero-copy/COW/lifetime | fileservice/arrowbridge/vector focused case `-count=3` PASS | 组件路径通过；跨 next batch/Reset/Free 的完整 owner 状态序列仍缺 |
| post-admission/pre-publish shutdown | 现有 rollout 会在 shutdown 期间释放 publish barrier，并允许重启后 0 或全量 | **Oracle 不合格**；comment 要求 barrier 持至 termination 且重启后只能 0 行 |
| 2-CN fanout | 现有 public test 只校验 count/distinct/id range | **证据不足**；未证明每个 CN 实际执行，也未覆盖 late remote-shard failure |
| transaction 分阶段 | 新增 `FailedLoadInsideExplicitTransaction`，COMMIT/ROLLBACK 两分支 3/3 PASS；commit-success restart 已通过 | failed LOAD 仅回滚当前 statement，prior INSERT 的本/他会话可见性及最终提交/回滚精确符合预期；commit-ACK 不确定点仍缺 |
| cancel/恢复 | 现有 `sql.DB` 后续成功及 reader cleanup 通过 | 不能证明原物理连接复用；固定 `sql.Conn`/`connection_id()`、KILL QUERY、disconnect 缺失 |
| rows/batches/errors metrics | 成功 reader publish 与 error category UT 通过 | rows/batches 是 pre-commit reader publish 计数；缺 late-fail/rollback 语义 case，errors 不覆盖所有 gate/planner/commit 错误 |
| 独立生产者 fixture | 当前 fixture 由 Arrow Go 生成 | **缺失**：需新增并记录 PyArrow 版本的 File/Stream |

因此这次增量测试关闭了四项明确缺口，但不能外推为“其余全部没问题”：已执行
focused case 和完整 `arrowload` suite 没发现新的产品断言失败，研发列出的其余关键
Oracle 仍有部分覆盖或没有资产。

## 已确认缺陷：省略配置时 Arrow LOAD 被关闭

- 预期：按研发确认的 Issue comment，省略 Arrow 配置时 local File/Stream、
  S3/stage 和 distributed 路径默认可用；显式开关仅用于回滚关闭。
- 实际：`FrontendParameters.SetDefaultValues()` 后 `Enabled`、`S3Enabled`、
  `DistributedEnabled` 均为 `false`；无配置的公开 SQL 在读取输入前返回
  `disabled by configuration`。
- 稳定性：无配置拒绝路径随 public-path suite 连续执行 3/3；目标表始终为 0 行。
- 正常对照：显式打开对应 gate 后，local、MinIO/stage 和 2-CN distributed
  public-path suite 连续执行 3/3 并完成完整数据校验。
- 回归资产问题：`TestArrowLoadDefaultsAndProgrammaticOptIn`、
  `TestLaunchTAEComposeProfileKeepsArrowLoadFailClosed` 和 gate-disabled BVT 正在断言
  default-off，需随实现修复同步改成 default-on 正向 baseline，并保留显式 false
  的回滚拒绝用例。

`-race` 首次把两个大型包并行链接时因测试机临时磁盘峰值不足而 build failed
（`errno=28`），这不是产品断言失败。保留小包通过结果后，将 `external` 与
`compile` 串行重跑，二者均通过且未报告 race。此前为解决同一磁盘不足曾清理可再生
Go build cache（约 12 GiB）；本轮又先清理 7.3 GiB。本轮完整回归首次执行时，本地
MinIO 明确返回 `minimum free drive threshold`，该轮判为无效环境失败。生成独立测试
二进制并再次清理已重建的 3.6 GiB cache 后，将测试临时目录放入隔离的稀疏 APFS
测试卷：同一 MinIO 控制用例通过，全部 6 个 MinIO 子用例连续 3/3 通过，随后
`pkg/tests/arrowload` 整包通过。未删除工作区或用户源文件，也未将该环境错误误报为
产品 bug。

## 已验证的设计矩阵

### 正常与边界路径

- File 与 Stream container；LZ4/ZSTD IPC body；多 record batch、EOS、dictionary
  replay/delta、切片 offset、NULL bitmap、长 binary。
- 数值、decimal、bool、timestamp/time、字符串/binary、dictionary index 宽度及非法
  index；按名称和显式列顺序 mapping。
- 本地文件、local stage、direct MinIO File/Stream、S3-backed stage、多对象成功导入。
- 2-CN record-batch fanout，校验总行数、去重行数和完整值域；distributed gate 关闭时
  验证安全串行 fallback。

### 异常、事务与恢复路径

- 未知/冲突 option、unsupported container/DDL surface、格式错误、schema mismatch、
  NOT NULL/约束失败、损坏 IPC、超限 metadata/body/schema。
- schema-only File/Stream 成功 0 行；zero-byte/no-schema 拒绝；全部 record 合法但仅缺
  Stream EOS 时整句回滚，正常对照随后成功。
- 多对象中后续对象损坏、对象在条件读取前被替换、读取取消；均验证 statement 不发布
  部分 Arrow rows，并用后续成功语句证明连接/reader 可复用。
- 显式事务可见性、两会话隔离、commit 前故障注入回滚、与逐行 `INSERT` 对账；
  `BEGIN → prior INSERT → failed LOAD` 的 COMMIT/ROLLBACK 两分支均验证 failed LOAD
  只回滚当前 statement，不错误终止或提交外层事务。
- 现有 rollout 测试只验证集群关闭期间已 admission 的 LOAD 最终为全成或全败，并验证
  gate 关闭重启及串行 roll-forward；该用例未满足 comment 对已知 pre-publish 终止后
  **必须零行**的更严格 Oracle，不能记为该项完成。
- commit 后重启读取持久数据；默认 local/S3 gate 均在 I/O 前 fail closed。

### 资源与可观测性

- buffer/range/capacity lease 的 retain/release、强制释放、晚到释放、failed-generation
  生命周期和 allocation terminal one-shot。
- 读取/转换/commit/cancel 错误路径的 Close 与 allocation account 清理；Arrow 指标注册
  和成功 reader publish 增量。尚未用 late failure 证明 rows/batches 与 committed rows
  分离，也未按 reader/planner/gate/commit 分层验证 errors。
- 畸形 IPC 的 fuzz 路径没有 panic 或测试可见泄漏。

## 未完成项与 blocker

| 项目 | 状态与原因 |
|---|---|
| Default policy | FAIL：研发确认 Issue comment 的 default-on 为准；候选实现及当前回归资产却是 fail-closed |
| `mo-tester` SQL BVT | 本轮未跑共享 compose 脚本；其现有资产只覆盖 default gate reject，不能替代已通过的 opt-in public-path Go suite，也仍应进入正式 CI |
| 权限/租户隔离 | 未执行 `SEC-01..04` 的 GRANT/REVOKE、跨租户 stage/object、审计脱敏 |
| 真实 provider | 未执行 AWS S3、OSS、COS；MinIO 仅证明 S3-compatible integration |
| 混合版本/发布物 | 未执行 exact-release Linux artifact、MORPC v56/v57 混部及升级顺序 |
| 故障注入 | 缺少 2-CN post-admission deterministic worker-loss；不能用 sleep/processlist 猜测替代 |
| Object versioning | 缺少 MinIO versioning 下计划 v1、写 v2 保留 v1、删除计划 v1 的确定性三段用例 |
| Transaction stage | prior INSERT + failed LOAD 的 statement/transaction 边界已补并通过；现有 rollout Oracle 仍过宽，commit-ACK 不确定点仍缺 |
| 连接恢复 | 缺固定物理连接的 context cancel、server KILL QUERY 与 socket disconnect 分类验证 |
| 分布式证据 | 现有 2-CN 仅查聚合行数/范围，缺 per-CN shard 参与和 late remote-shard rollback |
| Metrics | 缺 reader publish 后 late failure/rollback 与非 reader-layer error 的增量语义测试 |
| 独立 fixture | 缺记录 PyArrow 版本的独立 File/Stream 生产者资产 |
| 规模/稳定性/Chaos | 未执行 1/10/100 GiB、宽表、小 batch、压力、长稳、网络/节点故障和 Nightly workflow |
| Owner/CI | capability owner、security、release owner 审批和正式 CI 结果尚缺 |

## 阶段判定

- 本轮实际执行的本地 UT 与 Go public-path BVT/MOTR：通过。
- 普通用例 3 轮、并发 10 轮、generation 20 轮：达到测试设计中的本地重复门禁。
- Feature 总结论：默认配置必需 Happy Path 失败，**测试不通过。**
- Release gate：未达到；默认策略修复并关闭上述 blocker 前不得写“全量通过”或“可发布”。

## 核心复现命令

以下命令均在候选提交的独立 worktree 中执行；本机遗留的错误 `GOROOT` 通过单命令
环境覆盖排除，没有修改用户配置。

```bash
env -u GOROOT make -j8 cgo

env -u GOROOT .agents/skills/mo-dev/scripts/mo-cgo-test \
  -count=3 -timeout=600s \
  ./pkg/container/arrowbridge ./pkg/container/arrowipc \
  ./pkg/container/bufferlease ./pkg/sql/colexec/external/arrowio

env -u GOROOT .agents/skills/mo-dev/scripts/mo-cgo-test \
  -count=3 -timeout=1800s ./pkg/tests/arrowload

env -u GOROOT .agents/skills/mo-dev/scripts/mo-cgo-test \
  -count=3 -run 'TestIPCDictionaryCompressionForFileAndStream' \
  ./pkg/sql/colexec/external/arrowio

env -u GOROOT .agents/skills/mo-dev/scripts/mo-cgo-test \
  -v -count=3 \
  -run 'TestArrowLoadBVT/(InputBoundaryAtomicity|FailedLoadInsideExplicitTransaction)' \
  ./pkg/tests/arrowload

env -u GOROOT .agents/skills/mo-dev/scripts/mo-cgo-test \
  -run '^$' -fuzz '^FuzzArrowIPCPlanningAndOpenNeverPanicOrLeak$' \
  -fuzztime=15s -timeout=120s ./pkg/sql/colexec/external/arrowio
```

Focused、并发和 race 命令通过 `-run` 选择本报告执行结果表中列明的 Arrow、
capacity lease、generation、object identity、planner/compile 和 metric 用例；完整选择
表达式可从测试执行终端记录追溯。
