from __future__ import annotations

import argparse
from pathlib import Path

from pypdf import PdfWriter
from pypdf.generic import DecodedStreamObject, DictionaryObject, NameObject


PAGES = [
    ["Synthetic Intune Benchmark"],
    [
        "1.1 Ensure synthetic manual assessment with deterministic mapping (Manual)",
        "Profile Applicability:",
        "Level 1",
        "Audit:",
        "Synthetic audit.",
        "Remediation:",
        "Synthetic remediation.",
    ],
    [
        "1.2 Ensure synthetic exact choice (Automated)",
        "Profile Applicability:",
        "Level 1",
        "Audit:",
        "Synthetic audit.",
        "Remediation:",
        "Synthetic remediation.",
    ],
    [
        "1.3 Ensure synthetic organizational value (Automated)",
        "Profile Applicability:",
        "Level 1",
        "Audit:",
        "Synthetic audit.",
        "Remediation:",
        "Synthetic remediation.",
    ],
]


def pdf_escape(value: str) -> str:
    return value.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")


def create_pdf(path: Path) -> None:
    writer = PdfWriter()
    font = DictionaryObject(
        {
            NameObject("/Type"): NameObject("/Font"),
            NameObject("/Subtype"): NameObject("/Type1"),
            NameObject("/BaseFont"): NameObject("/Helvetica"),
        }
    )
    font_ref = writer._add_object(font)
    for lines in PAGES:
        page = writer.add_blank_page(width=612, height=792)
        page[NameObject("/Resources")] = DictionaryObject(
            {NameObject("/Font"): DictionaryObject({NameObject("/F1"): font_ref})}
        )
        commands = ["BT", "/F1 9 Tf", "40 755 Td"]
        for index, line in enumerate(lines):
            if index:
                commands.append("0 -13 Td")
            commands.append(f"({pdf_escape(line)}) Tj")
        commands.append("ET")
        content = DecodedStreamObject()
        content.set_data("\n".join(commands).encode("ascii"))
        page[NameObject("/Contents")] = writer._add_object(content)
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("wb") as stream:
        writer.write(stream)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    create_pdf(args.output)
