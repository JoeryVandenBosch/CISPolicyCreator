import copy
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[1]
GENERATOR = REPO_ROOT / "tools" / "New-CISExactMappingCandidates.py"
APPLIER = REPO_ROOT / "tools" / "Apply-CISExactMappingCandidates.py"
CHOICE = "#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition"


class ExactMappingToolsTests(unittest.TestCase):
    def write_json(self, path: Path, value: object) -> None:
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")

    def fixtures(self, root: Path) -> tuple[Path, Path, Path]:
        extraction = {
            "benchmark": {"id": "synthetic", "version": "1.0.0"},
            "recommendations": [
                {
                    "recommendationId": "1.1",
                    "title": '"Block Foo" is set to "Enabled"',
                    "remediation": "Set Block Foo to Enabled",
                    "profiles": ["L1"],
                    "cisAssessmentMethod": "Manual",
                },
                {
                    "recommendationId": "1.2",
                    "title": '"Turn off thing" is set to "Enabled"',
                    "remediation": "Set Turn off thing to Enabled",
                    "profiles": ["L1"],
                    "cisAssessmentMethod": "Automated",
                },
            ],
        }
        enabled = {
            "displayName": "Enabled",
            "name": "Enabled",
            "itemId": "enabled-exact-id",
            "optionValue": {"value": True},
        }
        definitions = [
            {
                "id": "device_vendor_msft_policy_config_synthetic_blockfoo",
                "displayName": "Block Foo",
                "@odata.type": CHOICE,
                "options": [enabled],
            },
            {
                "id": "device_vendor_msft_policy_config_synthetic_turnoffthing",
                "displayName": "Turn off thing (Device)",
                "@odata.type": CHOICE,
                "options": [enabled],
            },
            {
                "id": "user_vendor_msft_policy_config_synthetic_turnoffthing",
                "displayName": "Turn off thing (User)",
                "@odata.type": CHOICE,
                "options": [enabled],
            },
        ]
        snapshot = {
            "retrieval": {"definitionCount": len(definitions)},
            "definitions": definitions,
        }
        recommendations = [
            {
                "recommendationId": item["recommendationId"],
                "profiles": item["profiles"],
                "cisAssessmentMethod": item["cisAssessmentMethod"],
                "mappingStatus": "unresolved",
                "implementationType": None,
                "implementationRefs": [],
                "decisionRef": None,
                "notes": None,
            }
            for item in extraction["recommendations"]
        ]
        catalog = {
            "benchmark": {"id": "synthetic", "version": "1.0.0"},
            "pack": {"id": "synthetic-pack", "name": "Synthetic", "version": "1.0.0"},
            "recommendations": recommendations,
            "settingsCatalogPolicies": [],
            "settingsCatalogSettings": [],
        }
        extraction_path = root / "extraction.json"
        snapshot_path = root / "snapshot.json"
        catalog_path = root / "catalog.json"
        self.write_json(extraction_path, extraction)
        self.write_json(snapshot_path, snapshot)
        self.write_json(catalog_path, catalog)
        return extraction_path, snapshot_path, catalog_path

    def run_generator(self, extraction: Path, snapshot: Path, catalog: Path, output: Path) -> None:
        subprocess.run(
            [
                sys.executable,
                str(GENERATOR),
                "--extraction",
                str(extraction),
                "--snapshot",
                str(snapshot),
                "--catalog",
                str(catalog),
                "--family",
                "windows11",
                "--output",
                str(output),
            ],
            check=True,
            capture_output=True,
            text=True,
        )

    def test_only_unique_exact_candidate_is_promoted(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            extraction, snapshot, catalog = self.fixtures(root)
            worklist = root / "review.private-mapping-candidates.json"
            output = root / "output-catalog.json"
            self.run_generator(extraction, snapshot, catalog, worklist)
            review = json.loads(worklist.read_text(encoding="utf-8"))
            states = {item["recommendationId"]: item["status"] for item in review["recommendations"]}
            self.assertEqual(states["1.1"], "exact-candidate")
            self.assertEqual(states["1.2"], "ambiguous-exact-candidates")

            subprocess.run(
                [
                    sys.executable,
                    str(APPLIER),
                    "--extraction",
                    str(extraction),
                    "--snapshot",
                    str(snapshot),
                    "--catalog",
                    str(catalog),
                    "--worklist",
                    str(worklist),
                    "--output-catalog",
                    str(output),
                    "--catalog-version",
                    "0.2.0",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            promoted = json.loads(output.read_text(encoding="utf-8"))
            statuses = {
                item["recommendationId"]: item["mappingStatus"]
                for item in promoted["recommendations"]
            }
            self.assertEqual(statuses, {"1.1": "mapped", "1.2": "unresolved"})
            self.assertEqual(len(promoted["settingsCatalogSettings"]), 1)
            self.assertEqual(
                promoted["settingsCatalogSettings"][0]["resolve"]["definitionId"],
                "device_vendor_msft_policy_config_synthetic_blockfoo",
            )
            self.assertEqual(
                promoted["settingsCatalogSettings"][0]["value"]["optionId"],
                "enabled-exact-id",
            )

    def test_modified_worklist_is_rejected_by_independent_regeneration(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            extraction, snapshot, catalog = self.fixtures(root)
            worklist = root / "review.private-mapping-candidates.json"
            output = root / "output-catalog.json"
            self.run_generator(extraction, snapshot, catalog, worklist)
            review = json.loads(worklist.read_text(encoding="utf-8"))
            exact = copy.deepcopy(review["recommendations"][0]["candidate"])
            ambiguous = review["recommendations"][1]
            ambiguous.clear()
            ambiguous.update(
                {
                    "recommendationId": "1.2",
                    "status": "exact-candidate",
                    "profiles": ["L1"],
                    "cisAssessmentMethod": "Automated",
                    "candidate": exact,
                }
            )
            self.write_json(worklist, review)
            completed = subprocess.run(
                [
                    sys.executable,
                    str(APPLIER),
                    "--extraction",
                    str(extraction),
                    "--snapshot",
                    str(snapshot),
                    "--catalog",
                    str(catalog),
                    "--worklist",
                    str(worklist),
                    "--output-catalog",
                    str(output),
                    "--catalog-version",
                    "0.2.0",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("differs from an independent regeneration", completed.stderr)
            self.assertFalse(output.exists())


if __name__ == "__main__":
    unittest.main()
