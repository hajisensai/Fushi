import io
import plistlib
import struct
import tarfile
import tempfile
import unittest
from pathlib import Path

from verify_darwin_archive import macho_slices, verify_archive


MARKERS = (b"disc-navigation-state-json\0disc-menu-active\0discnav\0without DefaultDuration\0"
           b"Deriving missing DTS\0")


def thin(cpu, dependency="/usr/lib/libSystem.B.dylib", markers=MARKERS):
    name = dependency.encode() + b"\0"
    size = (24 + len(name) + 7) & ~7
    command = struct.pack("<6I", 0xC, size, 24, 0, 0, 0) + name
    command += b"\0" * (size - len(command))
    return struct.pack("<8I", 0xFEEDFACF, cpu, 0, 6, 1, size, 0, 0) + command + markers


def universal(slices):
    offset = 8 + len(slices) * 20
    table, body = bytearray(), bytearray()
    for cpu, data in slices:
        table += struct.pack(">5I", cpu, 0, offset, len(data), 0)
        body += data
        offset += len(data)
    return struct.pack(">2I", 0xCAFEBABE, len(slices)) + table + body


UNIFIED_AVCODEC = "@rpath/libavcodec.framework/libavcodec"


def archive_fixture(path, dependency=None, extra_x86=False, extra=()):
    """macOS arm64 libmpv archive; Mpv links the unified FFmpeg by default."""
    with tarfile.open(path, "w:gz") as archive:
        for framework in ("Mpv", "Bluray", "Placebo", *extra):
            info = {"AvailableLibraries": [{"LibraryIdentifier": "macos-arm64",
                    "LibraryPath": f"{framework}.framework", "SupportedPlatform": "macos",
                    "SupportedArchitectures": ["arm64"]}]}
            root = f"bundle/{framework}.xcframework"
            dep = dependency or (UNIFIED_AVCODEC if framework == "Mpv"
                                 else "/usr/lib/libSystem.B.dylib")
            slices = [(0x0100000C, thin(0x0100000C, dep))]
            if extra_x86:
                slices.append((0x01000007, thin(0x01000007, dep)))
            files = {root + "/Info.plist": plistlib.dumps(info),
                     root + f"/macos-arm64/{framework}.framework/Versions/A/{framework}": universal(slices)}
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))


class DarwinArchiveTest(unittest.TestCase):
    def test_checks_actual_slices_instead_of_trusting_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            # The plist claims arm64 only, the binary also carries x86_64.
            archive_fixture(path, extra_x86=True)
            with self.assertRaisesRegex(ValueError, "wrong architectures"):
                verify_archive(path, "macos")

    def test_rejects_packaged_ffmpeg(self):
        # Unified FFmpeg: a private Avcodec inside libmpv is a second FFmpeg.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, extra=("Avcodec",))
            with self.assertRaisesRegex(ValueError, "FFmpeg packaged inside libmpv"):
                verify_archive(path, "macos")

    def test_requires_mpv_to_link_the_unified_ffmpeg(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, dependency="/usr/lib/libSystem.B.dylib")
            with self.assertRaisesRegex(ValueError, "does not link the unified FFmpeg"):
                verify_archive(path, "macos")

    def test_rejects_unbundled_and_build_machine_dependencies(self):
        for dependency in ("@rpath/Missing.framework/Missing", "@rpath/Bluray.framework/wrong",
                           "@rpath/libfoo.framework/libfoo",
                           "/nix/store/build/libcodec.dylib"):
            with self.subTest(dependency=dependency), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "frameworks.tar.gz"
                archive_fixture(path, dependency)
                with self.assertRaisesRegex(ValueError, "unbundled dependency"):
                    verify_archive(path, "macos")

    def test_requires_navigation_in_each_cpu_slice(self):
        data = universal([(0x0100000C, thin(0x0100000C, markers=b"")),
                          (0x01000007, thin(0x01000007))])
        with self.assertRaisesRegex(ValueError, "Missing required marker"):
            macho_slices(data, (b"discnav",))

    def test_requires_lace_timestamp_patch_in_mpv(self):
        # BUG-3499: an Mpv slice without the laced-audio timestamp patch is rejected.
        data = thin(0x0100000C, markers=b"disc-navigation-state-json\0disc-menu-active\0discnav\0")
        with self.assertRaisesRegex(ValueError, "without DefaultDuration"):
            macho_slices(data, (b"discnav", b"without DefaultDuration"))

    def test_requires_recorder_dts_patch_in_mpv(self):
        # BUG-3500: an Mpv slice without the recorder video-DTS patch is rejected.
        data = thin(0x0100000C, markers=b"discnav\0without DefaultDuration\0")
        with self.assertRaisesRegex(ValueError, "Deriving missing DTS"):
            macho_slices(data, (b"discnav", b"without DefaultDuration", b"Deriving missing DTS"))

    def test_valid_archive_does_not_claim_device_rendering(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path)
            report = verify_archive(path, "macos")
            self.assertEqual(len(report["frameworks"]), 3)
            self.assertFalse(report["device_menu_rendering_tested"])

    def test_rejects_truncated_universal_slice(self):
        data = universal([(0x0100000C, thin(0x0100000C))])
        with self.assertRaisesRegex(ValueError, "exceeds the binary"):
            macho_slices(data[:-8])


if __name__ == "__main__":
    unittest.main()
