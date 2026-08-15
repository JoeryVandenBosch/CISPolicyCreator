#!/usr/bin/env python3
"""Deterministically extract recommendation records from a user-supplied CIS Intune PDF.

This is a local extraction step, not a mapper. The output is a private intermediate
artifact and contains benchmark text. Mapping status is deliberately absent.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import re
import sys
from pathlib import Path
from typing import Any


REC_RE = re.compile(
    r"(?ms)^<<<PAGE (?P<page>\d+)>>>\s*"
    r"(?:^Page \d+\s*)?"
    r"^(?P<id>\d+(?:\.\d+){1,6})\s+"
    r"(?:\([^\n]+\)\s+)?Ensure\s+"
    r"(?P<title>.{1,500}?)\s+\((?P<assessment>Automated|Manual)\)\s*"
    r"(?=Profile Applicability:)"
)

HEADINGS = [
    "Profile Applicability",
    "Description",
    "Rationale",
    "Impact",
    "Audit",
    "Remediation",
    "Default Value",
    "References",
    "CIS Controls",
]

MINIMUM_PYTHON = (3, 11)
EXTRACTOR_VERSION = "0.2.2"
REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
REQUIREMENTS_PATH = Path(__file__).with_name("requirements.txt")
EXTRACTION_SCHEMA_PATH = REPOSITORY_ROOT / "schemas" / "extraction.schema.json"


def load_parser_contract(
    requirements_path: Path = REQUIREMENTS_PATH,
    schema_path: Path = EXTRACTION_SCHEMA_PATH,
) -> str:
    """Return the single hash-locked pypdf version agreed by requirements and schema."""
    requirements = requirements_path.read_text(encoding="utf-8")
    logical_requirements = requirements.replace("\\\r\n", " ").replace("\\\n", " ")
    matches = re.findall(
        r"(?im)^\s*pypdf==(?P<version>[^\s]+)(?P<options>[^\r\n]*)$",
        logical_requirements,
    )
    if len(matches) != 1:
        raise ValueError("tools/requirements.txt must contain exactly one pinned pypdf requirement.")
    version, options = matches[0]
    hashes = re.findall(r"--hash=sha256:([a-f0-9]{64})(?=\s|$)", options)
    if not hashes:
        raise ValueError("The pinned pypdf requirement must contain at least one SHA-256 hash.")

    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    schema_version = schema["properties"]["tool"]["properties"]["pdfParserVersion"]["const"]
    if version != schema_version:
        raise ValueError(
            "Pinned pypdf version disagrees with extraction.schema.json: "
            f"requirements={version}; schema={schema_version}."
        )
    return version


def verify_runtime() -> str:
    if sys.version_info[:2] < MINIMUM_PYTHON:
        raise RuntimeError(
            f"Python {MINIMUM_PYTHON[0]}.{MINIMUM_PYTHON[1]} or later is required; "
            f"found {sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}."
        )
    expected = load_parser_contract()
    installed = importlib.metadata.version("pypdf")
    if installed != expected:
        raise RuntimeError(
            "Installed pypdf does not match the repository's hash-pinned parser version: "
            f"installed={installed}; required={expected}. "
            "Install tools/requirements.txt with --require-hashes."
        )
    return installed


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_pdf(path: Path, max_pages: int) -> tuple[str, int]:
    try:
        from pypdf import PdfReader
    except ImportError as exc:
        raise SystemExit(
            "pypdf is required for PDF extraction. Install tools/requirements.txt."
        ) from exc

    reader = PdfReader(str(path))
    if len(reader.pages) > max_pages:
        raise ValueError(
            f"PDF has {len(reader.pages)} pages, exceeding the configured limit of {max_pages}."
        )
    joined = []
    for index, page in enumerate(reader.pages, start=1):
        joined.append(f"\n<<<PAGE {index}>>>\n{page.extract_text() or ''}")
    return "".join(joined), len(reader.pages)


def field(block: str, heading: str) -> str | None:
    alternatives = "|".join(re.escape(item) for item in HEADINGS if item != heading)
    match = re.search(
        rf"(?ms)^{re.escape(heading)}:\s*(.+?)(?=^(?:{alternatives}):|\Z)",
        block,
    )
    return match.group(1).strip() if match else None


def clean_text(value: str) -> str:
    value = re.sub(r"<<<PAGE \d+>>>", " ", value)
    value = re.sub(r"\bPage \d+\b", " ", value)
    return " ".join(value.split())


def parse_profiles(profile_text: str) -> list[str]:
    profiles: list[str] = []
    if re.search(r"(?i)\b(?:level\s*1|L1)\b", profile_text):
        profiles.append("L1")
    if re.search(r"(?i)\b(?:level\s*2|L2)\b", profile_text):
        profiles.append("L2")
    if re.search(r"(?i)\bBL\b|BitLocker", profile_text):
        profiles.append("BL")
    return profiles


def recommendation_key(item: dict[str, Any]) -> tuple[int, ...]:
    return tuple(int(part) for part in item["recommendationId"].split("."))


def extract(text: str) -> list[dict[str, Any]]:
    matches = list(REC_RE.finditer(text))
    recommendations: list[dict[str, Any]] = []
    seen: set[str] = set()
    for index, match in enumerate(matches):
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        block = text[match.start() : end]
        profile = field(block, "Profile Applicability")
        if not profile or ("Remediation:" not in block and "Audit:" not in block):
            continue
        recommendation_id = match.group("id")
        if recommendation_id in seen:
            raise ValueError(f"Duplicate recommendation ID extracted: {recommendation_id}")
        seen.add(recommendation_id)
        page = int(match.group("page"))
        profiles = parse_profiles(profile)
        if not profiles:
            raise ValueError(
                f"Could not normalize Profile Applicability for recommendation {recommendation_id}."
            )
        recommendations.append(
            {
                "recommendationId": recommendation_id,
                "title": clean_text(match.group("title")),
                "page": page,
                "profiles": profiles,
                "cisAssessmentMethod": match.group("assessment"),
                "profileApplicability": clean_text(profile),
                "audit": field(block, "Audit"),
                "remediation": field(block, "Remediation"),
                "defaultValue": field(block, "Default Value"),
            }
        )
    if not recommendations:
        raise ValueError("No CIS Intune recommendations were extracted; refusing empty output.")
    return sorted(recommendations, key=recommendation_key)


def write_json(path: Path, payload: dict[str, Any], force: bool) -> None:
    if path.exists() and not force:
        raise FileExistsError(f"Output already exists: {path}. Pass --force to replace it.")
    path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(payload, indent=2, ensure_ascii=False, sort_keys=True) + "\n"
    path.write_text(rendered, encoding="utf-8", newline="\n")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Extract private recommendation records from a CIS Intune benchmark PDF."
    )
    parser.add_argument("pdf", type=Path)
    parser.add_argument("--benchmark-id", required=True)
    parser.add_argument("--benchmark-version", required=True)
    parser.add_argument("--require-text", action="append", default=[])
    parser.add_argument("--max-file-size-mib", type=int, default=250)
    parser.add_argument("--max-pages", type=int, default=2000)
    parser.add_argument("-o", "--output", type=Path, default=Path("recommendations.raw.json"))
    parser.add_argument("--force", action="store_true")
    args = parser.parse_args()

    try:
        parser_version = verify_runtime()
    except (OSError, KeyError, ValueError, RuntimeError, importlib.metadata.PackageNotFoundError) as exc:
        raise SystemExit(f"Runtime prerequisite check failed: {exc}") from exc

    pdf = args.pdf.resolve(strict=True)
    if args.max_file_size_mib < 1 or args.max_pages < 1:
        raise SystemExit("PDF size and page limits must be positive integers.")
    size_limit = args.max_file_size_mib * 1024 * 1024
    if pdf.stat().st_size > size_limit:
        raise SystemExit(
            f"PDF size exceeds the configured {args.max_file_size_mib} MiB limit."
        )
    text, page_count = read_pdf(pdf, args.max_pages)
    for required in args.require_text:
        if required.casefold() not in text.casefold():
            raise SystemExit(
                f"Source eligibility check failed: required text was not found: {required!r}"
            )
    recommendations = extract(text)
    payload = {
        "schemaVersion": "2.0",
        "tool": {
            "extractorVersion": EXTRACTOR_VERSION,
            "pdfParser": "pypdf",
            "pdfParserVersion": parser_version,
        },
        "benchmark": {
            "id": args.benchmark_id,
            "version": args.benchmark_version,
            "requiredTextMatched": args.require_text,
        },
        "source": {
            "fileName": pdf.name,
            "sha256": sha256_file(pdf),
            "pageCount": page_count,
        },
        "recommendations": recommendations,
    }
    write_json(args.output, payload, args.force)
    print(
        f"Extracted {len(recommendations)} private recommendation records to {args.output}."
    )


if __name__ == "__main__":
    main()
