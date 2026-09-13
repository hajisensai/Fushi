#!/usr/bin/env python3
"""Validate the early-loader contract of the Windows x86 locale runtime.

This is a deliberately strict build-output guard, not a general PE loader or a
claim that a DLL is safe to execute. In particular, kernel32 must remain delayed:
the first-stage v140 link can silently turn it into a normal import (LNK4194).
Only Python's standard library is needed. No DLL is loaded or executed.
"""

import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys


class InvalidPE(ValueError):
    """The file does not satisfy the locale runtime's PE contract."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise InvalidPE(message)


class RuntimePE:
    def __init__(self, data: bytes):
        self.data = data
        require(64 <= len(data) <= 64 * 1024 * 1024, "invalid DLL file size")
        require(data[:2] == b"MZ", "missing DOS signature")
        pe = self.unpack("I", 0x3C)[0]
        require(pe >= 64, "PE header overlaps DOS header")
        require(self.read(pe, 4) == b"PE\0\0", "missing PE signature")
        machine, count, _, _, _, optional_size, flags = self.unpack(
            "HHIIIHH", pe + 4
        )
        require(machine == 0x14C, "runtime must be x86")
        require(flags & 0x2002 == 0x2002, "runtime must be an executable DLL")
        require(1 <= count <= 96, "invalid section count")
        optional = pe + 24
        self.read(optional, optional_size)
        require(optional_size >= 96, "truncated optional header")
        require(self.unpack("H", optional)[0] == 0x10B, "runtime must be PE32")
        self.entry = self.unpack("I", optional + 16)[0]
        self.image_base = self.unpack("I", optional + 28)[0]
        self.image_size, self.header_size = self.unpack("II", optional + 56)
        require(0 < self.header_size <= len(data), "invalid header size")
        require(self.header_size <= self.image_size <= 0xFFFFFFFF,
                "invalid image size")
        require(self.image_base + self.image_size <= 0x100000000,
                "image address overflow")
        directory_count = self.unpack("I", optional + 92)[0]
        require(14 <= directory_count <= 16, "missing or invalid data directories")
        require(96 + directory_count * 8 <= optional_size,
                "directories exceed optional header")
        section_table = optional + optional_size
        require(section_table + count * 40 <= self.header_size,
                "section table exceeds headers")
        self.sections = []
        raw_ranges = []
        for index in range(count):
            at = section_table + index * 40
            virtual_size, rva, raw_size, raw = self.unpack("IIII", at + 8)
            characteristics = self.unpack("I", at + 36)[0]
            extent = max(virtual_size, raw_size)
            require(extent > 0 and rva >= self.header_size,
                    "empty section or section overlaps headers")
            require(rva + extent <= self.image_size, "section exceeds image")
            for start, size, _, _, _ in self.sections:
                require(rva + extent <= start or start + size <= rva,
                        "overlapping virtual sections")
            if raw_size:
                require(raw >= self.header_size, "section raw data overlaps headers")
                self.read(raw, raw_size)
                for start, size in raw_ranges:
                    require(raw + raw_size <= start or start + size <= raw,
                            "overlapping raw sections")
                raw_ranges.append((raw, raw_size))
            self.sections.append((rva, extent, raw, raw_size, characteristics))
        self.directories = []
        for index in range(directory_count):
            rva, size = self.unpack("II", optional + 96 + index * 8)
            require(bool(rva) == bool(size), "incomplete data directory")
            if rva:
                if index == 4:  # Certificate directory uses a file offset.
                    self.read(rva, size)
                else:
                    self.offset(rva, size)
            self.directories.append((rva, size))
        self.executable(self.entry)

    def read(self, offset: int, size: int) -> bytes:
        require(offset >= 0 and size >= 0 and offset + size <= len(self.data),
                "file range out of bounds")
        return self.data[offset:offset + size]

    def unpack(self, fmt: str, offset: int) -> tuple:
        return struct.unpack("<" + fmt, self.read(offset, struct.calcsize("<" + fmt)))

    def offset(self, rva: int, size: int) -> int:
        require(rva > 0 and size > 0 and rva + size <= self.image_size,
                "RVA range out of bounds")
        if rva + size <= self.header_size:
            self.read(rva, size)
            return rva
        for start, _, raw, raw_size, _ in self.sections:
            if start <= rva and rva + size <= start + raw_size:
                return raw + rva - start
        raise InvalidPE("RVA is not backed by contiguous file data")

    def words(self, rva: int, count: int, width: int = 4) -> tuple:
        require(0 < count <= 65536, "invalid table count")
        return self.unpack(("I" if width == 4 else "H") * count,
                           self.offset(rva, count * width))

    def string(self, rva: int) -> str:
        # Require the terminator to remain in the same backed RVA range.
        at = self.offset(rva, 1)
        end = self.data.find(b"\0", at, min(at + 4096, len(self.data)))
        require(end > at, "empty or unterminated PE string")
        self.offset(rva, end - at + 1)
        value = self.data[at:end]
        require(all(32 <= c < 127 for c in value), "non-ASCII PE string")
        return value.decode("ascii")

    def executable(self, rva: int) -> None:
        self.offset(rva, 1)
        require(any(start <= rva < start + raw_size and flags & 0x20000000
                    for start, _, _, raw_size, flags in self.sections),
                "entry/export/thunk is not executable code")

    def descriptors(self, directory: int, width: int) -> list:
        rva, size = self.directories[directory]
        require(rva and size >= width * 2 and size % width == 0,
                "missing or malformed descriptor directory")
        require(size // width <= 65, "too many import descriptors")
        result = []
        for offset in range(0, size, width):
            values = self.words(rva + offset, width // 4)
            if not any(values):
                require(result, "empty descriptor directory")
                tail = self.read(self.offset(rva + offset, size - offset),
                                 size - offset)
                require(not any(tail), "nonzero descriptors after terminator")
                return result
            result.append(values)
        raise InvalidPE("descriptor directory has no terminator")

    def thunks(self, lookup: int, iat: int, delayed: bool) -> int:
        require(lookup and iat and lookup % 4 == 0 and iat % 4 == 0,
                "missing or unaligned import thunk table")
        for index in range(4096):
            value = self.words(lookup + index * 4, 1)[0]
            target = self.words(iat + index * 4, 1)[0]
            if value == 0:
                require(index > 0 and target == 0, "empty or mismatched thunk table")
                return index
            if value & 0x80000000:
                require(value & 0x7FFF0000 == 0, "invalid import ordinal")
            else:
                self.offset(value, 2)  # IMAGE_IMPORT_BY_NAME hint
                self.string(value + 2)
            if delayed:
                require(target >= self.image_base, "invalid delay thunk address")
                self.executable(target - self.image_base)
            else:
                require(value == target, "unexpected prebound import table")
        raise InvalidPE("unterminated or oversized thunk table")

    def imports(self, delayed: bool) -> list:
        names = []
        for fields in self.descriptors(13 if delayed else 1, 32 if delayed else 20):
            if delayed:
                attributes, name, module, iat, lookup, bound, unload, stamp = fields
                require(attributes == 1, "delay descriptor must use RVAs")
                require(module and module % 4 == 0, "invalid delay module handle")
                require(self.words(module, 1)[0] == 0, "preloaded delay module handle")
                require(bound == 0 and unload == 0 and stamp == 0,
                        "unexpected bound/unload delay table")
            else:
                lookup, stamp, chain, name, iat = fields
                require(stamp == 0 and chain == 0, "unexpected bound import descriptor")
            dll = self.string(name).lower()
            require(dll not in names, "duplicate import DLL descriptor")
            names.append(dll)
            self.thunks(lookup, iat, delayed)
        return names

    def exports(self) -> list:
        rva, size = self.directories[0]
        require(rva and size >= 40, "missing export directory")
        fields = self.unpack("IIHHIIIIIII", self.offset(rva, 40))
        _, _, _, _, name, _, function_count, name_count, functions, names, ordinals = fields
        self.string(name)
        require(0 < name_count <= function_count, "invalid export counts")
        addresses = self.words(functions, function_count)
        name_rvas = self.words(names, name_count)
        indices = self.words(ordinals, name_count, 2)
        exported = []
        seen = set()
        for address in addresses:
            require(address != 0, "empty export address")
            if rva <= address < rva + size:
                self.string(address)
            else:
                self.executable(address)
        for name_rva, index in zip(name_rvas, indices):
            name = self.string(name_rva)
            require(name not in seen and index < function_count,
                    "duplicate export name or invalid ordinal")
            seen.add(name)
            exported.append(name)
            if name == "GetFileAttributesA":
                require(not rva <= addresses[index] < rva + size,
                        "GetFileAttributesA must not be forwarded")
        require("GetFileAttributesA" in exported, "missing GetFileAttributesA export")
        return exported


def verify_runtime(data: bytes) -> dict:
    pe = RuntimePE(data)
    normal = pe.imports(False)
    require(normal == ["ntdll.dll"], "normal imports must contain only ntdll.dll")
    delayed = pe.imports(True)
    require(set(delayed) == {"kernel32.dll", "user32.dll", "gdi32.dll", "dbghelp.dll"},
            "delay imports must contain kernel32/user32/gdi32/dbghelp exactly once")
    return {"machine": "x86", "format": "PE32", "entry_rva": hex(pe.entry),
            "imports": normal, "delay_imports": sorted(delayed),
            "exports": sorted(pe.exports()), "sha256": hashlib.sha256(data).hexdigest()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("dll", type=Path)
    args = parser.parse_args()
    try:
        with args.dll.open("rb") as stream:
            result = verify_runtime(stream.read(64 * 1024 * 1024 + 1))
    except (OSError, InvalidPE) as error:
        print(f"locale runtime PE validation failed: {error}", file=sys.stderr)
        return 1
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
