#!/usr/bin/env python3
"""校验 MatrixOne Feature 测试设计的结构契约。"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


REQUIRED_HEADINGS = (
    "Feature 背景与范围",
    "支持证据与版本基线",
    "验收目标与非目标",
    "涉及的 MatrixOne 能力",
    "架构、入口、数据流与状态对象",
    "风险与关键不变量",
    "测试环境、拓扑、配置与数据",
    "功能测试矩阵",
    "正常路径（Happy Path）",
    "边界路径（Boundary Path）",
    "异常路径（Unhappy Path）",
    "事务与并发",
    "安全与租户隔离",
    "恢复与故障注入",
    "性能、规模与稳定性",
    "兼容性",
    "可观测性与资源清理",
    "回归分层与已有资产",
    "不适用项及原因",
    "准入、退出、风险与待确认项",
)
SHA = re.compile(r"(?i)(?<![0-9a-f])[0-9a-f]{40}(?![0-9a-f])")
CAPABILITY = re.compile(r"capability_id\s*:\s*`?[a-z0-9][a-z0-9.-]+`?")
URL = re.compile(r"https?://[^\s)>]+")
ROUTING = re.compile(
    r"\b(?:UT|BVT|MOTR|big-data|stability|chaos|GPU|PITR|Snapshot)\b",
    re.IGNORECASE,
)
SECRETS = (
    re.compile(r"\bghp_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"(?i)\b(password|passwd|token|client-key-data)\s*[:=：]\s*[^\s`]{8,}"),
)


def _section(text: str, heading: str) -> str:
    match = re.search(
        rf"(?ms)^## {re.escape(heading)}\s*$\n(.*?)(?=^## |\Z)", text
    )
    return match.group(1).strip() if match else ""


def validate_design(text: str) -> list[str]:
    errors: list[str] = []
    positions: list[int] = []
    for heading in REQUIRED_HEADINGS:
        match = re.search(rf"(?m)^## {re.escape(heading)}\s*$", text)
        if not match:
            errors.append(f"缺少章节：{heading}")
        else:
            positions.append(match.start())
            if not _section(text, heading):
                errors.append(f"章节内容为空：{heading}")
    if len(positions) == len(REQUIRED_HEADINGS) and positions != sorted(positions):
        errors.append("章节顺序不符合要求")

    baseline = _section(text, "支持证据与版本基线")
    if not SHA.search(baseline):
        errors.append("缺少官方 main 的 40 位完整 SHA")
    if not URL.search(baseline):
        errors.append("缺少正式支持证据 URL")

    capabilities = _section(text, "涉及的 MatrixOne 能力")
    if not CAPABILITY.search(capabilities):
        errors.append("缺少 capability_id 映射")

    routing = _section(text, "回归分层与已有资产")
    if not ROUTING.search(routing):
        errors.append("缺少明确的测试分层")

    not_applicable = _section(text, "不适用项及原因")
    for line in not_applicable.splitlines():
        stripped = line.strip()
        if "不适用" in stripped and "：" not in stripped and ":" not in stripped:
            errors.append(f"不适用项缺少原因：{stripped}")

    if any(pattern.search(text) for pattern in SECRETS):
        errors.append("测试设计可能包含敏感凭据")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", help="Read stdin when omitted")
    args = parser.parse_args()
    text = Path(args.path).read_text(encoding="utf-8") if args.path else sys.stdin.read()
    errors = validate_design(text)
    if errors:
        for error in errors:
            print(f"错误：{error}", file=sys.stderr)
        return 1
    print("通过：Feature 测试设计契约校验成功")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
