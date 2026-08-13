import importlib.util
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("audit_capability_catalog.py")


def load_module():
    spec = importlib.util.spec_from_file_location("catalog_audit", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


VALID_ENTRY = """# SQL capabilities

## sql.query.select

- **Status:** supported
- **User entry:** `SELECT`
- **Support evidence:** https://docs.matrixorigin.cn/
- **Scope:** single-table query
- **Limitations:** documented compatibility boundary
- **State and invariants:** exact rows and types
- **Test routing:** BVT
- **Repository evidence:** `repo:test/distributed/cases/select`
"""

VALID_CHINESE_ENTRY = """# SQL 能力

## sql.query.select

- **支持状态:** supported
- **用户入口:** `SELECT`
- **支持证据:** https://docs.matrixorigin.cn/
- **支持范围:** 单表查询
- **限制条件:** 以兼容矩阵为准
- **状态与不变量:** 行和类型精确匹配
- **测试分层:** BVT
- **仓库证据:** `repo:test/distributed/cases/select`
"""


class CatalogAuditTest(unittest.TestCase):
    def setUp(self):
        self.module = load_module()
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "references").mkdir()
        (self.root / "repo" / "test" / "distributed" / "cases" / "select").mkdir(
            parents=True
        )

    def tearDown(self):
        self.temp.cleanup()

    def write(self, name: str, text: str) -> None:
        (self.root / "references" / name).write_text(text, encoding="utf-8")

    def test_accepts_complete_supported_entry_and_existing_repo_path(self):
        self.write("capability-sql.md", VALID_ENTRY)
        self.assertEqual(
            self.module.audit_catalog(self.root, self.root / "repo"), []
        )

    def test_accepts_complete_chinese_entry(self):
        self.write("capability-sql.md", VALID_CHINESE_ENTRY)
        self.assertEqual(
            self.module.audit_catalog(self.root, self.root / "repo"), []
        )

    def test_cli_success_message_is_chinese(self):
        self.write("capability-sql.md", VALID_CHINESE_ENTRY)
        result = subprocess.run(
            [
                sys.executable,
                str(MODULE_PATH),
                str(self.root),
                "--repo-root",
                str(self.root / "repo"),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("通过：能力目录契约校验成功", result.stdout)

    def test_rejects_missing_required_field(self):
        self.write(
            "capability-sql.md",
            VALID_ENTRY.replace("- **State and invariants:** exact rows and types\n", ""),
        )
        errors = self.module.audit_catalog(self.root, self.root / "repo")
        self.assertTrue(any("状态与不变量" in error for error in errors))

    def test_rejects_experimental_entry(self):
        self.write(
            "capability-sql.md",
            VALID_ENTRY.replace("**Status:** supported", "**Status:** experimental"),
        )
        errors = self.module.audit_catalog(self.root, self.root / "repo")
        self.assertTrue(any("不允许的支持状态" in error for error in errors))

    def test_rejects_duplicate_capability_id(self):
        self.write("capability-sql.md", VALID_ENTRY)
        self.write("capability-query.md", VALID_ENTRY)
        errors = self.module.audit_catalog(self.root, self.root / "repo")
        self.assertTrue(any("能力 ID" in error and "重复" in error for error in errors))

    def test_rejects_missing_repository_evidence_path(self):
        self.write(
            "capability-sql.md",
            VALID_ENTRY.replace(
                "repo:test/distributed/cases/select",
                "repo:test/distributed/cases/does-not-exist",
            ),
        )
        errors = self.module.audit_catalog(self.root, self.root / "repo")
        self.assertTrue(any("仓库路径不存在" in error for error in errors))


if __name__ == "__main__":
    unittest.main()
