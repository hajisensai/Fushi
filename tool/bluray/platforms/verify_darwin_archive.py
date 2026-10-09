"""Check xcframework architectures and dylib closure without loading Apple code.

This is artifact validation, not evidence that a menu rendered on a device.
"""

import argparse
import hashlib
import json
import plistlib
import struct
import tarfile
from pathlib import PurePosixPath


CPU_NAMES = {0x01000007: "x86_64", 0x0100000C: "arm64"}
LOAD_DYLIB = {0xC, 0x80000018, 0x8000001F, 0x80000023, 0x20}


def macho_slices(data, required_markers=()):
    """Return actual CPU names and load commands from thin or universal Mach-O."""
    magic = data[:4]
    if magic in (b"\xca\xfe\xba\xbe", b"\xca\xfe\xba\xbf"):
        wide = magic[-1] == 0xBF
        count = struct.unpack_from(">I", data, 4)[0]
        if count > 16:
            raise ValueError("Unreasonable universal Mach-O slice count")
        result = []
        for index in range(count):
            at = 8 + index * (32 if wide else 20)
            offset, size = struct.unpack_from(">QQ" if wide else ">II", data, at + 8)
            if offset + size > len(data):
                raise ValueError("Universal slice exceeds the binary")
            result.extend(macho_slices(data[offset:offset + size], required_markers))
        return result
    if magic not in (b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"):
        raise ValueError("Expected a 64-bit Mach-O library")
    endian = "<" if magic[0] == 0xCF else ">"
    cpu = struct.unpack_from(endian + "I", data, 4)[0]
    if struct.unpack_from(endian + "I", data, 12)[0] != 6:
        raise ValueError("Expected a Mach-O dynamic library")
    commands, command_bytes = struct.unpack_from(endian + "II", data, 16)
    end = 32 + command_bytes
    if end > len(data):
        raise ValueError("Mach-O load commands exceed the binary")
    dependencies = []
    position = 32
    for _ in range(commands):
        command, size = struct.unpack_from(endian + "II", data, position)
        if size < 8 or position + size > end:
            raise ValueError("Invalid Mach-O load command size")
        if command in LOAD_DYLIB:
            name_offset = struct.unpack_from(endian + "I", data, position + 8)[0]
            if not 24 <= name_offset < size:
                raise ValueError("Invalid dylib load command string")
            dependencies.append(data[position + name_offset:position + size]
                                .split(b"\0", 1)[0].decode("utf-8"))
        position += size
    for marker in required_markers:
        if marker not in data:
            raise ValueError(f"Missing navigation marker {marker!r} in CPU {cpu:x}")
    return [{"architecture": CPU_NAMES.get(cpu, f"unknown-{cpu:x}"),
             "dependencies": dependencies}]


def verify_archive(path, platform):
    required = {"Mpv", "Bluray", "Placebo", "Avcodec"}
    expected = {"macos": {"": {"arm64", "x86_64"}},
                "ios": {"": {"arm64"}, "simulator": {"arm64", "x86_64"}}}[platform]
    frameworks = {}
    with tarfile.open(path, "r:gz") as archive:
        members = {member.name: member for member in archive.getmembers()}
        for name, member in members.items():
            if not name.endswith(".xcframework/Info.plist") or not member.isfile():
                continue
            info = plistlib.loads(archive.extractfile(member).read())
            root = PurePosixPath(name).parent
            framework = root.name.removesuffix(".xcframework")
            variants = {}
            for library in info["AvailableLibraries"]:
                if library["SupportedPlatform"] != platform:
                    raise ValueError(f"{framework}: wrong platform")
                variant = library.get("SupportedPlatformVariant", "")
                if variant not in expected or variant in variants:
                    raise ValueError(f"{framework}: unexpected or duplicate variant {variant}")
                folder = root / library["LibraryIdentifier"] / library["LibraryPath"]
                candidates = [folder / framework, folder / "Versions/A" / framework]
                executable = next((members.get(str(candidate)) for candidate in candidates
                                   if members.get(str(candidate)) is not None
                                   and members[str(candidate)].isfile()), None)
                if executable is None:
                    raise ValueError(f"{framework}: no framework executable")
                data = archive.extractfile(executable).read()
                markers = (b"disc-navigation-state-json", b"disc-menu-active", b"discnav") if framework == "Mpv" else ()
                slices = macho_slices(data, markers)
                actual = {item["architecture"] for item in slices}
                if actual != expected[variant] or actual != set(library["SupportedArchitectures"]):
                    raise ValueError(f"{framework}: wrong architectures {actual}")
                if len(slices) != len(actual):
                    raise ValueError(f"{framework}: duplicate Mach-O architecture")
                variants[variant] = slices
            if set(variants) != set(expected):
                raise ValueError(f"{framework}: missing platform variant")
            frameworks[framework] = variants
    if not required <= frameworks.keys():
        raise ValueError(f"Missing required frameworks: {required - frameworks.keys()}")
    for framework, variants in frameworks.items():
        for slices in variants.values():
            for item in slices:
                for dependency in item["dependencies"]:
                    if dependency.startswith(("/usr/lib/", "/System/Library/")):
                        continue
                    if dependency.startswith("@rpath/"):
                        target = dependency.split("/", 2)[1].removesuffix(".framework")
                        valid_paths = {f"@rpath/{target}.framework/{target}",
                                       f"@rpath/{target}.framework/Versions/A/{target}",
                                       f"@rpath/{target}.framework/Versions/Current/{target}"}
                        if target in frameworks and dependency in valid_paths:
                            continue
                    raise ValueError(f"{framework}: unbundled dependency {dependency}")
    checksum = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            checksum.update(chunk)
    digest = checksum.hexdigest()
    return {"sha256": digest, "platform": platform, "frameworks": frameworks,
            "validation": "archive structure, Mach-O CPU slices, dylib closure, navigation markers",
            "device_menu_rendering_tested": False}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive")
    parser.add_argument("--platform", choices=("macos", "ios"), required=True)
    args = parser.parse_args()
    print(json.dumps(verify_archive(args.archive, args.platform), indent=2))


if __name__ == "__main__":
    main()
