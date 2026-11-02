#!/usr/bin/env python
"""Extract the SC-100 skills-measured objectives into a stable, addressable table.

WHY THIS EXISTS
---------------
The MCP server's coverage tools grade "how well does Microsoft Learn cover this exam
objective?" They need the objective statements themselves, plus the functional-group
title each one sits under, because the server prepends that group title to an
objective before embedding it (see _expand_objective_query in mcp/server.py). This
script turns the skills-measured outline into `index/objectives.json`, which is what
the server reads.

It is deterministic on purpose. A coverage grade is only as trustworthy as the label
set it is computed against, and a label set that shifts between runs makes every
coverage number built on it unreproducible. Parsing is also the part that can be
*proved* correct against Microsoft's published counts, so it is gated on them.

WHERE THE INPUT COMES FROM
--------------------------
The default input is `../docs/SC-100-Skills-Measured.md` in this repository: the exam
study guide's objective list, quoted word for word. If Microsoft revises the outline,
update that file (or point --input at your own copy of the study guide's list) and
re-run this script. The parser accepts both heading styles shown in the self-test.

ID SCHEME
---------
`D.G.N` -- domain, functional group, statement ordinal. So `2.3.4` is domain 2,
group 3, fourth statement. The scheme mirrors Microsoft's own published numbering
rather than inventing a parallel one, so an ID can be checked against the study
guide by eye. IDs are positional and therefore stable only against a given version
of the outline; the skills-measured date is recorded in the output so a revision
that renumbers is detectable rather than silent.

GATES
-----
The published blueprint says 4 domains, 14 functional groups, 81 objective
statements. All three are asserted. A parser that silently finds 79 would corrupt
every downstream coverage number while looking like it worked, so a count
mismatch is a hard failure, not a warning.

Usage:
    python tools/extract_objectives.py                       # ../docs in, index/ out
    python tools/extract_objectives.py --input <file.md> --output <dir>
    python tools/extract_objectives.py --self-test
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from _common import INDEX_DIR, TOOLKIT_ROOT, fail, info, ok, step, warn

# The skills-measured page lives in the repository's docs/ folder, one level above
# the toolkit. Resolved from this file, so the default works from any directory.
DEFAULT_INPUT = TOOLKIT_ROOT.parent / "docs" / "SC-100-Skills-Measured.md"

# Published structure of the SC-100 skills-measured outline. These are the
# numbers Microsoft prints; they are the contract this parser must satisfy.
EXPECTED_DOMAINS = 4
EXPECTED_GROUPS = 14
EXPECTED_STATEMENTS = 81

# Two heading styles are accepted, because copies of the outline circulate in both:
#
#     # DOMAIN 2 - Design security operations... (25-30%)
#     ## Domain 2: Design security operations... (25-30%)
#
# The separator may be a hyphen, a colon, or a typographic dash, so it is matched as
# a class written with escapes (U+2010 to U+2015) rather than literal characters.
RE_DOMAIN = re.compile(
    r"^#{1,2}\s+DOMAIN\s+(\d)\s*[-:\N{HYPHEN}-\N{HORIZONTAL BAR}]\s*(.+?)\s*\(([\d\N{EN DASH}\N{EM DASH}%\-]+)\)\s*$",
    re.IGNORECASE,
)

# "## 2.3 Design solutions..." or "### 2.3 Design solutions..."
RE_GROUP = re.compile(r"^#{2,3}\s+(\d)\.(\d+)\s+(.+?)\s*$")

# Any other Markdown heading ENDS the current group. The outline is usually part of a
# larger document: commentary sections such as "## 4. Change log" or "## What changed
# recently" follow the last group, and their bullets must never count as objectives.
# An early version of this parser only stopped at numbered outline headings and
# reported 88 statements instead of 81 on exactly this trap.
RE_ANY_HEADING = re.compile(r"^#{1,6}\s")

# "- Design a solution for ..." -- a statement bullet, not a nested list item.
RE_BULLET = re.compile(r"^-\s+(.+?)\s*$")

# "| **Skills-measured version** | **As of July 28, 2026** ..." or
# "| **Skills measured as of** | **October 21, 2026** |"
RE_SKILLS_DATE = re.compile(r"skills[- ]measured\b.*?\b([A-Z][a-z]+ \d{1,2}, \d{4})", re.IGNORECASE)


def parse_blueprint(text: str) -> dict:
    """Parse the objective-domain markdown into domains -> groups -> statements.

    Bullets are attributed to the most recently seen group heading. Any bullet
    appearing before the first DOMAIN heading is preamble (audience profile,
    Microsoft's caveat) and is deliberately dropped -- those are prose, not
    objectives, and counting them would break the 81 gate.
    """
    domains: dict[int, dict] = {}
    current_domain: int | None = None
    current_group: tuple[int, int] | None = None
    skills_date = None

    for raw in text.splitlines():
        line = raw.rstrip()

        if skills_date is None:
            m = RE_SKILLS_DATE.search(line)
            if m:
                skills_date = m.group(1).strip()

        m = RE_DOMAIN.match(line)
        if m:
            num = int(m.group(1))
            domains[num] = {
                "domain": num,
                "title": m.group(2).strip(),
                "weight": m.group(3).strip(),
                "groups": {},
            }
            current_domain = num
            current_group = None
            continue

        m = RE_GROUP.match(line)
        if m:
            d, g = int(m.group(1)), int(m.group(2))
            if current_domain is None:
                # A group heading before any domain heading means the document
                # shape changed. Guessing an owner here would silently misfile
                # every statement beneath it.
                fail(f"Group heading '{d}.{g}' appeared before any DOMAIN heading.",
                     "The blueprint structure changed. Re-check the capture.")
            if d != current_domain:
                fail(f"Group '{d}.{g}' is nested under DOMAIN {current_domain}.",
                     "Group numbering must agree with its enclosing domain.")
            domains[d]["groups"][g] = {
                "group": f"{d}.{g}",
                "title": m.group(3).strip(),
                "statements": [],
            }
            current_group = (d, g)
            continue

        # Any other heading ends the current group and collects no bullets. Without
        # this, everything after "## 4. Change log" or "## What changed recently"
        # is misfiled as objectives. Checked AFTER the group pattern on purpose, so
        # a real group heading is never mistaken for commentary.
        if RE_ANY_HEADING.match(line):
            current_group = None
            continue

        # Only bullets inside a group are objective statements.
        if current_group is None:
            continue
        m = RE_BULLET.match(line)
        if m:
            d, g = current_group
            stmts = domains[d]["groups"][g]["statements"]
            stmts.append({
                "objective_id": f"{d}.{g}.{len(stmts) + 1}",
                "text": m.group(1).strip(),
            })

    return {"domains": domains, "skills_measured_version": skills_date}


def flatten(parsed: dict) -> list[dict]:
    """Flatten to one row per objective statement, carrying its ancestry.

    Downstream consumers (the MCP server's coverage tools) want a flat addressable
    list; the nesting only exists to derive the IDs.
    """
    rows: list[dict] = []
    for d in sorted(parsed["domains"]):
        dom = parsed["domains"][d]
        for g in sorted(dom["groups"]):
            grp = dom["groups"][g]
            for stmt in grp["statements"]:
                rows.append({
                    "objective_id": stmt["objective_id"],
                    "exam_domain": d,
                    "domain_title": dom["title"],
                    "domain_weight": dom["weight"],
                    "group_id": grp["group"],
                    "group_title": grp["title"],
                    "text": stmt["text"],
                })
    return rows


def validate(parsed: dict, rows: list[dict]) -> dict:
    """Assert the published counts. A mismatch is fatal, never a warning.

    A parser that finds 79 of 81 statements produces coverage numbers that look
    plausible and are wrong. Silence is the dangerous outcome here.
    """
    n_domains = len(parsed["domains"])
    n_groups = sum(len(d["groups"]) for d in parsed["domains"].values())
    n_stmts = len(rows)

    gates = {
        "domain_count": "PASS" if n_domains == EXPECTED_DOMAINS else "FAIL",
        "group_count": "PASS" if n_groups == EXPECTED_GROUPS else "FAIL",
        "statement_count": "PASS" if n_stmts == EXPECTED_STATEMENTS else "FAIL",
        "ids_unique": "PASS" if len({r["objective_id"] for r in rows}) == n_stmts else "FAIL",
        "all_have_text": "PASS" if all(r["text"] for r in rows) else "FAIL",
    }

    info(f"domains={n_domains} (expect {EXPECTED_DOMAINS})")
    info(f"groups={n_groups} (expect {EXPECTED_GROUPS})")
    info(f"statements={n_stmts} (expect {EXPECTED_STATEMENTS})")

    failed = [k for k, v in gates.items() if v == "FAIL"]
    if failed:
        fail(f"Blueprint gates failed: {', '.join(failed)}",
             "The published outline is 4 domains / 14 groups / 81 statements. "
             "A count mismatch means the input file or the parser drifted -- fix it "
             "before the MCP server's coverage tools consume these IDs.")
    return gates


def self_test() -> int:
    """Exercise the parser on a miniature blueprint with a known shape."""
    step("Objective extractor self-test")
    sample = """
| **Skills-measured version** | **As of July 28, 2026** (only version) |

Some preamble prose.

- A preamble bullet that must NOT be counted.

# DOMAIN 1 - Design things (20-25%)

## 1.1 First group

- Statement one
- Statement two

## 1.2 Second group

- Statement three

# DOMAIN 2 - Design other things (25-30%)

## 2.1 Third group

- Statement four

---

## 4. Change log (commentary, NOT a blueprint group)

- A commentary bullet that must NOT be counted.
- Another commentary bullet.

## 5. Some other trailing section

- And another.
"""
    parsed = parse_blueprint(sample)
    rows = flatten(parsed)

    checks = [
        (len(parsed["domains"]) == 2, f"2 domains (got {len(parsed['domains'])})"),
        (len(rows) == 4, f"4 statements, preamble bullet excluded (got {len(rows)})"),
        # Regression guard: "## 4. Change log" parses as a group without this.
        # The real blueprint reported 88 instead of 81 on exactly this bug.
        (all(not r["group_title"].startswith("Change log") for r in rows),
         "trailing commentary sections excluded"),
        ([r["objective_id"] for r in rows] == ["1.1.1", "1.1.2", "1.2.1", "2.1.1"],
         f"IDs are positional D.G.N (got {[r['objective_id'] for r in rows]})"),
        (rows[2]["group_title"] == "Second group", "group title attached"),
        (rows[3]["exam_domain"] == 2, "domain ancestry attached"),
        (rows[0]["domain_weight"] == "20-25%", "weight captured"),
        (parsed["skills_measured_version"].startswith("July 28, 2026"),
         f"skills date captured (got {parsed['skills_measured_version']!r})"),
    ]

    # The second heading style: "## Domain N: Title (weight)" with "### D.G" groups,
    # a colon separator, and a commentary section with NO number that must still end
    # the last group. This is the shape of docs/SC-100-Skills-Measured.md.
    sample2 = """
| **Skills measured as of** | **October 21, 2026** |

## Where each domain is taught

- A navigation bullet that must NOT be counted.

## Domain 1: Design things (20-25%)

### 1.1 First group

- Statement one
- Statement two

## Domain 2: Design other things (25-30%)

### 2.1 Second group

- Statement three

## What changed recently

### October 21, 2026 (change log)

- A change-log bullet that must NOT be counted.
"""
    parsed2 = parse_blueprint(sample2)
    rows2 = flatten(parsed2)
    checks += [
        (len(parsed2["domains"]) == 2, f"style 2: 2 domains (got {len(parsed2['domains'])})"),
        ([r["objective_id"] for r in rows2] == ["1.1.1", "1.1.2", "2.1.1"],
         f"style 2: unnumbered commentary heading ends the group "
         f"(got {[r['objective_id'] for r in rows2]})"),
        (rows2[0]["domain_title"] == "Design things", "style 2: colon separator parsed"),
        (parsed2["skills_measured_version"] == "October 21, 2026",
         f"style 2: skills date captured (got {parsed2['skills_measured_version']!r})"),
    ]

    passed = True
    for good, label in checks:
        print(f"           {label} [{'pass' if good else 'FAIL'}]")
        passed = passed and good

    if not passed:
        print("    self-test: FAILED")
        return 1
    print("    self-test: ALL PASS")
    ok("objective extractor is sound")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Extract SC-100 skills-measured objectives into a stable ID table.")
    ap.add_argument("--input", default=None,
                    help=f"Skills-measured Markdown file (default: {DEFAULT_INPUT.name} in ../docs)")
    ap.add_argument("--output", help="Directory for objectives.json (default: index/)")
    ap.add_argument("--self-test", action="store_true", help="Run internal tests and exit")
    args = ap.parse_args()

    if args.self_test:
        return self_test()

    src = Path(args.input).expanduser() if args.input else DEFAULT_INPUT
    if not src.is_file():
        fail(f"Not a file: {src}",
             "Pass --input with the path to a Markdown copy of the SC-100 skills-measured list.")

    step(f"Parsing {src.name}")
    parsed = parse_blueprint(src.read_text(encoding="utf-8"))
    rows = flatten(parsed)
    gates = validate(parsed, rows)

    if parsed["skills_measured_version"]:
        info(f"skills-measured version: {parsed['skills_measured_version']}")
    else:
        # Not fatal, but the date is how a revised outline is proven to be a different
        # version rather than the same one reparsed.
        warn("No skills-measured version found. Provenance will be weaker.")

    out_dir = Path(args.output) if args.output else INDEX_DIR
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / "objectives.json"

    payload = {
        "source_file": src.name,
        "skills_measured_version": parsed["skills_measured_version"],
        "counts": {
            "domains": len(parsed["domains"]),
            "groups": sum(len(d["groups"]) for d in parsed["domains"].values()),
            "statements": len(rows),
        },
        "gates": gates,
        "objectives": rows,
    }
    # newline="" for the same reason as chunk_learn.py: platform newline
    # translation would make this file differ byte-for-byte between a Windows
    # and a Linux run despite identical content.
    with out_path.open("w", encoding="utf-8", newline="") as fh:
        fh.write(json.dumps(payload, indent=2) + "\n")

    ok(f"{len(rows)} objectives -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
