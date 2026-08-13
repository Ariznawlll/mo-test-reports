# MatrixOne 测试模版

这套模版用于为 MatrixOne 新增或变更的 Feature 编写完整测试设计。它只收录用户可用、已经正式宣布支持的产品能力，并要求设计基于最新官方 `main`、正式支持证据、能力不变量和已有回归资产。

## 内容

- [SKILL.md](SKILL.md)：完整测试设计工作流。
- [能力索引](references/capability-index.md)：15 个能力域、44 个正式能力条目。
- [正式支持判定策略](references/formal-support-policy.md)：能力准入、证据优先级和新鲜度审计规则。
- [通用测试维度](references/universal-test-dimensions.md)：正常、边界、异常、事务、并发、恢复、安全、兼容性和清理等维度。
- [跨能力关系](references/interaction-map.md)：Feature 与事务、存储、会话、集群、恢复等能力的交互风险。
- [测试分层规则](references/test-routing.md)：UT、BVT、MOTR、big-data、stability、Chaos、GPU 和 recovery 的选择标准。
- [测试设计模板](references/test-plan-template.md)：输出测试设计时必须使用的章节和内容要求。

## 使用方式

把 `测试模版/` 作为 Codex Skill 使用，或者直接参考 [测试设计模板](references/test-plan-template.md) 编写文档。设计完成后运行：

```bash
python3 测试模版/scripts/validate_test_design.py <design.md>
```

维护正式能力目录后运行：

```bash
python3 测试模版/scripts/audit_capability_catalog.py --repo-root /path/to/matrixone
python3 -m unittest discover -s 测试模版/scripts -p 'test_*.py' -v
```

## Python 工具说明

- `audit_capability_catalog.py`：检查能力条目必需字段、状态、重复 ID 和 `repo:` 路径。
- `validate_test_design.py`：检查测试设计章节、完整 main SHA、支持证据、能力映射、测试分层、不适用理由和敏感凭据。
- `test_audit_capability_catalog.py`：验证能力目录审计器自身行为。
- `test_validate_test_design.py`：验证测试设计校验器自身行为；文件内的假 Token 只用于确认敏感信息检测有效。

## 维护原则

- 代码存在、Parser 可解析、内部 UT 通过，不等于产品正式支持。
- `main` 变化时只审计目标能力相关路径；相关合同变化后再更新能力条目。
- 大数据测试只用于规模阈值、spill、计划切换、低概率竞态、性能或长稳合同。
- Chaos 只用于节点、网络、存储、进程或滚动升级故障属于 Feature 合同的场景。
- 不适用的测试维度必须说明具体原因，不能只写 `N/A`。
