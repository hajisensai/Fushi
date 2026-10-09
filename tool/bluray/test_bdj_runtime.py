"""BD-J bundle integrity and installer tests; optional actual JNI smoke test.

Set FUSHI_BDJ_RUNTIME to an installed component and FUSHI_BDJ_DLL to libbluray-4.dll
to also run the private JVM and a generated, unencrypted BD-J title.
"""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import uuid
import zipfile

REPO = Path(__file__).resolve().parents[2]
BUNDLE = REPO / "third_party/media_kit_libs_windows_video/bdj"
SCRIPT = BUNDLE / "bdj_runtime.ps1"
MANIFEST = json.loads((BUNDLE / "manifest.json").read_text(encoding="utf-8-sig"))
POWERSHELL = shutil.which("powershell") or shutil.which("pwsh")


def invoke_script(*args):
    return subprocess.run(
        [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPT),
         "-Bundle", str(BUNDLE), *map(str, args)],
        capture_output=True, text=True, encoding="utf-8", errors="strict", timeout=60,
    )


def make_fixture(root):
    """Empty-app BD-J first-play title: tests JNI, BDJO and AWT startup, no film."""
    bdmv = root / "BDMV"
    (bdmv / "BDJO").mkdir(parents=True)
    be = lambda value: struct.pack(">I", value)
    obj = struct.pack(">IH", 0x80000000, 0xC000) + b"00000\0"
    index = (b"INDX0200" + be(78) + be(0) + bytes(24) + be(34) + bytes(34)
             + be(26) + obj + obj + bytes(2))
    (bdmv / "index.bdmv").write_bytes(index)
    terminal = be(10) + b"*****\x10" + bytes(4)
    cache = be(2) + bytes(2)
    playlists = be(4) + bytes(4)
    apps = be(2) + bytes(2)
    sections = [terminal, cache, playlists, apps, bytes(4), bytes(2)]
    offsets = []
    position = 48
    for section in sections:
        offsets.append(position)
        position += len(section)
    (bdmv / "BDJO/00000.bdjo").write_bytes(
        b"BDJO0200" + b"".join(be(offset) for offset in offsets) + bytes(16)
        + b"".join(sections))


def native_child(runtime, dll, fixture):
    # Called in a fresh process: JVM state and C-runtime environment are process-wide.
    java_home = runtime / MANIFEST["runtime"]["directory"]
    search_handles = [os.add_dll_directory(str(dll.parent))]
    lib = ctypes.CDLL(str(dll))
    lib.bd_init.restype = ctypes.c_void_p
    lib.bd_set_player_setting_str.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_char_p]
    lib.bd_set_player_setting.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_uint]
    lib.bd_open_disc.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_char_p]
    lib.bd_play.argtypes = [ctypes.c_void_p]
    lib.bd_close.argtypes = [ctypes.c_void_p]
    handle = lib.bd_init()
    if not handle:
        raise RuntimeError("bd_init failed")
    try:
        assert lib.bd_set_player_setting_str(handle, 0x202, str(java_home).encode()) == 1
        assert lib.bd_set_player_setting(handle, 0x101, 0) == 1
        assert lib.bd_open_disc(handle, str(fixture).encode(), None) == 1
        assert lib.bd_play(handle) == 1
        time.sleep(2)  # BD-J initialization is asynchronous; parent checks the completion log.
    finally:
        lib.bd_close(handle)
        for search_handle in search_handles:
            search_handle.close()


class BundleTests(unittest.TestCase):
    def test_self_contained_installer_and_developer_wrapper_use_same_contract(self):
        if not POWERSHELL:
            self.skipTest("PowerShell unavailable")
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            standalone = root / "standalone"
            shutil.copytree(BUNDLE, standalone)
            runtime = Path(os.environ["FUSHI_BDJ_RUNTIME"]) if os.environ.get("FUSHI_BDJ_RUNTIME") else root / "not-installed"
            scripts = [standalone / "bdj_runtime.ps1", Path(__file__).with_name("bdj_runtime.ps1")]
            results = []
            for script in scripts:
                result = subprocess.run(
                    [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(script),
                     "-Action", "Probe", "-Root", str(runtime)],
                    capture_output=True, text=True, encoding="utf-8", errors="strict", timeout=30,
                )
                if runtime.exists():
                    self.assertEqual(result.returncode, 0, result.stderr)
                    results.append(json.loads(result.stdout))
                else:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("BD-J component checksum mismatch", result.stderr)
                    results.append(result.returncode)
            self.assertEqual(results[0], results[1])

    def test_every_shipped_binary_matches_manifest(self):
        for artifact in MANIFEST["files"]:
            with self.subTest(artifact=artifact["name"]):
                self.assertEqual(hashlib.sha256((BUNDLE / artifact["name"]).read_bytes()).hexdigest(),
                                 artifact["sha256"])

    def test_main_and_awt_are_separate_java8_compatible_archives(self):
        expected = {
            "libbluray-j2se-1.5.0.jar": "org/videolan/Libbluray.class",
            "libbluray-awt-j2se-1.5.0.jar": "java/awt/BDToolkit.class",
        }
        for name, required in expected.items():
            with zipfile.ZipFile(BUNDLE / name) as archive:
                self.assertIn(required, archive.namelist())
                for entry in archive.namelist():
                    if entry.endswith(".class"):
                        data = archive.read(entry)
                        self.assertEqual(data[:4], b"\xca\xfe\xba\xbe")
                        self.assertLessEqual(struct.unpack(">H", data[6:8])[0], 52, entry)

    def test_corresponding_sources_match_pinned_upstream_archive(self):
        data = (BUNDLE / "source/libbluray-1.5.0.tar.xz").read_bytes()
        self.assertEqual(hashlib.sha256(data).hexdigest(), MANIFEST["libbluray"]["sourceSha256"])

    @unittest.skipUnless(POWERSHELL, "PowerShell unavailable")
    def test_start_signal_blocks_runtime_probe_until_host_releases_it(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            signal = root / "job-attached.signal"
            process = subprocess.Popen(
                [POWERSHELL, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(SCRIPT),
                 "-Bundle", str(BUNDLE), "-Action", "Probe", "-Root", str(root / "missing"),
                 "-StartSignal", str(signal)],
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                text=True, encoding="utf-8", errors="strict",
            )
            try:
                # Without the gate, the missing runtime would immediately fail.
                time.sleep(0.6)
                self.assertIsNone(process.poll())
                signal.write_text("contents are ignored", encoding="utf-8")
                stdout, stderr = process.communicate(timeout=10)
                self.assertNotEqual(process.returncode, 0)
                self.assertIn("checksum mismatch", stderr)
                self.assertEqual(stdout, "")
            finally:
                if process.poll() is None:
                    process.kill()
                    process.communicate(timeout=10)

    @unittest.skipUnless(POWERSHELL, "PowerShell unavailable")
    def test_rejects_corrupt_archive_without_publishing_install(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            archive = root / "bad.zip"
            archive.write_bytes(b"not the pinned runtime")
            result = invoke_script("-Action", "Install", "-Root", root / "installed", "-Archive", archive)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("checksum mismatch", result.stderr)
            self.assertFalse((root / "installed").exists())
            self.assertFalse(any(path.is_dir() for path in root.glob(".bdj-install-*")))
            self.assertEqual(len(list(root.glob(".bdj-install-*.error.log"))), 1)

    @unittest.skipUnless(POWERSHELL, "PowerShell unavailable")
    def test_explicit_stage_failure_cleans_only_its_own_session(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            stage = root / (".bdj-install-" + uuid.uuid4().hex)
            other = root / (".bdj-install-" + uuid.uuid4().hex)
            other.mkdir()
            (other / "keep").write_text("another running install")
            archive = root / "bad.zip"
            archive.write_bytes(b"invalid")
            result = invoke_script("-Action", "Install", "-Root", root / "installed",
                                   "-Archive", archive, "-StagingDirectory", stage)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse(stage.exists())
            self.assertEqual((other / "keep").read_text(), "another running install")

    @unittest.skipUnless(POWERSHELL, "PowerShell unavailable")
    def test_rejects_unsafe_and_nonempty_stages_without_deleting_them(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            candidates = [root / "ordinary-folder", root / (".bdj-install-" + uuid.uuid4().hex),
                          root / "other-parent" / (".bdj-install-" + uuid.uuid4().hex)]
            for stage in candidates:
                with self.subTest(stage=stage):
                    stage.mkdir(parents=True)
                    marker = stage / "keep"
                    marker.write_text("untouched")
                    result = invoke_script("-Action", "Install", "-Root", root / "installed",
                                           "-StagingDirectory", stage)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("StagingDirectory", result.stderr)
                    self.assertEqual(marker.read_text(), "untouched")

    @unittest.skipUnless(POWERSHELL, "PowerShell unavailable")
    def test_existing_partial_install_is_not_replaced(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            marker = root / "keep.txt"
            marker.write_text("in use", encoding="utf-8")
            result = invoke_script("-Action", "Install", "-Root", root)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(marker.read_text(), "in use")

    @unittest.skipUnless(POWERSHELL and os.environ.get("FUSHI_BDJ_RUNTIME"), "installed runtime not configured")
    def test_actual_private_java8_runtime(self):
        result = invoke_script("-Action", "Probe", "-Root", os.environ["FUSHI_BDJ_RUNTIME"])
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertTrue(report["ready"])
        self.assertEqual(Path(report["componentRoot"]), Path(os.environ["FUSHI_BDJ_RUNTIME"]).resolve())
        self.assertIn("BDJ_RUNTIME_OK 1.8.0_504", report["probe"])

    @unittest.skipUnless(POWERSHELL and os.environ.get("FUSHI_BDJ_ARCHIVE"), "offline runtime archive not configured")
    def test_offline_install_atomic_publish_and_utf8_path_roundtrip(self):
        with tempfile.TemporaryDirectory(prefix="fushi-bdj-install-") as temporary:
            parent = Path(temporary) / "中文路径 with spaces"
            stage = parent / (".bdj-install-" + uuid.uuid4().hex)
            root = parent / "installed"
            result = invoke_script("-Action", "Install", "-Root", root,
                                   "-StagingDirectory", stage, "-Archive", os.environ["FUSHI_BDJ_ARCHIVE"])
            self.assertEqual(result.returncode, 0, result.stderr)
            report = json.loads(result.stdout)
            self.assertEqual(Path(report["componentRoot"]), root)
            self.assertEqual(Path(report["javaHome"]).parent, root)
            self.assertTrue(Path(report["jvm"]).is_file())
            self.assertFalse(stage.exists())

    @unittest.skipUnless(os.name == "nt" and os.environ.get("FUSHI_BDJ_RUNTIME")
                         and os.environ.get("FUSHI_BDJ_DLL"), "native BD-J runtime not configured")
    def test_actual_jni_and_bdj_window_startup(self):
        runtime = Path(os.environ["FUSHI_BDJ_RUNTIME"]).resolve()
        dll = Path(os.environ["FUSHI_BDJ_DLL"]).resolve()
        with tempfile.TemporaryDirectory(prefix="fushi-bdj-") as temporary:
            fixture = Path(temporary)
            make_fixture(fixture)
            environment = dict(os.environ, LIBBLURAY_CP=str(runtime / "libbluray-j2se-1.5.0.jar"),
                               BD_DEBUG_MASK="0xFFFFFFFF")
            result = subprocess.run([sys.executable, str(Path(__file__).resolve()), "--native-child",
                                     str(runtime), str(dll), str(fixture)], env=environment,
                                    capture_output=True, text=True, errors="replace", timeout=30)
            log = result.stdout + result.stderr
            self.assertEqual(result.returncode, 0, log)
            self.assertIn("Java JNI version: 1.8", log)
            self.assertIn("Finished initializing and starting xlets.", log)
            self.assertNotIn("loadN() failed", log)
            self.assertNotIn("UnsatisfiedLinkError", log)


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--native-child":
        native_child(*map(Path, sys.argv[2:]))
    else:
        unittest.main()
