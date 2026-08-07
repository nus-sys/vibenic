#!/usr/bin/env python3
"""Validate that every relative link in the DEPs corpus resolves.

Checks markdown links `[text](target)` in every .md file under the corpus root,
skipping external URLs and pure anchors. A link to a directory must resolve to
a directory; a link with a `#fragment` is checked for the file part only.

Usage:  python3 tools/check_links.py [root]
Exit:   0 if every link resolves, 1 otherwise.
"""
import re
import sys
from pathlib import Path

LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
SKIP_PREFIX = ("http://", "https://", "mailto:", "#")


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else
                Path(__file__).resolve().parent.parent).resolve()

    broken, checked, files = [], 0, 0
    for md in sorted(root.rglob("*.md")):
        if any(part in {"build", ".git", "__pycache__"} for part in md.parts):
            continue
        files += 1
        for lineno, line in enumerate(md.read_text().splitlines(), 1):
            for target in LINK.findall(line):
                target = target.strip()
                if target.startswith(SKIP_PREFIX) or not target:
                    continue
                path_part = target.split("#", 1)[0]
                if not path_part:          # pure anchor
                    continue
                checked += 1
                resolved = (md.parent / path_part).resolve()
                if not resolved.exists():
                    broken.append((md.relative_to(root), lineno, target))

    for f, lineno, target in broken:
        print(f"BROKEN  {f}:{lineno}  ->  {target}")

    print(f"\n{checked} relative links in {files} markdown files; "
          f"{len(broken)} broken")
    return 1 if broken else 0


if __name__ == "__main__":
    sys.exit(main())
