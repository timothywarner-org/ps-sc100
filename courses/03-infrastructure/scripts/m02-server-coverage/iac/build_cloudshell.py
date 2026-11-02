#!/usr/bin/env python3
"""Rebuild ../Deploy-C3M02ServerEstate.cloudshell.sh from the templates in this folder.

You don't need this to run the lab. The Cloud Shell script next to the PowerShell scripts is
already built. Run this only after you change a template, so the Cloud Shell script carries
your change.

WHY GENERATED
    Cloud Shell has no copy of these files, so the upload has to carry every template inline.
    Hand-maintaining Bicep in two places is how an embedded copy and a local edit drift apart
    without anyone noticing. Here the .bicep and .yaml files are the only source; this script
    embeds them, each in a quoted heredoc so bash expands nothing inside.

USAGE (from the folder that holds Deploy-C3M02ServerEstate.ps1; Python 3.8 or later)
    python iac/build_cloudshell.py          write the .sh
    python iac/build_cloudshell.py --check  exit 1 if the .sh is stale
EXIT
    0 written or in sync   1 --check found drift   2 a template is missing or unsafe to embed
"""
from __future__ import annotations

import sys
from pathlib import Path

# Everything is resolved from this file's own folder, so the script reads and writes only
# inside the lab folder, wherever you unpacked it.
HERE = Path(__file__).resolve().parent
OUT = HERE.parent / "Deploy-C3M02ServerEstate.cloudshell.sh"
TEMPLATE = HERE / "Deploy-C3M02ServerEstate.cloudshell.sh.in"
EMBED = ["main.bicep", "servers.bicep", "archost.bicep", "arc-host-cloud-init.yaml"]
DELIM = "C3M02_TEMPLATE_EOF"


class EmbedError(Exception):
    """A template can't be embedded safely, so nothing is written."""


def render() -> str:
    blocks = []
    for name in EMBED:
        body = (HERE / name).read_text(encoding="utf-8").rstrip("\n")
        if DELIM in body:
            raise EmbedError(f"{name} contains the heredoc delimiter {DELIM}; pick another")
        blocks.append(f"cat > \"$WORK/{name}\" <<'{DELIM}'\n{body}\n{DELIM}")
    text = TEMPLATE.read_text(encoding="utf-8")
    if text.count("@@EMBED@@") != 1:
        raise EmbedError("template must contain exactly one @@EMBED@@ marker")
    return text.replace("@@EMBED@@", "\n\n".join(blocks))


def main() -> int:
    try:
        want = render()
    except FileNotFoundError as e:
        print(f"missing template: {e.filename}")
        return 2
    except EmbedError as e:
        print(f"unsafe to embed: {e}")
        return 2
    if "--check" in sys.argv:
        have = OUT.read_text(encoding="utf-8") if OUT.exists() else ""
        if have != want:
            print(f"STALE  {OUT.name} differs from the iac templates; rerun without --check")
            return 1
        print(f"OK     {OUT.name} matches the iac templates")
        return 0
    # LF line endings even on Windows: bash in Cloud Shell chokes on carriage returns.
    OUT.write_text(want, encoding="utf-8", newline="\n")
    print(f"wrote {OUT.name} ({len(want.splitlines())} lines)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
