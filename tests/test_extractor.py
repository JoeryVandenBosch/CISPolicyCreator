from __future__ import annotations

import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "cpc_extractor", ROOT / "tools" / "Extract-CISRecommendations.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class ExtractorTests(unittest.TestCase):
    def test_parser_contract_is_hash_locked_and_schema_bound(self) -> None:
        self.assertEqual(MODULE.load_parser_contract(), "6.15.0")

    def test_parser_contract_rejects_unhashed_or_schema_mismatched_versions(self) -> None:
        schema = json.loads(MODULE.EXTRACTION_SCHEMA_PATH.read_text(encoding="utf-8"))
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requirements = root / "requirements.txt"
            schema_path = root / "extraction.schema.json"
            schema_path.write_text(json.dumps(schema), encoding="utf-8")

            requirements.write_text("pypdf==6.15.0\n", encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "at least one SHA-256 hash"):
                MODULE.load_parser_contract(requirements, schema_path)

            requirements.write_text(
                "pypdf==6.14.0 --hash=sha256:" + ("a" * 64) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(ValueError, "disagrees with extraction.schema.json"):
                MODULE.load_parser_contract(requirements, schema_path)

    def test_runtime_rejects_an_installed_parser_version_mismatch(self) -> None:
        with patch.object(MODULE.importlib.metadata, "version", return_value="0.0.0"):
            with self.assertRaisesRegex(RuntimeError, "installed=0.0.0; required=6.15.0"):
                MODULE.verify_runtime()

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

    def test_cis_controls_reference_is_not_treated_as_recommendation(self) -> None:
        text = """
<<<PAGE 1>>>
Page 1
1.1 Ensure synthetic setting is enabled (Automated)
Profile Applicability:
Level 1
Audit:
Synthetic audit text.
Remediation:
Synthetic remediation text.
CIS Controls:
9.2 Ensure Only Approved Ports, Protocols and Services Are Running
Ensure that only approved services are running.
<<<PAGE 2>>>
Page 2
1.2 Ensure second synthetic setting is enabled (Manual)
Profile Applicability:
Level 2
Audit:
Synthetic audit text.
Remediation:
Synthetic remediation text.
"""
        records = MODULE.extract(text)
        self.assertEqual([item["recommendationId"] for item in records], ["1.1", "1.2"])
        self.assertEqual([item["page"] for item in records], [1, 2])


if __name__ == "__main__":
    unittest.main()
