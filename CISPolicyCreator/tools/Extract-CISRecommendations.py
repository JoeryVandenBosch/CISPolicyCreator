#!/usr/bin/env python3
"""Extract recommendation-shaped blocks from a user-supplied CIS Intune PDF.

This helper is intentionally conservative. It extracts text locally and does NOT map
recommendations to Microsoft Graph. Every recommendation starts as ``unresolved``.

Keep source PDFs and raw extraction JSON private unless the applicable license allows
redistribution.
"""
from __future__ import annotations
import argparse, json, re
from pathlib import Path
from typing import Any
from pypdf import PdfReader

REC_RE = re.compile(r"(?m)^(?P<id>\d+(?:\.\d+){1,6})\s+(?:\([^\n]+\)\s+)?Ensure\s+(?P<title>.+?)(?:\s+\((?:Automated|Manual|Scored|Not Scored)\))?\s*$")


def read_pdf(path: Path) -> tuple[str, int]:
    reader = PdfReader(str(path))
    joined=[]
    for index,page in enumerate(reader.pages,start=1):
        joined.append(f"\n<<<PAGE {index}>>>\n{page.extract_text() or ''}")
    return "".join(joined), len(reader.pages)


def field(block: str, heading: str, next_headings: list[str]) -> str | None:
    alternatives="|".join(re.escape(h) for h in next_headings)
    m=re.search(rf"(?ms)^{re.escape(heading)}:\s*(.+?)(?=^(?:{alternatives}):|^\d+(?:\.\d+){{1,6}}\s+(?:\([^\n]+\)\s+)?Ensure\s+|\Z)",block)
    return m.group(1).strip() if m else None


def extract(text: str) -> list[dict[str, Any]]:
    matches=list(REC_RE.finditer(text)); out=[]
    for i,m in enumerate(matches):
        end=matches[i+1].start() if i+1<len(matches) else len(text)
        block=text[m.start():end]
        if "Profile Applicability:" not in block or ("Remediation:" not in block and "Audit:" not in block):
            continue
        pages=list(re.finditer(r"<<<PAGE (\d+)>>>", text[:m.start()]))
        page=int(pages[-1].group(1)) if pages else None
        title_match=re.search(r"(?ms)^\d+(?:\.\d+){1,6}\s+(?:\([^\n]+\)\s+)?Ensure\s+(.*?)\s+\((?:Automated|Manual|Scored|Not Scored)\)\s*Profile Applicability:",block)
        title=title_match.group(1) if title_match else m.group("title")
        title=re.sub(r"<<<PAGE \d+>>>"," ",title); title=re.sub(r"Page \d+"," ",title); title=" ".join(title.split())
        profile=field(block,"Profile Applicability",["Description","Rationale","Impact","Audit","Remediation","Default Value","References"])
        remediation=field(block,"Remediation",["Default Value","References","CIS Controls","Profile Applicability","Description","Rationale","Impact","Audit"])
        audit=field(block,"Audit",["Remediation","Default Value","References","CIS Controls"])
        default=field(block,"Default Value",["References","CIS Controls","Profile Applicability","Description"])
        out.append({
            "recommendationId":m.group("id"), "title":title, "page":page,
            "profileApplicability":profile, "audit":audit, "remediation":remediation, "defaultValue":default,
            "status":"unresolved", "implementationType":None, "implementation":None,
            "warning":"Extraction only. Do not deploy until the exact Intune/API mapping has been reviewed and marked mapped."
        })
    return out


def main() -> None:
    p=argparse.ArgumentParser(description="Extract candidate recommendations from a locally supplied CIS Intune benchmark PDF.")
    p.add_argument("pdf",type=Path); p.add_argument("-o","--output",type=Path,default=Path("recommendations.raw.json"))
    args=p.parse_args(); text,page_count=read_pdf(args.pdf); recs=extract(text)
    payload={"sourceFile":args.pdf.name,"pageCount":page_count,"recommendationCount":len(recs),"failClosed":True,"recommendations":recs}
    args.output.write_text(json.dumps(payload,indent=2,ensure_ascii=False),encoding="utf-8")
    print(f"Extracted {len(recs)} candidate recommendations to {args.output}; all are unresolved by design.")

if __name__=="__main__": main()
