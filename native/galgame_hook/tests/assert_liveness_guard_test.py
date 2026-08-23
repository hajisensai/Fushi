#!/usr/bin/env python3
"""Every native test must keep its assertions alive under --config Release.

MSVC defines NDEBUG in Release, which compiles bare `assert(...)` out entirely.
CI builds these tests with `--config Release`, so a test file without
`#undef NDEBUG` is green no matter what it claims to check -- the same
"zero execution masquerading as a pass" family as BUG-1157.

This guard is a source scan rather than a runtime check on purpose: a runtime
check would itself be an assert, and would therefore be the first thing the
defect deletes.
"""

from __future__ import annotations

import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


class AssertLivenessGuardTest(unittest.TestCase):
    def test_every_native_test_undefines_ndebug_before_including_anything(
        self,
    ) -> None:
        tests = sorted((ROOT / "tests").glob("*_test.cpp"))
        self.assertGreater(len(tests), 20, "test discovery looks broken")
        for path in tests:
            text = path.read_text(encoding="utf-8")
            self.assertIn("#undef NDEBUG", text, path.name)
            # Order matters, but only against the includes that can bind
            # assert(): <cassert>/<assert.h>, and any project header that might
            # pull one of them in. Platform headers such as <windows.h> ahead of
            # the undef are fine, and forcing them below it would be a pointless
            # churn -- so pin the real invariant, not "line 1".
            undef_at = text.index("#undef NDEBUG")
            for marker in ('#include <cassert>', '#include <assert.h>',
                           '#include "'):
                at = text.find(marker)
                if at >= 0:
                    self.assertLess(undef_at, at, f"{path.name}: {marker}")

    def test_new_adapter_scaffolding_emits_the_undef(self) -> None:
        # galhook.py `new` writes a native test file; if its template forgets the
        # undef, every future engine adapter starts life with dead assertions.
        tool = (ROOT / "tools" / "galhook.py").read_text(encoding="utf-8")
        native_test_template = tool.split("native_test.write_text(", 1)[1]
        native_test_template = native_test_template.split(
            "encoding=", 1
        )[0]
        self.assertIn("#undef NDEBUG", native_test_template)


if __name__ == "__main__":
    unittest.main()
