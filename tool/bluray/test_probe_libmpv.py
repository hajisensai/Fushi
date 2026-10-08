"""Packaging graph tests; optional ABI checks against the actual built DLL."""
import os
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from package_libmpv import collect
from namespace_runtime import private_names, rewrite_names


class RuntimeClosureTests(unittest.TestCase):
    def test_private_names_reject_collisions_and_keep_public_abi(self):
        self.assertEqual(private_names(["libmpv-2.dll", "libcrypto-3-x64.dll"]),
                         {"libcrypto-3-x64.dll": "fbdcrypto-3-x64.dll"})
        with self.assertRaises(ValueError):
            private_names(["abcshared.dll", "xyzshared.dll"])
        with self.assertRaises(ValueError):
            private_names(["libcrypto.dll", "fbdcrypto.dll"])

    def test_rewrites_case_insensitive_dynamic_names_and_forwarders(self):
        data = b"libfoo.dll\0LIBFOO.DLL\0libfoo.Function\0" + "LIBFOO.DLL\0".encode("utf-16le")
        result, count = rewrite_names(data, {"libfoo.dll": "fbdfoo.dll"})
        self.assertEqual(len(result), len(data))
        self.assertEqual(count, 4)
        self.assertIn(b"fbdfoo.Function", result)
        self.assertIn("fbdfoo.dll\0".encode("utf-16le"), result)
        self.assertNotIn(b"libfoo", result.lower())

    def test_recursive_imports_and_cycles_are_packaged_once(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            prefix, system = root / "prefix", root / "system"
            (prefix / "bin").mkdir(parents=True)
            system.mkdir()
            mpv, a, b = root / "libmpv-2.dll", prefix / "bin/a.dll", prefix / "bin/b.dll"
            for path in (mpv, a, b, system / "kernel32.dll"):
                path.touch()
            graph = {mpv.name: [a.name, "kernel32.dll"], a.name: [b.name], b.name: [a.name]}
            with patch("package_libmpv.imports", side_effect=lambda path: graph[path.name]):
                self.assertEqual(set(collect(mpv, prefix, system)), {mpv, a, b})

    def test_missing_transitive_dependency_is_a_hard_failure(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch("package_libmpv.imports", return_value=["missing-codec.dll"]):
                with self.assertRaisesRegex(RuntimeError, "missing-codec"):
                    collect(root / "libmpv-2.dll", root, root / "system")


@unittest.skipUnless(os.environ.get("FUSHI_MPV_LIBRARY"), "Set FUSHI_MPV_LIBRARY to test the actual runtime")
class NativeAbiTests(unittest.TestCase):
    def test_menu_state_render_and_truehd_capabilities(self):
        # unittest.mock imports asyncio/ssl. Conda's OpenSSL DLLs then occupy the
        # same Windows module names before libmpv starts. Test the application
        # runtime in a fresh process, not in an unrelated Python SSL host.
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("probe_libmpv.py")),
                                 os.environ["FUSHI_MPV_LIBRARY"]], capture_output=True, text=True,
                                timeout=20, check=True)
        report = json.loads(result.stdout)
        self.assertEqual(report["disc_menu_option_result"], 0)
        self.assertTrue(report["discnav"])
        for field in ("disc_menu_active_property", "disc_navigation_state_json_property",
                      "bluray_protocol", "truehd_decoder", "render_api"):
            self.assertTrue(report[field], field)

    def test_unavailable_state_and_invalid_navigation_are_not_success(self):
        code = """
import sys
sys.path.insert(0, sys.argv[2])
from probe_libmpv import Mpv
m = Mpv(sys.argv[1])
try:
    for name, value in [('config','no'), ('vo','null'), ('ao','null'),
                        ('bluray-java-home','C:/unused-private-jre')]:
        assert m.option(name, value) == 0
    assert m.lib.mpv_initialize(m.handle) == 0
    assert m.get('disc-navigation-state-json')['error'] < 0
    assert m.command('discnav', 'invalid-action') < 0
finally:
    m.close()
"""
        subprocess.run([sys.executable, "-c", code, os.environ["FUSHI_MPV_LIBRARY"],
                        str(Path(__file__).parent)], check=True, timeout=20)


if __name__ == "__main__":
    unittest.main()
