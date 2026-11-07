"""Copy Fushi's dictionary popup into web/popup/ (generated, not committed).

The single source is the browser extension (tools/browser-extension): its
nested-popup.html renders a lookup in its own document and talks to the parent
over a MessagePort, which is exactly what the Lens page needs. Copying at build
time keeps one popup renderer for the app, the extension and the Lens.

Usage: python scripts/copy_popup.py
"""

from __future__ import annotations

import os
import re
import shutil
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PLUGIN = os.path.dirname(HERE)
EXTENSION = os.path.normpath(os.path.join(PLUGIN, "..", "browser-extension"))
DEST = os.path.join(PLUGIN, "web", "popup")

# Loaded at runtime by the files nested-popup.html references, not by a tag.
EXTRA = ["vendor/content.css", "vendor/popup.css"]


def referenced_files(html: str) -> list:
    refs = re.findall(r'(?:src|href)="([^"#?]+)"', html)
    return [r for r in refs if not r.startswith(("http:", "https:", "data:"))]


def main() -> int:
    page = os.path.join(EXTENSION, "nested-popup.html")
    if not os.path.isfile(page):
        print(f"browser extension not found at {EXTENSION}", file=sys.stderr)
        return 1
    with open(page, encoding="utf-8") as f:
        files = ["nested-popup.html"] + referenced_files(f.read()) + EXTRA
    if os.path.isdir(DEST):
        shutil.rmtree(DEST)
    for rel in dict.fromkeys(files):
        src = os.path.join(EXTENSION, rel)
        if not os.path.isfile(src):
            print(f"missing {rel}", file=sys.stderr)
            return 1
        dst = os.path.join(DEST, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copyfile(src, dst)
    print(f"copied {len(files)} popup files to {os.path.relpath(DEST, PLUGIN)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
