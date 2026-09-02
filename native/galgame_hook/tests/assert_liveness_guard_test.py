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
REPO_ROOT = Path(__file__).resolve().parents[3]

# 扫描面不是「本目录」而是「所有会被 MSVC 以 Release 编译的原生测试目录」。
# fushi/windows/runner/tests 里的测试由 fushi/windows/runner/CMakeLists.txt 挂进
# `add_dependencies(${BINARY_NAME} ...)`，`flutter build windows --release` 会
# 直接编译并运行它们——那是与本目录完全同一族的失效面，此前却没有任何守卫覆盖
# （BUG-2057 的 gal_direct_card_geometry_test.cpp 就是从这个缺口漏进去的）。
NATIVE_TEST_DIRS = (
    ROOT / "tests",
    REPO_ROOT / "fushi" / "windows" / "runner" / "tests",
)


class AssertLivenessGuardTest(unittest.TestCase):
    def test_every_native_test_undefines_ndebug_before_including_anything(
        self,
    ) -> None:
        tests = []
        for directory in NATIVE_TEST_DIRS:
            found = sorted(directory.glob("*_test.cpp"))
            # 每个扫描面单独判空：合成一个总数会让某一目录整个消失（改名/搬走）
            # 被另一目录的数量掩盖，守卫就退化成永远绿。
            self.assertGreater(
                len(found), 5, f"test discovery looks broken: {directory}"
            )
            tests.extend(found)
        self.assertGreater(len(tests), 20, "test discovery looks broken")
        for path in tests:
            text = path.read_text(encoding="utf-8")
            self.assertIn("#undef NDEBUG", text, str(path))
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
                    self.assertLess(undef_at, at, f"{path}: {marker}")

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
