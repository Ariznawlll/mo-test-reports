#!/usr/bin/env python3
"""Audit the structure and repository links of the MO capability catalog."""

from __future__ import annotations

import argparse
import re
from pathlib import Path


REQUIRED_FIELDS = (
    "Status",
    "User entry",
    "Support evidence",
    "Scope",
    "Limitations",
    "State and invariants",
    "Test routing",
)
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
    """Return catalog errors. An empty list means the catalog is structurally valid."""
    errors: list[str] = []
    references = skill_dir / "references"
    files = sorted(
        path
        for path in references.glob("capability-*.md")
        if path.name not in NON_DOMAIN_FILES
    )
    if not files:
        return ["no capability domain files found"]

    seen: dict[str, Path] = {}
    for path in files:
        entries = _entries(path)
        if not entries:
            errors.append(f"{path.name}: no capability entries")
            continue
        for capability_id, body in entries:
            if capability_id in seen:
                errors.append(
                    f"{path.name}: duplicate capability id {capability_id} "
                    f"(also in {seen[capability_id].name})"
                )
            else:
                seen[capability_id] = path

            fields = {name.strip(): value.strip() for name, value in FIELD.findall(body)}
            for required in REQUIRED_FIELDS:
                if not fields.get(required):
                    errors.append(
                        f"{path.name}:{capability_id}: missing field {required}"
                    )

            status = fields.get("Status", "")
            if status and status not in ALLOWED_STATUSES:
                errors.append(
                    f"{path.name}:{capability_id}: disallowed status {status}"
                )

            if repo_root is not None:
                for relative in REPO_PATH.findall(body):
                    candidate = repo_root / relative
                    if not candidate.exists():
                        errors.append(
                            f"{path.name}:{capability_id}: missing repository path {relative}"
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
            print(f"ERROR: {error}")
        return 1
    print("OK: capability catalog contract satisfied")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
