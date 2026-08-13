#!/usr/bin/env python3
"""审计 MatrixOne 能力目录的结构和仓库路径。"""

from __future__ import annotations

import argparse
import re
from pathlib import Path


REQUIRED_FIELDS = (
    "支持状态",
    "用户入口",
    "支持证据",
    "支持范围",
    "限制条件",
    "状态与不变量",
    "测试分层",
)
FIELD_ALIASES = {
    "Status": "支持状态",
    "User entry": "用户入口",
    "Support evidence": "支持证据",
    "Scope": "支持范围",
    "Limitations": "限制条件",
    "State and invariants": "状态与不变量",
    "Test routing": "测试分层",
    "Repository evidence": "仓库证据",
    "Interactions": "关联能力",
    "Coverage gaps": "覆盖缺口",
}
ALLOWED_STATUSES = {"supported", "supported-with-conditions"}
NON_DOMAIN_FILES = {
    "capability-index.md",
    "capability-entry-contract.md",
}
HEADING = re.compile(r"(?m)^## ([a-z0-9][a-z0-9.-]+)\s*$")
FIELD = re.compile(r"(?m)^- \*\*([^*]+):\*\*\s*(.+)$")
REPO_PATH = re.compile(r"`repo:([^`]+)`")


def _entries(path: Path) -> list[tuple[str, str]]:
    text = path.read_text(encoding="utf-8")
    matches = list(HEADING.finditer(text))
    entries: list[tuple[str, str]] = []
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        entries.append((match.group(1), text[match.end() : end]))
    return entries


def audit_catalog(skill_dir: Path, repo_root: Path | None = None) -> list[str]:
    """返回目录错误；空列表表示目录结构有效。"""
    errors: list[str] = []
    references = skill_dir / "references"
    files = sorted(
        path
        for path in references.glob("capability-*.md")
        if path.name not in NON_DOMAIN_FILES
    )
    if not files:
        return ["未找到能力域文件"]

    seen: dict[str, Path] = {}
    for path in files:
        entries = _entries(path)
        if not entries:
            errors.append(f"{path.name}：没有能力条目")
            continue
        for capability_id, body in entries:
            if capability_id in seen:
                errors.append(
                    f"{path.name}：能力 ID {capability_id} 重复"
                    f"（也存在于 {seen[capability_id].name}）"
                )
            else:
                seen[capability_id] = path

            fields = {
                FIELD_ALIASES.get(name.strip(), name.strip()): value.strip()
                for name, value in FIELD.findall(body)
            }
            for required in REQUIRED_FIELDS:
                if not fields.get(required):
                    errors.append(
                        f"{path.name}:{capability_id}：缺少字段 {required}"
                    )

            status = fields.get("支持状态", "")
            if status and status not in ALLOWED_STATUSES:
                errors.append(
                    f"{path.name}:{capability_id}：不允许的支持状态 {status}"
                )

            if repo_root is not None:
                for relative in REPO_PATH.findall(body):
                    candidate = repo_root / relative
                    if not candidate.exists():
                        errors.append(
                            f"{path.name}:{capability_id}：仓库路径不存在 {relative}"
                        )
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "skill_dir",
        nargs="?",
        default=str(Path(__file__).resolve().parents[1]),
    )
    parser.add_argument("--repo-root", type=Path)
    args = parser.parse_args()
    errors = audit_catalog(Path(args.skill_dir), args.repo_root)
    if errors:
        for error in errors:
            print(f"错误：{error}")
        return 1
    print("通过：能力目录契约校验成功")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
