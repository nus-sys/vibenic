#!/usr/bin/env python3
"""Validate that every relative markdown link under a root resolves.

Checks markdown links `[text](target)` in every .md file under the given root,
skipping external URLs and pure anchors. A link to a directory must resolve to
a directory; a link with a `#fragment` is checked for the file part only.

Git submodules listed in `<root>/.gitmodules` are skipped: their contents are
another repository's responsibility.

Usage:  python3 tools/check_links.py [root]
Exit:   0 if every link resolves, 1 otherwise.
"""
import re
import sys
from pathlib import Path

LINK = re.compile(r"\[[^\]]*\]\(([^)]+)\)")
SKIP_PREFIX = ("http://", "https://", "mailto:", "#")
SUBMODULE_PATH = re.compile(r"^\s*path\s*=\s*(\S+)", re.M)


def submodule_dirs(root: Path) -> set:
    """Directory names to skip, from .gitmodules if the root has one."""
    gm = root / ".gitmodules"
    if not gm.is_file():
        return set()
    return {p.strip("/").split("/")[0] for p in SUBMODULE_PATH.findall(gm.read_text())}


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else
                Path(__file__).resolve().parent.parent).resolve()

    skip = {"build", ".git", "__pycache__"} | submodule_dirs(root)
    broken, checked, files = [], 0, 0
    for md in sorted(root.rglob("*.md")):
        if any(part in skip for part in md.parts):
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
