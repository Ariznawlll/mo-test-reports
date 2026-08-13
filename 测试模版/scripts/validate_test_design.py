#!/usr/bin/env python3
"""Validate the structural contract of a MatrixOne feature test design."""

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
    "Happy Path",
    "Boundary Path",
    "Unhappy Path",
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
            errors.append(f"missing section: {heading}")
        else:
            positions.append(match.start())
            if not _section(text, heading):
                errors.append(f"empty section: {heading}")
    if len(positions) == len(REQUIRED_HEADINGS) and positions != sorted(positions):
        errors.append("sections are not in the required order")

    baseline = _section(text, "支持证据与版本基线")
    if not SHA.search(baseline):
        errors.append("missing 40-character official main SHA")
    if not URL.search(baseline):
        errors.append("missing formal support evidence URL")

    capabilities = _section(text, "涉及的 MatrixOne 能力")
    if not CAPABILITY.search(capabilities):
        errors.append("missing capability_id mapping")

    routing = _section(text, "回归分层与已有资产")
    if not ROUTING.search(routing):
        errors.append("missing concrete test routing")

    not_applicable = _section(text, "不适用项及原因")
    for line in not_applicable.splitlines():
        stripped = line.strip()
        if "不适用" in stripped and "：" not in stripped and ":" not in stripped:
            errors.append(f"不适用 item lacks a reason: {stripped}")

    if any(pattern.search(text) for pattern in SECRETS):
        errors.append("design may contain a secret")
    return errors


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("path", nargs="?", help="Read stdin when omitted")
    args = parser.parse_args()
    text = Path(args.path).read_text(encoding="utf-8") if args.path else sys.stdin.read()
    errors = validate_design(text)
    if errors:
        for error in errors:
            print(f"ERROR: {error}", file=sys.stderr)
        return 1
    print("OK: feature test design contract satisfied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
