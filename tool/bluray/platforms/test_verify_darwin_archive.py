import io
import plistlib
import struct
import tarfile
import tempfile
import unittest
from pathlib import Path

from verify_darwin_archive import macho_slices, verify_archive


IOS_MARKERS = (b"disc-navigation-state-json\0disc-menu-active\0discnav\0dvd-state\0"
               b"disc-remote-access\0without DefaultDuration\0Deriving missing DTS\0")
# macOS Mpv also carries cdda-seek-sector-offset.patch (tool/cdda, macOS only).
MARKERS = IOS_MARKERS + b"Seek to sector %d, byte %d within the sector.\n\0"


def thin(cpu, dependency="/usr/lib/libSystem.B.dylib", markers=MARKERS):
    dependencies = [dependency] if isinstance(dependency, str) else list(dependency)
    commands = b""
    for item in dependencies:
        name = item.encode() + b"\0"
        size = (24 + len(name) + 7) & ~7
        command = struct.pack("<6I", 0xC, size, 24, 0, 0, 0) + name
        commands += command + b"\0" * (size - len(command))
    return (struct.pack("<8I", 0xFEEDFACF, cpu, 0, 6, len(dependencies), len(commands), 0, 0)
            + commands + markers)


def universal(slices):
    offset = 8 + len(slices) * 20
    table, body = bytearray(), bytearray()
    for cpu, data in slices:
        table += struct.pack(">5I", cpu, 0, offset, len(data), 0)
        body += data
        offset += len(data)
    return struct.pack(">2I", 0xCAFEBABE, len(slices)) + table + body


UNIFIED_AVCODEC = "@rpath/libavcodec.framework/libavcodec"
SHARED_DVDNAV = "@rpath/libdvdnav.framework/libdvdnav"
CDIO_PARANOIA = "@rpath/Cdio_paranoia.framework/Versions/A/Cdio_paranoia"
CDDA = ("Cdio", "Cdio_cdda", "Cdio_paranoia")
ARM64, X86_64 = 0x0100000C, 0x01000007


def archive_fixture(path, dependency=None, extra_x86=False, extra=(), platform="macos",
                    cdda=None, mpv_markers=None, mpv_links_cdda=True):
    """libmpv archive; Mpv links the unified FFmpeg and shared DVD by default.

    macOS (arm64) also ships the libcdio frameworks and Mpv links libcdio_paranoia;
    iOS has a device (arm64) and a simulator (arm64 + x86_64) library and no cdda.
    """
    macos = platform == "macos"
    cdda = macos if cdda is None else cdda
    if mpv_markers is None:
        mpv_markers = MARKERS if macos else IOS_MARKERS
    libraries = ([("macos-arm64", "", [ARM64])] if macos else
                 [("ios-arm64", "", [ARM64]),
                  ("ios-arm64_x86_64-simulator", "simulator", [ARM64, X86_64])])
    with tarfile.open(path, "w:gz") as archive:
        for framework in ("Mpv", "Bluray", "Placebo", *(CDDA if cdda else ()), *extra):
            root = f"bundle/{framework}.xcframework"
            links_cdda = cdda and mpv_links_cdda
            default = ((UNIFIED_AVCODEC, SHARED_DVDNAV, *((CDIO_PARANOIA,) if links_cdda else ()))
                       if framework == "Mpv" else "/usr/lib/libSystem.B.dylib")
            dep = dependency or default
            markers = mpv_markers if framework == "Mpv" else MARKERS
            available, files = [], {}
            for identifier, variant, cpus in libraries:
                if extra_x86 and X86_64 not in cpus:
                    cpus = [*cpus, X86_64]
                    claimed = ["arm64"]  # the plist keeps claiming arm64 only
                else:
                    claimed = ["x86_64" if cpu == X86_64 else "arm64" for cpu in cpus]
                library = {"LibraryIdentifier": identifier,
                           "LibraryPath": f"{framework}.framework",
                           "SupportedPlatform": platform, "SupportedArchitectures": claimed}
                if variant:
                    library["SupportedPlatformVariant"] = variant
                available.append(library)
                slices = [(cpu, thin(cpu, dep, markers)) for cpu in cpus]
                files[root + f"/{identifier}/{framework}.framework/Versions/A/{framework}"] = \
                    universal(slices)
            files[root + "/Info.plist"] = plistlib.dumps({"AvailableLibraries": available})
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

    def test_rejects_packaged_dvd_libraries(self):
        # tool/dvd: libdvdnav ships once beside the unified FFmpeg, never inside libmpv.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, extra=("libdvdnav",))
            with self.assertRaisesRegex(ValueError, "DVD libraries packaged inside libmpv"):
                verify_archive(path, "macos")

    def test_requires_mpv_to_link_the_shared_dvd_library(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, dependency=UNIFIED_AVCODEC)
            with self.assertRaisesRegex(ValueError, "does not link the shared DVD library"):
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
            self.assertEqual(set(report["frameworks"]),
                             {"Mpv", "Bluray", "Placebo", "Cdio", "Cdio_cdda", "Cdio_paranoia"})
            self.assertFalse(report["device_menu_rendering_tested"])

    def test_macos_requires_libcdio_frameworks(self):
        # tool/cdda: audio CD is macOS only, its libcdio frameworks must ship there.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, cdda=False)
            with self.assertRaisesRegex(ValueError, "Missing required frameworks"):
                verify_archive(path, "macos")

    def test_macos_requires_cdda_seek_patch_in_mpv(self):
        # An Mpv without cdda-seek-sector-offset.patch (or without cdda at all) is rejected.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, mpv_markers=IOS_MARKERS)
            with self.assertRaisesRegex(ValueError, "Seek to sector"):
                verify_archive(path, "macos")

    def test_macos_requires_mpv_to_link_libcdio_paranoia(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            # libcdio frameworks are shipped, but Mpv does not link Cdio_paranoia.
            archive_fixture(path, mpv_links_cdda=False)
            with self.assertRaisesRegex(ValueError, "does not link libcdio_paranoia"):
                verify_archive(path, "macos")

    def test_ios_needs_no_cdda(self):
        # iOS has no optical drive: no libcdio frameworks, no cdda seek marker.
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, platform="ios")
            report = verify_archive(path, "ios")
            self.assertEqual(set(report["frameworks"]), {"Mpv", "Bluray", "Placebo"})

    def test_ios_rejects_packaged_libcdio(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "frameworks.tar.gz"
            archive_fixture(path, platform="ios", cdda=True)
            with self.assertRaisesRegex(ValueError, "audio CD \\(cdda\\) is macOS only"):
                verify_archive(path, "ios")

    def test_rejects_truncated_universal_slice(self):
        data = universal([(0x0100000C, thin(0x0100000C))])
        with self.assertRaisesRegex(ValueError, "exceeds the binary"):
            macho_slices(data[:-8])


if __name__ == "__main__":
    unittest.main()
