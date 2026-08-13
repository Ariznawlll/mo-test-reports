# MatrixOne 测试模版中文化实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 `测试模版/` 的面向用户内容完整中文化，同时保持 Skill、能力 ID、脚本入口和旧英文字段兼容。

**Architecture:** 文档层统一使用中文字段和中文说明；自动化层以字段别名映射兼容中英文目录，并用中文输出用户提示。通过测试先定义中文契约，再批量迁移 44 个能力条目并运行全量审计。

**Tech Stack:** Markdown、Python 3 标准库、`unittest`、Codex Skill validator、Git/GitHub PR。

## Global Constraints

- `capability_id`、Python 文件名、命令参数、SHA、URL 和测试层技术标识保持原样。
- 目录新内容统一使用中文字段，审计器继续接受旧英文字段。
- 不修改 MatrixOne 产品代码，不引入第三方依赖。
- 不写入真实 Token、密码、AK/SK 或其他凭据。

---

### Task 1: 中文审计契约

**Files:**
- Modify: `测试模版/scripts/test_audit_capability_catalog.py`
- Modify: `测试模版/scripts/test_validate_test_design.py`
- Modify: `测试模版/scripts/audit_capability_catalog.py`
- Modify: `测试模版/scripts/validate_test_design.py`

**Interfaces:**
- Consumes: 现有 `audit_catalog(skill_dir, repo_root)` 和 `validate_design(text)`。
- Produces: 中英文字段别名、中文 CLI 提示、保持不变的返回值接口。

- [ ] **Step 1: 编写失败测试**

新增中文能力字段通过、旧英文字段继续通过、两个 CLI 成功/错误提示为中文的测试。

- [ ] **Step 2: 验证测试按预期失败**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s 测试模版/scripts -p 'test_*.py' -v`

Expected: 中文字段或中文提示断言失败，原 13 项测试保持现状。

- [ ] **Step 3: 实现最小兼容层**

在目录审计器中增加英文字段到中文规范字段的别名映射；将两个 CLI 的帮助、成功和错误信息改为中文，不改变 Python 函数签名。

- [ ] **Step 4: 验证测试通过**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s 测试模版/scripts -p 'test_*.py' -v`

Expected: 全部通过。

- [ ] **Step 5: 提交**

```bash
git add 测试模版/scripts
git commit -m "feat: localize test template validators"
```

### Task 2: 中文化能力目录与参考文档

**Files:**
- Modify: `测试模版/references/*.md`

**Interfaces:**
- Consumes: Task 1 的中英文字段兼容审计器。
- Produces: 使用中文字段的 44 个正式能力条目和中文参考资料。

- [ ] **Step 1: 批量迁移字段名**

将 Status、User entry、Support evidence、Scope、Limitations、State and invariants、Test routing、Repository evidence、Interactions、Coverage gaps 按规格映射为中文。

- [ ] **Step 2: 中文化残留说明**

翻译成段英文支持证据说明、标题和维护说明；正式产品名、SQL、路径与链接保持原样。

- [ ] **Step 3: 运行目录审计**

Run: `PYTHONDONTWRITEBYTECODE=1 python3 测试模版/scripts/audit_capability_catalog.py --repo-root /Users/ariznawl/weilu/matrixone`

Expected: `通过：能力目录契约校验成功`。

- [ ] **Step 4: 提交**

```bash
git add 测试模版/references
git commit -m "docs: localize MatrixOne capability catalog"
```

### Task 3: 中文化 Skill 与入口文档

**Files:**
- Modify: `测试模版/SKILL.md`
- Modify: `测试模版/README.md`
- Modify: `测试模版/agents/openai.yaml`

**Interfaces:**
- Consumes: 中文能力目录、中文测试设计模板与分层规则。
- Produces: 中文主工作流和中文 Skill UI 文案。

- [ ] **Step 1: 重写 Skill 正文**

保持 10 步工作流和维护/交付门禁含义不变，将章节、规则和命令说明改为中文；frontmatter `name` 保持 `mo-feature-test-design`。

- [ ] **Step 2: 更新 README 与 UI 文案**

说明四个 Python 文件用途和三类执行命令；`display_name` 保持产品名，描述与默认提示改为中文。

- [ ] **Step 3: 运行 Skill 校验**

Run: `python3 /Users/ariznawl/.codex/skills/.system/skill-creator/scripts/quick_validate.py 测试模版`

Expected: `Skill is valid!`

- [ ] **Step 4: 提交**

```bash
git add 测试模版/SKILL.md 测试模版/README.md 测试模版/agents/openai.yaml
git commit -m "docs: localize MatrixOne test design skill"
```

### Task 4: 完整验证与 PR 更新

**Files:**
- Verify: `测试模版/**`
- Verify: `README.md`

**Interfaces:**
- Consumes: 前三项全部输出。
- Produces: 通过验证并推送到 PR #11 的中文测试模版。

- [ ] **Step 1: 运行全部自动化验证**

```bash
PYTHONDONTWRITEBYTECODE=1 python3 -m unittest discover -s 测试模版/scripts -p 'test_*.py' -v
PYTHONDONTWRITEBYTECODE=1 python3 测试模版/scripts/audit_capability_catalog.py --repo-root /Users/ariznawl/weilu/matrixone
python3 /Users/ariznawl/.codex/skills/.system/skill-creator/scripts/quick_validate.py 测试模版
git diff --check origin/main...HEAD
```

- [ ] **Step 2: 扫描残留与生成物**

确认不存在未完成占位标记、成段英文流程、`__pycache__` 或 `.pyc`；测试中的假 Token 仅用于敏感信息拒绝测试。

- [ ] **Step 3: 推送并复核 PR**

```bash
git push origin codex/test-template
gh pr view 11 --repo Ariznawlll/mo-test-reports
```

Expected: PR #11 保持 Open，新增提交和文件清单准确。
