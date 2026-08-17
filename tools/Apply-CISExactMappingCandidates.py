#!/usr/bin/env python3
"""Apply hash-bound exact mapping candidates to a new public-safe catalog.

Only records emitted as ``exact-candidate`` by New-CISExactMappingCandidates.py
are promoted. The source catalog is never overwritten by this script.
"""

from __future__ import annotations

import argparse
import copy
import hashlib
import json
import re
import subprocess
import sys
import tempfile
from collections import defaultdict
from pathlib import Path
from typing import Any


FAMILY_LABELS = {
    "windows11": "Windows 11",
    "windows10": "Windows 10",
    "edge": "Microsoft Edge",
    "office": "Microsoft Office",
    "macos": "macOS 26 Tahoe",
    "ios": "iOS/iPadOS 26",
}

PLATFORMS = {
    "windows11": "windows10",
    "windows10": "windows10",
    "edge": "windows10",
    "office": "windows10",
    "macos": "macOS",
    "ios": "iOS",
}


def read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as handle:
        value = json.load(handle)
    if not isinstance(value, dict):
        raise ValueError(f"Expected a JSON object: {path}")
    return value


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def natural_key(value: str) -> tuple[Any, ...]:
    return tuple(int(part) if part.isdigit() else part.lower() for part in re.split(r"(\d+)", value))


def safe_id(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--extraction", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--worklist", type=Path, required=True)
    parser.add_argument("--output-catalog", type=Path, required=True)
    parser.add_argument("--catalog-version", required=True)
    parser.add_argument("--max-settings-per-policy", type=int, default=75)
    args = parser.parse_args()

    if not args.worklist.name.endswith(".private-mapping-candidates.json"):
        raise SystemExit("Worklist must end with .private-mapping-candidates.json")
    if args.output_catalog.exists():
        raise SystemExit(f"Output catalog already exists: {args.output_catalog}")
    if args.max_settings_per_policy < 1 or args.max_settings_per_policy > 500:
        raise SystemExit("max-settings-per-policy must be between 1 and 500")

    extraction = read_json(args.extraction)
    read_json(args.snapshot)
    catalog = read_json(args.catalog)
    worklist = read_json(args.worklist)
    if worklist.get("mappingChangesMade") is not False:
        raise SystemExit("Worklist must state mappingChangesMade=false")
    source = worklist.get("source") or {}
    expected_hashes = {
        "extractionSha256": sha256_file(args.extraction),
        "settingsCatalogSnapshotSha256": sha256_file(args.snapshot),
        "mappingCatalogSha256": sha256_file(args.catalog),
    }
    for name, expected in expected_hashes.items():
        if source.get(name) != expected:
            raise SystemExit(f"Worklist {name} does not match the supplied input")
    if worklist.get("family") not in FAMILY_LABELS:
        raise SystemExit("Worklist family is unsupported")
    family = str(worklist["family"])
    if (worklist.get("benchmark") or {}).get("id") != (extraction.get("benchmark") or {}).get("id"):
        raise SystemExit("Worklist and extraction benchmark IDs differ")
    if (worklist.get("benchmark") or {}).get("version") != (extraction.get("benchmark") or {}).get("version"):
        raise SystemExit("Worklist and extraction benchmark versions differ")
    if (catalog.get("benchmark") or {}).get("id") != (extraction.get("benchmark") or {}).get("id"):
        raise SystemExit("Catalog and extraction benchmark IDs differ")
    if (catalog.get("benchmark") or {}).get("version") != (extraction.get("benchmark") or {}).get("version"):
        raise SystemExit("Catalog and extraction benchmark versions differ")

    generator = Path(__file__).with_name("New-CISExactMappingCandidates.py")
    if not generator.is_file():
        raise SystemExit(f"Exact-candidate generator is missing: {generator}")
    with tempfile.TemporaryDirectory(prefix="cpc-exact-candidates-") as temporary:
        regenerated_path = Path(temporary) / "regenerated.private-mapping-candidates.json"
        completed = subprocess.run(
            [
                sys.executable,
                str(generator),
                "--extraction",
                str(args.extraction),
                "--snapshot",
                str(args.snapshot),
                "--catalog",
                str(args.catalog),
                "--family",
                family,
                "--output",
                str(regenerated_path),
            ],
            check=False,
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            detail = (completed.stderr or completed.stdout).strip()
            raise SystemExit(f"Could not independently regenerate the exact candidates: {detail}")
        regenerated = read_json(regenerated_path)
    if worklist != regenerated:
        raise SystemExit(
            "Worklist differs from an independent regeneration; refusing candidate promotion"
        )

    output = copy.deepcopy(catalog)
    output["version"] = args.catalog_version
    recommendation_by_id = {
        str(item["recommendationId"]): item for item in output.get("recommendations") or []
    }
    if len(recommendation_by_id) != len(output.get("recommendations") or []):
        raise SystemExit("Catalog contains duplicate recommendation IDs")
    extracted_ids = {str(item["recommendationId"]) for item in extraction.get("recommendations") or []}
    if set(recommendation_by_id) != extracted_ids:
        raise SystemExit("Catalog and extraction recommendation sets differ")

    candidates = [
        item for item in worklist.get("recommendations") or [] if item.get("status") == "exact-candidate"
    ]
    candidates.sort(key=lambda item: natural_key(str(item["recommendationId"])))
    seen_candidate_ids: set[str] = set()
    grouped: dict[tuple[str, ...], list[dict[str, Any]]] = defaultdict(list)
    for candidate in candidates:
        recommendation_id = str(candidate["recommendationId"])
        if recommendation_id in seen_candidate_ids:
            raise SystemExit(f"Duplicate exact candidate: {recommendation_id}")
        seen_candidate_ids.add(recommendation_id)
        recommendation = recommendation_by_id.get(recommendation_id)
        if not recommendation:
            raise SystemExit(f"Candidate references unknown recommendation: {recommendation_id}")
        if recommendation.get("mappingStatus") != "unresolved":
            raise SystemExit(
                f"Exact candidate {recommendation_id} is not unresolved in the source catalog"
            )
        profiles = tuple(str(value) for value in candidate.get("profiles") or [])
        if not profiles or list(profiles) != list(recommendation.get("profiles") or []):
            raise SystemExit(f"Candidate profiles differ for recommendation {recommendation_id}")
        root_id = str(((candidate.get("candidate") or {}).get("rootDefinitionId") or ""))
        setting = (candidate.get("candidate") or {}).get("setting")
        if not root_id or not isinstance(setting, dict):
            raise SystemExit(f"Candidate {recommendation_id} is incomplete")
        if str(((setting.get("resolve") or {}).get("definitionId") or "")) != root_id:
            raise SystemExit(f"Candidate {recommendation_id} root definition is inconsistent")
        grouped[profiles].append(candidate)

    new_policies: list[dict[str, Any]] = []
    new_settings: list[dict[str, Any]] = []
    label = FAMILY_LABELS[family]
    platform = PLATFORMS[family]
    pack_version = str((catalog.get("pack") or {}).get("version") or "")

    for profiles in sorted(grouped):
        bins: list[dict[str, Any]] = []
        for candidate in grouped[profiles]:
            root_id = str(candidate["candidate"]["rootDefinitionId"])
            target = next(
                (
                    item
                    for item in bins
                    if root_id not in item["rootIds"]
                    and len(item["candidates"]) < args.max_settings_per_policy
                ),
                None,
            )
            if target is None:
                target = {"rootIds": set(), "candidates": []}
                bins.append(target)
            target["rootIds"].add(root_id)
            target["candidates"].append(candidate)

        profile_label = "+".join(profiles)
        profile_id = safe_id(profile_label)
        for index, policy_bin in enumerate(bins, start=1):
            policy_id = f"{family}-verified-{profile_id}-part-{index}"
            policy_name = f"CIS - {label} Verified [{profile_label}] - v{pack_version} - Part {index}"
            new_policies.append(
                {
                    "id": policy_id,
                    "name": policy_name,
                    "description": (
                        "Strict exact-name, exact-value mappings validated against a pinned "
                        "Microsoft Graph Settings Catalog snapshot."
                    ),
                    "platforms": platform,
                    "technologies": "mdm",
                    "profiles": list(profiles),
                    "roleScopeTagIds": ["0"],
                }
            )
            for candidate in policy_bin["candidates"]:
                recommendation_id = str(candidate["recommendationId"])
                setting = candidate["candidate"]["setting"]
                recommendation = recommendation_by_id[recommendation_id]
                recommendation["mappingStatus"] = "mapped"
                recommendation["implementationType"] = "settings-catalog"
                recommendation["implementationRefs"] = [f"settings-catalog:{policy_id}"]
                recommendation["decisionRef"] = None
                recommendation["notes"] = (
                    "Exact PDF setting name/value and pinned-snapshot definition/value IDs; "
                    "complete dependency tree validated without inference."
                )
                new_settings.append(
                    {
                        "recommendationId": recommendation_id,
                        "policyId": policy_id,
                        "displayName": setting["displayName"],
                        "profiles": list(profiles),
                        "resolve": setting["resolve"],
                        "value": setting["value"],
                    }
                )

    existing_policy_ids = {str(item["id"]) for item in output.get("settingsCatalogPolicies") or []}
    for policy in new_policies:
        if policy["id"] in existing_policy_ids:
            raise SystemExit(f"Generated policy ID collides with source catalog: {policy['id']}")
        existing_policy_ids.add(policy["id"])
    output["settingsCatalogPolicies"] = (output.get("settingsCatalogPolicies") or []) + new_policies
    output["settingsCatalogSettings"] = (output.get("settingsCatalogSettings") or []) + new_settings

    args.output_catalog.parent.mkdir(parents=True, exist_ok=True)
    args.output_catalog.write_text(
        json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    print(
        f"Promoted {len(new_settings)} exact candidates into {len(new_policies)} new policies: "
        f"{args.output_catalog}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
