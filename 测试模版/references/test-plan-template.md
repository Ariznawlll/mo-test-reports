# Feature 测试设计模板

使用以下标题和顺序。每个矩阵项包含：用例 ID、能力 ID、不变量、前置状态、输入/操作、预期结果、状态/清理断言、环境和测试层。

## Feature 背景与范围

描述用户问题、正式范围、适用产品形态和明确边界。

## 支持证据与版本基线

- 官方 main：`<40-character SHA>`
- 核验日期：`YYYY-MM-DD`
- 正式支持证据：官方文档/Release/RFC/maintainer URL
- 实现/测试证据：main 入口、BVT/MOTR/UT/workflow 路径
- Freshness：目录 SHA 到当前 SHA 的相关路径变化及处理

## 验收目标与非目标

列出可观察、可判定的目标；非目标必须有产品或范围依据。

## 涉及的 MatrixOne 能力

- capability_id: `domain.capability`
- 关系：primary / required / common / high-risk / conditional
- 选择理由和正式限制

## 架构、入口、数据流与状态对象

记录公开入口、内部依赖、数据流，以及表/Catalog/index/transaction/session/task/object/cache 等状态对象。

## 风险与关键不变量

按 correctness、atomicity、isolation、durability、recovery、cleanup 列出风险和不变量。

## 测试环境、拓扑、配置与数据

记录版本、拓扑、配置、客户端/协议、数据模型、规模、分布、凭据隔离和环境门槛。

## 功能测试矩阵

建立验收目标 → capability_id → 不变量 → 用例 → 测试层的 traceability 表。

## Happy Path

正常入口、主要支持变体、重复执行和恢复后的 control。

## Boundary Path

合法 NULL/empty/min/max/precision/dimension/timezone/identifier/size 等边界。

## Unhappy Path

非法输入、冲突、权限、timeout/cancel/disconnect 和失败后立即状态复核。

## 事务与并发

autocommit/commit/rollback、可见性、锁/冲突/deadlock/retry、DDL/DML 和断连时序。

## 安全与租户隔离

owner/admin/ordinary user、最小权限、越权、跨 account/tenant 和 metadata 可见性。

## 恢复与故障注入

错误恢复、reconnect/restart/resume、checkpoint replay 和合同要求的 node/network/storage failure。

## 性能、规模与稳定性

先证明小数据是否进入相同路径；仅在 threshold/spill/plan switch/generation/soak 合同下设计 big-data/stability。

## 兼容性

引用具体 MySQL/Driver/协议兼容边界，覆盖 metadata、error、timezone、SQL mode 和类型。

## 可观测性与资源清理

EXPLAIN/ANALYZE、log/metric/task progress、panic/OOM/restart，以及 schema/session/lock/file/task/port 清理。

## 回归分层与已有资产

- UT：内部纯逻辑/ownership/fault
- BVT：快速确定性公开 SQL
- MOTR：跨功能或 multi-client/protocol scenario
- big-data/stability/chaos/GPU/recovery：只在合同触发时
- 已有测试路径、拟新增文件、repeat/suite/CI 门禁

## 不适用项及原因

- 示例：Chaos 不适用：该 Feature 不依赖节点、网络或外部服务故障。

## 准入、退出、风险与待确认项

定义环境/依赖准入、通过/失败退出标准、未决产品问题、环境阻塞和剩余风险。

完成后运行：

```bash
python3 scripts/validate_test_design.py <design.md>
```
