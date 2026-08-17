#!/usr/bin/env python3
"""Build a private worklist of strictly provable CIS-to-Settings-Catalog mappings.

This development tool never changes a mapping catalog. It accepts a private PDF
extraction plus an exact Settings Catalog snapshot, and emits candidates only when
the recommendation setting name, product family, prescribed value, and complete
parent/child tree can all be resolved without guessing.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import unicodedata
from collections import defaultdict
from pathlib import Path
from typing import Any


CHOICE = "#microsoft.graph.deviceManagementConfigurationChoiceSettingDefinition"
SIMPLE = "#microsoft.graph.deviceManagementConfigurationSimpleSettingDefinition"
GROUP = "#microsoft.graph.deviceManagementConfigurationSettingGroupCollectionDefinition"
INTEGER_VALUE = "#microsoft.graph.deviceManagementConfigurationIntegerSettingValueDefinition"
STRING_VALUE = "#microsoft.graph.deviceManagementConfigurationStringSettingValueDefinition"


def normalize(value: str | None) -> str:
    if not value:
        return ""
    value = unicodedata.normalize("NFKC", value).lower()
    return " ".join(re.findall(r"[^\W_]+", value, flags=re.UNICODE))


def normalize_display_name(value: str | None) -> str:
    if not value:
        return ""
    without_scope = re.sub(r"\s+\((?:User|Device)\)\s*$", "", value, flags=re.IGNORECASE)
    return normalize(without_scope)


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


def resolver(definition: dict[str, Any]) -> dict[str, Any]:
    return {
        "definitionId": definition["id"],
        "baseUri": definition.get("baseUri"),
        "offsetUri": definition.get("offsetUri"),
        "expectedType": definition["@odata.type"],
    }


def node(definition: dict[str, Any], value: dict[str, Any]) -> dict[str, Any]:
    return {
        "displayName": definition["displayName"],
        "resolve": resolver(definition),
        "value": value,
    }


def node_display_names_present(setting_node: dict[str, Any]) -> bool:
    if not str(setting_node.get("displayName") or "").strip():
        return False
    value = setting_node.get("value") or {}
    for child in value.get("children") or []:
        if not node_display_names_present(child):
            return False
    for item in value.get("items") or []:
        for child in item.get("children") or []:
            if not node_display_names_present(child):
                return False
    return True


def parse_title(title: str) -> tuple[str, str] | None:
    cleaned = (
        title.replace("“", '"')
        .replace("”", '"')
        .replace("‘", "'")
        .replace("’", "'")
        .strip()
    )
    match = re.match(
        r"^(?:Ensure\s+)?(?P<q>['\"])(?P<name>.+?)(?P=q)\s+(?:is\s+set\s+to|to)\s+"
        r"(?P<vq>['\"])(?P<value>.+)(?P=vq)(?:\s+\([^)]*\))?$",
        cleaned,
        flags=re.IGNORECASE,
    )
    if not match:
        return None
    return match.group("name").strip(), match.group("value").strip()


def family_allows(family: str, definition_id: str) -> bool:
    lowered = definition_id.lower()
    if family == "edge":
        return lowered.startswith(
            ("device_vendor_msft_policy_config_microsoft_edge", "user_vendor_msft_policy_config_microsoft_edge")
        )
    if family == "office":
        office_products = ("office16", "access16", "excel16", "outlk16", "outlook16", "ppt16", "pub16", "word16")
        return any(
            lowered.startswith(f"{scope}_vendor_msft_policy_config_{product}")
            for scope in ("device", "user")
            for product in office_products
        ) or lowered.startswith("device_vendor_msft_policy_config_secguide")
    if family in {"macos", "ios"}:
        return lowered.startswith("com.apple.")
    if family in {"windows10", "windows11"}:
        if not lowered.startswith(("device_vendor_msft_policy_config_", "user_vendor_msft_policy_config_")):
            return False
        product_exclusions = (
            "office16",
            "access16",
            "excel16",
            "outlk16",
            "outlook16",
            "ppt16",
            "pub16",
            "word16",
            "microsoft_edge",
            "chromeintune",
        )
        excluded = tuple(
            f"{scope}_vendor_msft_policy_config_{product}"
            for scope in ("device", "user")
            for product in product_exclusions
        )
        return not lowered.startswith(excluded)
    raise ValueError(f"Unsupported family: {family}")


def option_matches(option: dict[str, Any], desired: str) -> bool:
    wanted = normalize(desired)
    if wanted in {normalize(option.get("displayName")), normalize(option.get("name"))}:
        return True
    raw = (option.get("optionValue") or {}).get("value")
    if wanted == "yes" and raw in (True, "true", 1):
        return normalize(option.get("displayName")) == "true"
    if wanted == "no" and raw in (False, "false", 0):
        return normalize(option.get("displayName")) == "false"
    return False


def exact_option(definition: dict[str, Any], desired: str) -> dict[str, Any] | None:
    matches = [option for option in definition.get("options") or [] if option_matches(option, desired)]
    return matches[0] if len(matches) == 1 else None


def required_children(option: dict[str, Any]) -> list[str]:
    result: list[str] = []
    for dependency in option.get("dependedOnBy") or []:
        if dependency.get("required") is True and dependency.get("dependedOnBy"):
            result.append(str(dependency["dependedOnBy"]))
    return result


def required_child_ids(
    definition: dict[str, Any], selected_option: dict[str, Any] | None = None
) -> list[str]:
    return sorted(set(required_children(definition) + required_children(selected_option or {})))


def definition_dependencies(
    definition: dict[str, Any], selected_option: dict[str, Any] | None
) -> list[dict[str, Any]]:
    dependencies = []
    if selected_option:
        dependencies.extend(selected_option.get("dependentOn") or [])
    dependencies.extend(definition.get("dependentOn") or [])
    unique: dict[tuple[str, str], dict[str, Any]] = {}
    for dependency in dependencies:
        parent = str(dependency.get("parentSettingId") or "")
        required_value = str(dependency.get("dependentOn") or "")
        if parent:
            unique[(parent, required_value)] = dependency
    return list(unique.values())


def simple_value(definition: dict[str, Any], desired: str) -> dict[str, Any] | None:
    value_definition = definition.get("valueDefinition") or {}
    value_type = value_definition.get("@odata.type")
    if value_type == INTEGER_VALUE and re.fullmatch(r"-?\d+", desired.strip()):
        value = int(desired.strip())
        minimum = value_definition.get("minimumValue")
        maximum = value_definition.get("maximumValue")
        if minimum is not None and value < int(minimum):
            return None
        if maximum is not None and value > int(maximum):
            return None
        return {"kind": "integer", "value": value}
    if value_type == STRING_VALUE:
        if not desired.strip() or re.search(r"<[^>]+>|\b(your|organization|tenant-specific)\b", desired, re.I):
            return None
        minimum = value_definition.get("minimumLength")
        maximum = value_definition.get("maximumLength")
        if minimum is not None and len(desired) < int(minimum):
            return None
        if maximum is not None and len(desired) > int(maximum):
            return None
        return {"kind": "string", "value": desired}
    return None


def leaf_value(
    definition: dict[str, Any], desired: str
) -> tuple[dict[str, Any] | None, dict[str, Any] | None, str | None]:
    definition_type = definition.get("@odata.type")
    if definition_type == CHOICE:
        selected = exact_option(definition, desired)
        if not selected:
            return None, None, "choice-value-not-exact"
        if required_child_ids(definition, selected):
            return None, None, "choice-has-required-children"
        return {"kind": "choice", "optionId": selected["itemId"]}, selected, None
    if definition_type == SIMPLE:
        value = simple_value(definition, desired)
        if value is None:
            return None, None, "simple-value-not-exact"
        return value, None, None
    return None, None, "unsupported-definition-type"


def wrap_dependencies(
    child_node: dict[str, Any],
    definition: dict[str, Any],
    selected_option: dict[str, Any] | None,
    by_id: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any] | None, str | None]:
    current_node = child_node
    current_definition = definition
    current_option = selected_option
    seen = {str(definition["id"])}
    while True:
        dependencies = definition_dependencies(current_definition, current_option)
        if not dependencies:
            return current_node, None
        if len(dependencies) != 1:
            return None, "ambiguous-parent-dependency"
        dependency = dependencies[0]
        parent_id = str(dependency["parentSettingId"])
        if parent_id in seen or parent_id not in by_id:
            return None, "invalid-parent-dependency"
        seen.add(parent_id)
        parent = by_id[parent_id]
        parent_type = parent.get("@odata.type")
        if parent_type == GROUP:
            current_child_id = str(current_node.get("resolve", {}).get("definitionId") or "")
            missing_required_children = [
                child_id for child_id in required_child_ids(parent) if child_id != current_child_id
            ]
            if missing_required_children:
                return None, "parent-group-has-unresolved-required-children"
            current_node = node(
                parent,
                {"kind": "group-collection", "items": [{"children": [current_node]}]},
            )
            current_option = None
        elif parent_type == CHOICE:
            option_id = str(dependency.get("dependentOn") or "")
            options = [item for item in parent.get("options") or [] if str(item.get("itemId")) == option_id]
            if len(options) != 1:
                return None, "parent-option-not-exact"
            current_option = options[0]
            current_child_id = str(current_node.get("resolve", {}).get("definitionId") or "")
            missing_required_children = [
                child_id
                for child_id in required_child_ids(parent, current_option)
                if child_id != current_child_id
            ]
            if missing_required_children:
                return None, "parent-choice-has-unresolved-required-children"
            current_node = node(
                parent,
                {"kind": "choice", "optionId": option_id, "children": [current_node]},
            )
        else:
            return None, "unsupported-parent-type"
        current_definition = parent


def direct_candidate(
    definition: dict[str, Any],
    desired: str,
    remediation: str,
    by_id: dict[str, dict[str, Any]],
) -> tuple[dict[str, Any] | None, str | None]:
    definition_type = definition.get("@odata.type")
    if definition_type == CHOICE:
        selected = exact_option(definition, desired)
        if selected:
            child_ids = required_child_ids(definition, selected)
            if not child_ids:
                value = {"kind": "choice", "optionId": selected["itemId"]}
                return wrap_dependencies(node(definition, value), definition, selected, by_id)
            children: list[dict[str, Any]] = []
            remediation_normalized = normalize(remediation)
            if "check all applications" in remediation_normalized:
                for child_id in child_ids:
                    child_definition = by_id.get(child_id)
                    if not child_definition or child_definition.get("@odata.type") != CHOICE:
                        return None, "all-applications-child-not-choice"
                    child_option = exact_option(child_definition, "True")
                    if not child_option or required_child_ids(child_definition, child_option):
                        return None, "all-applications-true-not-exact"
                    children.append(
                        node(child_definition, {"kind": "choice", "optionId": child_option["itemId"]})
                    )
            else:
                numeric_each = re.search(
                    r"\benabled\s*:\s*(-?\d+)\s+for each application listed\b",
                    remediation,
                    flags=re.IGNORECASE,
                )
                if not numeric_each:
                    return None, "choice-has-required-children"
                child_desired = numeric_each.group(1)
                for child_id in child_ids:
                    child_definition = by_id.get(child_id)
                    if not child_definition:
                        return None, "required-child-missing"
                    child_value, _, error = leaf_value(child_definition, child_desired)
                    if error:
                        return None, f"required-child-{error}"
                    children.append(node(child_definition, child_value))
            value = {"kind": "choice", "optionId": selected["itemId"], "children": children}
            return wrap_dependencies(node(definition, value), definition, selected, by_id)

        if ":" not in desired:
            return None, "choice-value-not-exact"
        parent_label, child_desired = (part.strip() for part in desired.split(":", 1))
        parent_option = exact_option(definition, parent_label)
        if not parent_option:
            return None, "parent-choice-not-exact"
        child_ids = required_child_ids(definition, parent_option)
        if not child_ids:
            return None, "qualified-choice-has-no-required-child"
        children: list[dict[str, Any]] = []
        if len(child_ids) == 1:
            child_definition = by_id.get(child_ids[0])
            if not child_definition:
                return None, "required-child-missing"
            child_value, child_option, error = leaf_value(child_definition, child_desired)
            if error:
                return None, f"required-child-{error}"
            children.append(node(child_definition, child_value))
        elif "check all applications" in normalize(remediation):
            for child_id in child_ids:
                child_definition = by_id.get(child_id)
                if not child_definition or child_definition.get("@odata.type") != CHOICE:
                    return None, "all-applications-child-not-choice"
                child_option = exact_option(child_definition, "True")
                if not child_option or required_child_ids(child_definition, child_option):
                    return None, "all-applications-true-not-exact"
                children.append(
                    node(child_definition, {"kind": "choice", "optionId": child_option["itemId"]})
                )
        else:
            return None, "multiple-required-children"
        value = {"kind": "choice", "optionId": parent_option["itemId"], "children": children}
        return wrap_dependencies(node(definition, value), definition, parent_option, by_id)

    if definition_type == SIMPLE:
        value = simple_value(definition, desired)
        if value is None:
            return None, "simple-value-not-exact"
        return wrap_dependencies(node(definition, value), definition, None, by_id)

    return None, "unsupported-definition-type"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--extraction", type=Path, required=True)
    parser.add_argument("--snapshot", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument(
        "--family",
        choices=("windows10", "windows11", "edge", "office", "macos", "ios"),
        required=True,
    )
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()

    if not args.output.name.endswith(".private-mapping-candidates.json"):
        raise SystemExit("Output must end with .private-mapping-candidates.json")
    if args.output.exists():
        raise SystemExit(f"Output already exists: {args.output}")

    extraction = read_json(args.extraction)
    snapshot = read_json(args.snapshot)
    catalog = read_json(args.catalog)
    extraction_benchmark = extraction.get("benchmark") or {}
    catalog_benchmark = catalog.get("benchmark") or {}
    if extraction_benchmark.get("id") != catalog_benchmark.get("id"):
        raise SystemExit("Extraction and catalog benchmark IDs differ")
    if extraction_benchmark.get("version") != catalog_benchmark.get("version"):
        raise SystemExit("Extraction and catalog benchmark versions differ")
    extraction_ids = [
        str(item.get("recommendationId") or "")
        for item in extraction.get("recommendations") or []
    ]
    catalog_ids = [
        str(item.get("recommendationId") or "")
        for item in catalog.get("recommendations") or []
    ]
    if not extraction_ids or "" in extraction_ids or len(set(extraction_ids)) != len(extraction_ids):
        raise SystemExit("Extraction recommendation IDs are missing or duplicated")
    if not catalog_ids or "" in catalog_ids or len(set(catalog_ids)) != len(catalog_ids):
        raise SystemExit("Catalog recommendation IDs are missing or duplicated")
    if set(extraction_ids) != set(catalog_ids):
        raise SystemExit("Extraction and catalog recommendation sets differ")
    definitions = snapshot.get("definitions") or []
    by_id = {str(item["id"]): item for item in definitions}
    if len(by_id) != len(definitions):
        raise SystemExit("Snapshot contains duplicate definition IDs")
    retrieval_count = (snapshot.get("retrieval") or {}).get("definitionCount")
    if retrieval_count is not None and int(retrieval_count) != len(definitions):
        raise SystemExit("Snapshot retrieval count differs from its definition array")

    by_name: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for definition in definitions:
        by_name[normalize_display_name(definition.get("displayName"))].append(definition)

    already_mapped = {
        str(item["recommendationId"])
        for item in catalog.get("recommendations") or []
        if item.get("mappingStatus") == "mapped"
    }
    records: list[dict[str, Any]] = []
    summary: defaultdict[str, int] = defaultdict(int)

    for recommendation in extraction.get("recommendations") or []:
        recommendation_id = str(recommendation["recommendationId"])
        if recommendation_id in already_mapped:
            status = "already-mapped"
            records.append({"recommendationId": recommendation_id, "status": status})
            summary[status] += 1
            continue
        parsed = parse_title(str(recommendation.get("title") or ""))
        if not parsed:
            status = "title-not-exact"
            records.append({"recommendationId": recommendation_id, "status": status})
            summary[status] += 1
            continue
        setting_name, desired = parsed
        remediation = str(recommendation.get("remediation") or "")
        if normalize(setting_name) not in normalize(remediation):
            status = "remediation-does-not-repeat-setting"
            records.append(
                {
                    "recommendationId": recommendation_id,
                    "status": status,
                    "settingName": setting_name,
                    "desiredValue": desired,
                }
            )
            summary[status] += 1
            continue
        definitions_for_name = [
            item
            for item in by_name.get(normalize(setting_name), [])
            if family_allows(args.family, str(item["id"]))
        ]
        if args.family == "office":
            remediation_normalized = normalize(remediation)
            device_scoped = (
                "microsoft office 2016 machine" in remediation_normalized
                or "administrative templates ms security guide" in remediation_normalized
            )
            definitions_for_name = [
                item
                for item in definitions_for_name
                if str(item["id"]).lower().startswith("device_") == device_scoped
            ]
            product_markers = (
                ("administrative templates ms security guide", ("secguide",)),
                ("microsoft access 2016", ("access16",)),
                ("microsoft excel 2016", ("excel16",)),
                ("microsoft outlook 2016", ("outlk16", "outlook16")),
                ("microsoft powerpoint 2016", ("ppt16",)),
                ("microsoft publisher 2016", ("pub16",)),
                ("microsoft word 2016", ("word16",)),
                ("microsoft office 2016", ("office16",)),
            )
            expected_products = next(
                (products for marker, products in product_markers if marker in remediation_normalized),
                (),
            )
            definitions_for_name = [
                item
                for item in definitions_for_name
                if any(
                    f"_policy_config_{product}" in str(item["id"]).lower()
                    for product in expected_products
                )
            ]
        if args.family == "edge":
            remediation_normalized = normalize(remediation)
            explicitly_recommended = "recommended settings" in remediation_normalized
            definitions_for_name = [
                item
                for item in definitions_for_name
                if str(item["id"]).lower().startswith("device_")
                and ("_recommended" in str(item["id"]).lower()) == explicitly_recommended
            ]
        successful: list[dict[str, Any]] = []
        failures: list[dict[str, str]] = []
        for definition in definitions_for_name:
            candidate_node, error = direct_candidate(definition, desired, remediation, by_id)
            if candidate_node and node_display_names_present(candidate_node):
                successful.append(
                    {
                        "definitionId": definition["id"],
                        "rootDefinitionId": candidate_node["resolve"]["definitionId"],
                        "setting": candidate_node,
                    }
                )
            else:
                if candidate_node and not node_display_names_present(candidate_node):
                    error = "dependency-display-name-empty"
                failures.append({"definitionId": definition["id"], "reason": str(error)})
        if len(successful) == 1:
            status = "exact-candidate"
            record = {
                "recommendationId": recommendation_id,
                "status": status,
                "profiles": recommendation.get("profiles") or [],
                "cisAssessmentMethod": recommendation.get("cisAssessmentMethod"),
                "settingName": setting_name,
                "desiredValue": desired,
                "candidate": successful[0],
            }
        elif len(successful) > 1:
            status = "ambiguous-exact-candidates"
            record = {
                "recommendationId": recommendation_id,
                "status": status,
                "settingName": setting_name,
                "desiredValue": desired,
                "candidates": successful,
            }
        elif definitions_for_name:
            status = "definition-found-value-unresolved"
            record = {
                "recommendationId": recommendation_id,
                "status": status,
                "settingName": setting_name,
                "desiredValue": desired,
                "failures": failures,
            }
        else:
            status = "definition-not-exact"
            record = {
                "recommendationId": recommendation_id,
                "status": status,
                "settingName": setting_name,
                "desiredValue": desired,
            }
        records.append(record)
        summary[status] += 1

    output = {
        "schemaVersion": "1.0",
        "tool": {"name": "New-CISExactMappingCandidates.py", "version": "0.1.0"},
        "mappingChangesMade": False,
        "benchmark": extraction.get("benchmark"),
        "family": args.family,
        "source": {
            "extractionSha256": sha256_file(args.extraction),
            "settingsCatalogSnapshotSha256": sha256_file(args.snapshot),
            "mappingCatalogSha256": sha256_file(args.catalog),
        },
        "summary": dict(sorted(summary.items())),
        "recommendations": records,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(output, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(output["summary"], indent=2))
    print(f"Wrote private exact-mapping worklist: {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
