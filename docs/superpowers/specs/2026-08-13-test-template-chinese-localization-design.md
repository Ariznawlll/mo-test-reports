# MatrixOne 测试模版中文化设计

## 目标

将 `测试模版/` 中面向使用者的内容整理为中文，使中文团队可以直接阅读、维护和执行，同时保持 Codex Skill、能力 ID、脚本入口和测试分层标识兼容。

## 中文化范围

- 中文化 `SKILL.md` 的正文、章节名和操作说明。
- 中文化 README、测试设计模板、支持策略、能力索引、交互关系、测试维度和测试分层文档。
- 中文化 15 个能力域文件中的能力名称、字段名称、范围、限制、不变量和测试建议。
- 中文化两个 Python 工具的命令说明、成功提示和错误提示。
- 中文化两个 Python 测试文件的测试方法名和示例内容中可读文本。

## 保留的技术标识

以下内容保持英文或原始形式，避免破坏工具与引用：

- `mo-feature-test-design`、Python 文件名和命令参数。
- `capability_id` 及其值。
- `supported`、`supported-with-conditions` 等机器状态值。
- UT、BVT、MOTR、big-data、stability、Chaos、GPU、PITR、Snapshot。
- SQL、API、Driver、协议名、代码路径、SHA 和 URL。
- `SKILL.md` frontmatter 的 `name`；`description` 改为中文触发条件。

## 能力字段映射

能力目录使用以下中文字段：

| 英文字段 | 中文字段 |
|---|---|
| Status | 支持状态 |
| User entry | 用户入口 |
| Support evidence | 支持证据 |
| Scope | 支持范围 |
| Limitations | 限制条件 |
| State and invariants | 状态与不变量 |
| Test routing | 测试分层 |
| Repository evidence | 仓库证据 |
| Interactions | 关联能力 |
| Coverage gaps | 覆盖缺口 |

审计器同时接受中文字段和旧英文字段，保证历史条目或渐进迁移不会失效；新目录统一输出中文字段。

## 工具行为

- `audit_capability_catalog.py` 的规则不变，只增加中英文字段别名和中文用户提示。
- `validate_test_design.py` 的结构规则不变，错误与成功提示改为中文。
- 自动化测试必须先证明当前实现不能识别中文字段或输出中文提示，再修改实现使测试通过。
- 密钥检测规则和测试中的假 Token 保持有效，假 Token 不改成真实凭据。

## 验收标准

1. `测试模版/` 面向读者的说明以中文为主，不再出现成段英文流程说明。
2. 能力目录的 44 个条目统一使用中文字段，并通过目录审计。
3. 两个 Python 工具的帮助、成功和错误信息均为中文。
4. 中英文字段兼容测试、设计校验测试全部通过。
5. Skill 格式校验通过，目录无未完成占位标记或生成缓存。
6. PR #11 继续只包含测试模版及仓库 README 入口，不引入无关产物。
