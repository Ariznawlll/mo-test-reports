---
name: mo-feature-test-design
description: 用于设计或评审 MatrixOne 新增、变更 Feature 的测试覆盖，判断 UT、BVT、MOTR、big-data、stability、Chaos、GPU、recovery 分层，分析跨能力风险，或决定是否需要规模与故障注入测试。
---

# MatrixOne Feature 测试设计

## 目标

根据 MatrixOne 正式支持的用户合同、能力不变量、架构交互和已有回归资产，生成有证据支撑的测试设计。能力目录是官方最新 `main` 的持续维护基线，但不能替代对当前文档和代码的核验。

不要从通用测试清单直接开始。先确认产品向用户承诺了什么，再设计能够证明该承诺并保护高风险交互的最小完整测试矩阵。

## 必须读取的资料

生成设计前，按顺序读取：

1. `references/formal-support-policy.md`
2. `references/capability-index.md`
3. 主能力及关联能力对应的 `references/capability-*.md`
4. `references/universal-test-dimensions.md`
5. `references/interaction-map.md`
6. `references/test-routing.md`
7. `references/test-plan-template.md`

新增或维护能力条目时，还必须读取 `references/capability-entry-contract.md`。

## 工作流程

### 1. 明确 Feature 合同

描述公开入口、支持的语法或 API、用户可观察结果、支持的部署形态、配置、生命周期、文档限制和明确的非目标。

使用 `formal-support-policy.md` 中的证据层级。Parser 分支、已合并实现、隐藏配置、内部 UT 或 Issue 评论都不能单独证明产品正式支持。

公开来源存在冲突时采用更窄的合同，并把冲突记录为产品待确认项，不能静默扩大范围。

### 2. 执行新鲜度门禁

获取 MatrixOne 官方 `main` 的完整 SHA，与 `formal-support-policy.md` 和 `capability-index.md` 中的目录 SHA 比较。

- SHA 未变化：正常使用目录。
- SHA 已变化：检查目标能力相关文档、公开入口、实现和测试路径的差异。
- 相关路径已变化：先更新能力条目的支持证据、条件、限制、关联能力、目录 SHA 和日期，再设计测试。
- 只有无关路径变化：在设计中记录审计结论，不改写无关条目。

未核验完整 SHA 时，禁止宣称基于“最新 main”。

### 3. 选择能力

选择一个主 `capability_id`，再展开条目的“关联能力”：

- `必需`：必须纳入。
- `高风险`：除非能证明 Feature 合同无法进入该路径，否则必须纳入。
- `常见`：公开工作流使用时纳入。
- `条件适用`：只有条件成立时纳入。

未选择的常见、高风险或条件适用交互必须记录原因。能力 ID 用于可追溯性；内部组件名只作为架构背景，不直接作为用户验收目标。

### 4. 建立被测系统模型

需要梳理：

- 公开入口及客户端、协议变体；
- 数据流和控制流；
- 行、Catalog、索引、事务、会话、锁、后台任务、Checkpoint、对象、Cache、文件等状态对象；
- CN、TN、Log Service、Proxy、对象存储、Account、Tenant、Role、GPU Worker 等拓扑与所有权边界；
- 同步和异步完成信号。

据此决定哪些结果要在操作后立即检查，哪些要在 commit、轮询、重连、重启或恢复后检查。

### 5. 定义风险与不变量

把用户合同转化为可观察不变量，至少考虑：

- 结果和 metadata 正确性；
- 原子性，以及拒绝后不存在部分修改；
- 事务可见性、隔离、锁释放和重试行为；
- 持久性与恢复；
- Tenant 和权限隔离；
- 稳定的错误分类及错误后的复用能力；
- 资源、任务、会话、Schema、锁、文件和端口清理；
- 不同合法执行计划的结果等价性；
- 只在 MatrixOne 正式兼容范围内验证兼容行为。

每个重要不变量必须映射到至少一个用例和明确的判定依据。

### 6. 构建功能测试矩阵

按相关性应用 `universal-test-dimensions.md`，不要机械全排列：

- 正常路径证明每个正式入口和有意义的变体。
- 边界路径覆盖 NULL、空值、精度、维度、时区、标识符、批次边界等合法极限。
- 异常路径覆盖非法输入、冲突、权限、取消、断连、超时和失败原子性。
- 生命周期覆盖适用的 create、use、alter、rebuild、drop、recreate、repeat、reconnect 和 cleanup。
- 修改状态或触发错误后要立即检查，不能先执行成功操作掩盖损坏。

使用字面期望结果或独立 Oracle。“没有 panic”或“查询成功”本身不能证明结果正确。

### 7. 决定规模、并发与故障覆盖

不能因为“数据更多看起来更强”就增加 big-data。只有合同或缺陷依赖以下条件时才需要：

- 跨越内存、磁盘、Batch、Partition、Block、Object 或 Admission 阈值；
- 触发 spill 或外部执行；
- 优化器计划或物理算法只在特定规模下切换；
- 通过多次 fresh generation 暴露低概率竞态；
- 验证吞吐、时延、资源上限或长时间稳定性。

如果能通过正式配置让小数据进入完全相同路径，则把小而确定的用例放入普通回归，生产规模验证保留在 Nightly。

锁、可见性、Cache 失效、路由、会话迁移或分布式所有权相关能力需要多客户端或多 CN。只有节点、网络、存储、进程或滚动升级故障属于合同，才使用 Chaos。GPU 只用于正式支持的 GPU 路径。每个专用环境门禁都要说明原因。

### 8. 选择正确测试层

按照 `test-routing.md`：

- UT：内部纯逻辑、所有权、错误映射和确定性故障注入。
- BVT：快速、确定性的公开 SQL 和 metadata 合同。
- MOTR：黑盒协议、多会话、生命周期、跨 Feature 或依赖环境的场景。
- big-data/Nightly：规模阈值、spill、计划切换、性能、长稳和低概率 generation。
- stability、Chaos、recovery、GPU：各自明确的环境合同。

优先扩展已有权威测试。除非新测试层证明不同合同，否则不要在新 PR 中重复稳定回归。

### 9. 定义执行与证据

每个用例都要说明前置条件、操作、Oracle、即时状态断言、清理、重复次数、超时和环境。异步能力使用产品可观察的就绪信号进行有界轮询；固定 sleep 不能证明已经就绪。

必须区分：

- 产品测试结果；
- 夹具或环境失败；
- Suite 中的无关失败；
- 尚未测试的条件。

不能把部分覆盖写成完整通过。

### 10. 编写并校验设计

严格按照 `references/test-plan-template.md` 的标题和顺序编写。每个“不适用”项都要给出具体原因。必须包含官方 `main` 完整 SHA、正式支持 URL、能力 ID、回归分层、已有资产路径、准入和退出条件、剩余风险及产品待确认项。

运行：

```bash
python3 scripts/validate_test_design.py <design.md>
```

修复全部错误后才能交付。

## 能力目录维护

正式宣布的能力新增、变更、受限、废弃或移除时：

1. 按 `capability-entry-contract.md` 更新对应能力域文件。
2. 更新跨能力关系和已有测试资产。
3. 审计受影响路径后，更新目录 SHA 和核验日期。
4. 运行：

```bash
python3 scripts/audit_capability_catalog.py --repo-root /path/to/matrixone
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

当前正式能力索引不得保留 unsupported、preview、internal、debug-only、deprecated 或 removed 行为。历史或版本限定信息只能作为明确条件或维护记录保留。

## 交付检查

宣布测试设计完成前确认：

- 已记录正式支持证据和当前官方 `main` 完整 SHA；
- 主能力和关联能力 ID 可追溯；
- 每个验收目标都映射到不变量、用例、Oracle 和测试层；
- 正常、边界和异常路径都有实质覆盖；
- 事务、并发、安全、恢复、规模、兼容性和可观测性已覆盖，或明确说明不适用原因；
- big-data 和 Chaos 选择有具体触发条件；
- 已列出现有测试和覆盖缺口；
- 清理与失败后状态检查明确；
- 测试设计校验器通过，且文档不含凭据。
