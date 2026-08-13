# 能力条目契约

每个 `capability-*.md` 使用二级标题声明稳定 ID，并包含以下字段：

```markdown
## domain.capability-name

- **Status:** supported | supported-with-conditions
- **User entry:** 用户可调用的 SQL/协议/CLI/API/配置
- **Support evidence:** 官方文档、Release/RFC 或明确支持声明
- **Scope:** 已正式支持的范围
- **Limitations:** 条件、限制、兼容差异或“无额外限制”
- **State and invariants:** 数据、元数据、状态和必须保持的不变量
- **Test routing:** UT/BVT/MOTR/scenario/big-data/stability/chaos/GPU/recovery
- **Repository evidence:** `repo:` 路径、测试目录或公开入口代码
- **Interactions:** required/common/high-risk/conditional 能力 ID
- **Coverage gaps:** 当前已知缺口，或“未发现已知缺口”
```

前七个字段由 `audit_capability_catalog.py` 强制检查。Repository evidence 中的 `repo:` 路径在传入 MatrixOne 仓库根目录时必须存在。

## ID 规则

- 只使用小写字母、数字、点和连字符。
- 第一段是稳定能力域，如 `sql`、`transaction`、`vector`。
- ID 表达用户能力，不表达内部包或当前实现类名。
- 已发布 ID 不因代码重构改名；语义拆分时保留旧条目的迁移说明。

## 内容规则

- Scope 描述已支持内容，不复制完整 SQL 语法。
- Limitations 必须写清部署、配置、版本、协议、租户、CPU/GPU 和兼容限制。
- State and invariants 至少包含结果正确性、失败原子性、隔离、恢复或资源清理中相关的合同。
- Happy、Boundary、Unhappy 具体测试从不变量生成，不堆砌无关组合。
- 合法 NULL、空集、最大值等属于 Boundary；只有合同规定非法时才属于 Unhappy。
- Test routing 选择能够证明合同的最低成本层级；规模和故障是触发条件时才升级。

## 变更审计

更新条目时回答：

1. 用户入口是否变化？
2. 正式支持证据是否仍有效？
3. 支持范围或限制是否变化？
4. 数据/状态对象是否变化？
5. 不变量和高风险交互是否变化？
6. 测试资产路径是否仍存在？
7. 是否需要更新验证 main SHA？
