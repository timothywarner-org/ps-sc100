#!/usr/bin/env python3
"""
run_all.py -- run every self-test in the toolkit and report one verdict.

WHY THIS EXISTS
---------------
Every script here carries its own `--self-test`, which is good for working on that
script and useless for answering the question that matters before you trust an answer
from the knowledge base: is the whole pipeline sound right now?

This is that question, as one command with one exit code.

WHAT IT DOES NOT DO
-------------------
It touches no Azure resource and spends nothing. Every check runs offline, which is
deliberate: a gate you can only run after a five-minute deploy is a gate you stop
running. Checks that need a built index skip cleanly on a fresh clone and run for real
once you have built one.

THIS IS NOT PYTEST
------------------
Each suite is a standalone script with its own exit code, so this runner needs nothing
but Python. Do not point pytest at tests/: there are no test_* functions for it to
collect, so it would report zero tests and look green while checking nothing.

RUN
---
    uv run python tests/run_all.py
    uv run python tests/run_all.py --verbose      # show each suite's full output

EXIT CODES
----------
    0  every suite passed
    1  at least one suite failed, or a suite script is missing
"""

from __future__ import annotations

import argparse
import pathlib
import subprocess
import sys

TOOLKIT_ROOT = pathlib.Path(__file__).resolve().parent.parent

# (label, argv, why-it-matters). Ordered most-critical first, so a scan of the output
# reads worst-news-first rather than chronologically.
SUITES: list[tuple[str, list[str], str]] = [
    (
        "MCP server: tools, citability, scoring",
        [sys.executable, str(TOOLKIT_ROOT / "mcp" / "server.py"), "--self-test"],
        "Does every passage come back with text and a source_url, and is the tool surface right?",
    ),
    (
        "Chunker: domain map and splitter",
        [sys.executable, str(TOOLKIT_ROOT / "tools" / "chunk_learn.py"), "--self-test"],
        "CORRECTNESS. The Learn-path to exam-domain inversion, and near-neighbour splitting.",
    ),
    (
        "Skills-measured objective extractor",
        [sys.executable, str(TOOLKIT_ROOT / "tools" / "extract_objectives.py"), "--self-test"],
        "CORRECTNESS. Objective IDs are the label set every coverage grade is built on.",
    ),
    (
        "Local ingest",
        [sys.executable, str(TOOLKIT_ROOT / "tools" / "ingest_local.py"), "--self-test"],
        "CITABILITY. Does every chunk keep its full text and its source_url?",
    ),
    (
        "Keyword search (stdlib only)",
        [sys.executable, str(TOOLKIT_ROOT / "tools" / "search_keyword.py"), "--self-test"],
        "CITABILITY. Does the zero-install path separate near-identical names and keep every source_url?",
    ),
    (
        "Corpus snapshot classifier (Azure path)",
        [sys.executable, str(TOOLKIT_ROOT / "tools" / "sync_corpus.py"), "--self-test"],
        "SAFETY. Would anything but corpus content be uploaded to your storage account?",
    ),
]


def run(label: str, argv: list[str], why: str, verbose: bool) -> bool:
    print(f"\n{'=' * 72}")
    print(f"  {label}")
    print(f"  {why}")
    print("=" * 72)

    # A missing script is a FAILURE, not a skip. A runner that counts an absent suite as
    # a pass reports green for a test that never ran.
    script = pathlib.Path(argv[1])
    if not script.exists():
        print(f"  [FAIL] {script.name} not found")
        return False

    proc = subprocess.run(argv, cwd=str(TOOLKIT_ROOT), capture_output=True, text=True,
                          encoding="utf-8", errors="replace")
    output = (proc.stdout or "") + (proc.stderr or "")
    # Chroma's deprecation chatter is noise that obscures real failures.
    lines = [line for line in output.splitlines()
             if "DeprecationWarning" not in line and "does not implement" not in line]

    if verbose or proc.returncode != 0:
        for line in lines:
            print(f"  {line}")
    else:
        for line in lines:
            if any(k in line for k in ("pass", "FAIL", "ALL PASS", "skip", "failures")):
                print(f"  {line}")

    passed = proc.returncode == 0
    print(f"\n  ---> {'PASS' if passed else 'FAIL'} (exit {proc.returncode})")
    return passed


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--verbose", "-v", action="store_true", help="Show each suite's full output.")
    args = ap.parse_args()

    print("=" * 72)
    print("  SC-100 STUDY TOOLKIT -- FULL SELF-TEST")
    print("  Offline. No Azure calls, no cost.")
    print("=" * 72)

    results: list[tuple[str, bool]] = []
    for label, argv, why in SUITES:
        results.append((label, run(label, argv, why, args.verbose)))

    print("\n" + "=" * 72)
    print("  SUMMARY")
    print("=" * 72)
    for label, passed in results:
        print(f"  {'PASS' if passed else 'FAIL'}  {label}")

    failed = [label for label, passed in results if not passed]
    print()
    if failed:
        print(f"  {len(failed)} of {len(results)} suites FAILED.")
        print("  Fix these before you trust answers from the knowledge base.")
        print("=" * 72)
        return 1

    print(f"  All {len(results)} suites passed.")
    print()
    print("  Every passage stays citable, the domain inversion is applied, and the")
    print("  MCP tool surface matches the docs.")
    print("=" * 72)
    return 0


if __name__ == "__main__":
    sys.exit(main())
