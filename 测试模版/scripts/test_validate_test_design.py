import importlib.util
import unittest
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("validate_test_design.py")


def load_module():
    spec = importlib.util.spec_from_file_location("design_validator", MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


HEADINGS = (
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


def valid_design() -> str:
    bodies = {heading: "已覆盖具体合同和预期结果。" for heading in HEADINGS}
    bodies["支持证据与版本基线"] = (
        "- main：`0123456789abcdef0123456789abcdef01234567`\n"
        "- 正式支持证据：https://docs.matrixorigin.cn/"
    )
    bodies["涉及的 MatrixOne 能力"] = (
        "- capability_id: `session.prepared-statement`"
    )
    bodies["回归分层与已有资产"] = "- BVT：公开 SQL\n- MOTR：binary protocol"
    bodies["不适用项及原因"] = "- Chaos 不适用：该语义不依赖节点或网络故障。"
    return "\n\n".join(f"## {heading}\n\n{bodies[heading]}" for heading in HEADINGS) + "\n"


class TestDesignValidatorTest(unittest.TestCase):
    def setUp(self):
        self.module = load_module()

    def test_accepts_complete_design(self):
        self.assertEqual(self.module.validate_design(valid_design()), [])

    def test_rejects_missing_section(self):
        text = valid_design().replace(
            "## Boundary Path\n\n已覆盖具体合同和预期结果。\n\n", ""
        )
        self.assertTrue(any("Boundary Path" in e for e in self.module.validate_design(text)))

    def test_rejects_missing_full_main_sha(self):
        text = valid_design().replace(
            "0123456789abcdef0123456789abcdef01234567", "deadbeef"
        )
        self.assertTrue(any("40-character" in e for e in self.module.validate_design(text)))

    def test_rejects_missing_capability_id(self):
        text = valid_design().replace("capability_id: `session.prepared-statement`", "会话能力")
        self.assertTrue(any("capability_id" in e for e in self.module.validate_design(text)))

    def test_rejects_missing_support_evidence(self):
        text = valid_design().replace("https://docs.matrixorigin.cn/", "无")
        self.assertTrue(any("support evidence" in e for e in self.module.validate_design(text)))

    def test_rejects_missing_test_routing(self):
        text = valid_design().replace("- BVT：公开 SQL\n- MOTR：binary protocol", "尚未分层")
        self.assertTrue(any("test routing" in e for e in self.module.validate_design(text)))

    def test_rejects_bare_not_applicable(self):
        text = valid_design().replace(
            "Chaos 不适用：该语义不依赖节点或网络故障。", "Chaos 不适用"
        )
        self.assertTrue(any("不适用" in e for e in self.module.validate_design(text)))

    def test_rejects_secret(self):
        text = valid_design().replace(
            "已覆盖具体合同和预期结果。",
            "token=ghp_abcdefghijklmnopqrstuvwxyz1234567890",
            1,
        )
        self.assertTrue(any("secret" in e for e in self.module.validate_design(text)))


if __name__ == "__main__":
    unittest.main()
