from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "cpc_extractor", ROOT / "tools" / "Extract-CISRecommendations.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ExtractorTests(unittest.TestCase):
    def test_manual_and_automated_are_preserved(self) -> None:
        text = """
<<<PAGE 1>>>
1.1 Ensure synthetic manual setting (Manual)
Profile Applicability:
Level 1
Audit:
Synthetic audit text.
Remediation:
Synthetic remediation text.
<<<PAGE 2>>>
1.2 Ensure synthetic automated setting (Automated)
Profile Applicability:
Level 2
Audit:
Synthetic audit text.
Remediation:
Synthetic remediation text.
"""
        records = MODULE.extract(text)
        self.assertEqual([item["recommendationId"] for item in records], ["1.1", "1.2"])
        self.assertEqual(records[0]["cisAssessmentMethod"], "Manual")
        self.assertEqual(records[0]["profiles"], ["L1"])
        self.assertEqual(records[1]["cisAssessmentMethod"], "Automated")
        self.assertEqual(records[1]["profiles"], ["L2"])

    def test_empty_extraction_fails_closed(self) -> None:
        with self.assertRaisesRegex(ValueError, "No CIS Intune recommendations"):
            MODULE.extract("not a benchmark")

    def test_unknown_profile_fails_closed(self) -> None:
        text = """
<<<PAGE 1>>>
1.1 Ensure synthetic setting (Automated)
Profile Applicability:
Unknown profile
Audit:
Synthetic audit text.
"""
        with self.assertRaisesRegex(ValueError, "Could not normalize"):
            MODULE.extract(text)


if __name__ == "__main__":
    unittest.main()
