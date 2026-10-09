import io
import plistlib
import struct
import tarfile
import tempfile
import unittest
from pathlib import Path

from verify_darwin_archive import macho_slices, verify_archive


MARKERS = b"disc-navigation-state-json\0disc-menu-active\0discnav\0"


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


def archive_fixture(path, dependency="/usr/lib/libSystem.B.dylib", arm_only=False):
    with tarfile.open(path, "w:gz") as archive:
        for framework in ("Mpv", "Bluray", "Placebo", "Avcodec"):
            info = {"AvailableLibraries": [{"LibraryIdentifier": "macos-arm64_x86_64",
                    "LibraryPath": f"{framework}.framework", "SupportedPlatform": "macos",
                    "SupportedArchitectures": ["arm64", "x86_64"]}]}
            root = f"bundle/{framework}.xcframework"
            slices = [(0x0100000C, thin(0x0100000C, dependency))]
            if not arm_only:
                slices.append((0x01000007, thin(0x01000007, dependency)))
            files = {root + "/Info.plist": plistlib.dumps(info),
                     root + f"/macos-arm64_x86_64/{framework}.framework/Versions/A/{framework}": universal(slices)}
            for name, data in files.items():
                member = tarfile.TarInfo(name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))


class DarwinArchiveTest(unittest.TestCase):
    def test_checks_actual_slices_instead_of_trusting_plist(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, arm_only=True)
            with self.assertRaisesRegex(ValueError, "wrong architectures"):
                verify_archive(path, "macos")

    def test_rejects_unbundled_and_build_machine_dependencies(self):
        for dependency in ("@rpath/Missing.framework/Missing", "@rpath/Bluray.framework/wrong",
                           "/nix/store/build/libcodec.dylib"):
            with self.subTest(dependency=dependency), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "frameworks.tar.gz"
                archive_fixture(path, dependency)
                with self.assertRaisesRegex(ValueError, "unbundled dependency"):
                    verify_archive(path, "macos")

    def test_requires_navigation_in_each_cpu_slice(self):
        data = universal([(0x0100000C, thin(0x0100000C, markers=b"")),
                          (0x01000007, thin(0x01000007))])
        with self.assertRaisesRegex(ValueError, "Missing navigation marker"):
            macho_slices(data, (b"discnav",))

    def test_valid_archive_does_not_claim_device_rendering(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path)
            report = verify_archive(path, "macos")
            self.assertEqual(len(report["frameworks"]), 4)
            self.assertFalse(report["device_menu_rendering_tested"])

    def test_rejects_truncated_universal_slice(self):
        data = universal([(0x0100000C, thin(0x0100000C))])
        with self.assertRaisesRegex(ValueError, "exceeds the binary"):
            macho_slices(data[:-8])


if __name__ == "__main__":
    unittest.main()
