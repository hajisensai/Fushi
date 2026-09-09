"""Synthetic PE contract tests; no game or third-party binary fixtures."""

import importlib.util
from pathlib import Path
import struct
import unittest


SCRIPT = (Path(__file__).resolve().parents[1] / "third_party" /
          "locale_emulator" / "verify_runtime_pe.py")
SPEC = importlib.util.spec_from_file_location("verify_runtime_pe", SCRIPT)
guard = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(guard)


class Fixture:
    def __init__(self):
        self.data = bytearray(0x2200)
        self.data[:2] = b"MZ"
        self.put(0x3C, 0x80)
        self.data[0x80:0x84] = b"PE\0\0"
        struct.pack_into("<HHIIIHH", self.data, 0x84,
                         0x14C, 1, 0, 0, 0, 224, 0x2102)
        self.optional = 0x98
        self.half(self.optional, 0x10B)
        self.put(self.optional + 16, 0x1000)
        self.put(self.optional + 28, 0x10000000)
        self.put(self.optional + 56, 0x3000, 0x200)
        self.put(self.optional + 92, 16)
        self.section = self.optional + 224
        self.data[self.section:self.section + 8] = b".text\0\0\0"
        self.put(self.section + 8, 0x2000, 0x1000, 0x2000, 0x200)
        self.put(self.section + 36, 0xE0000020)
        self.directory(0, 0x1400, 0x80)
        self.directory(1, 0x1100, 40)
        self.directory(13, 0x1200, 160)
        self.cursor = 0x1600
        self.rput(0x1100, *self.import_descriptor("ntdll.dll", False))
        for index, name in enumerate(("KERNEL32.dll", "USER32.dll", "GDI32.dll", "dbghelp.dll")):
            self.rput(0x1200 + index * 32, *self.import_descriptor(name, True))
        module_name = self.string("LocaleEmulator.dll")
        export_name = self.string("GetFileAttributesA")
        functions, names, ordinals = self.allocate(4), self.allocate(4), self.allocate(2)
        self.rput(functions, 0x1000)
        self.rput(names, export_name)
        struct.pack_into("<IIHHIIIIIII", self.data, self.off(0x1400),
                         0, 0, 0, 0, module_name, 1, 1, 1, functions, names, ordinals)

    @staticmethod
    def off(rva):
        return rva - 0x1000 + 0x200

    def put(self, at, *values):
        struct.pack_into("<" + "I" * len(values), self.data, at, *values)

    def half(self, at, value):
        struct.pack_into("<H", self.data, at, value)

    def rput(self, rva, *values):
        self.put(self.off(rva), *values)

    def directory(self, index, rva, size):
        self.put(self.optional + 96 + index * 8, rva, size)

    def allocate(self, size):
        result = self.cursor
        self.cursor = (self.cursor + size + 3) & ~3
        return result

    def string(self, value):
        content = value.encode("ascii") + b"\0"
        rva = self.allocate(len(content))
        self.data[self.off(rva):self.off(rva) + len(content)] = content
        return rva

    def import_descriptor(self, name, delayed):
        dll_name = self.string(name)
        hint_name = self.allocate(2)
        self.cursor = hint_name + 2
        self.string("SyntheticFunction")
        lookup, iat = self.allocate(8), self.allocate(8)
        self.rput(lookup, hint_name, 0)
        self.rput(iat, 0x10001000 if delayed else hint_name, 0)
        if delayed:
            return 1, dll_name, self.allocate(4), iat, lookup, 0, 0, 0
        return lookup, 0, 0, dll_name, iat


class RuntimePEContractTest(unittest.TestCase):
    def setUp(self):
        self.fixture = Fixture()

    def verify(self):
        return guard.verify_runtime(bytes(self.fixture.data))

    def reject(self):
        with self.assertRaises(guard.InvalidPE):
            self.verify()

    def test_valid_contract(self):
        result = self.verify()
        self.assertEqual(result["imports"], ["ntdll.dll"])
        self.assertEqual(len(result["delay_imports"]), 4)
        self.assertEqual(result["exports"], ["GetFileAttributesA"])

    def test_every_truncation_is_rejected(self):
        data = bytes(self.fixture.data)
        for size in range(len(data)):
            with self.subTest(size=size), self.assertRaises(guard.InvalidPE):
                guard.verify_runtime(data[:size])

    def test_wrong_architecture_and_kind(self):
        for offset, value in ((0x84, 0x8664), (0x96, 0x102), (0x98, 0x20B)):
            with self.subTest(offset=offset):
                self.fixture = Fixture()
                self.fixture.half(offset, value)
                self.reject()

    def test_header_counts_and_ranges(self):
        for offset, value in ((0x3C, 0xFFFFFFF0), (0x3C, 8),
                              (0x98 + 56, 0), (0x98 + 60, 0x100),
                              (0x98 + 92, 13), (0x98 + 92, 17)):
            with self.subTest(offset=offset, value=value):
                self.fixture = Fixture()
                self.fixture.put(offset, value)
                self.reject()
        for count in (0, 97):
            with self.subTest(count=count):
                self.fixture = Fixture()
                self.fixture.half(0x86, count)
                self.reject()

    def test_bad_signatures(self):
        for offset in (0, 0x80):
            with self.subTest(offset=offset):
                self.fixture = Fixture()
                self.fixture.data[offset] = 0
                self.reject()

    def test_bad_entry_points(self):
        for value in (0, 0x100, 0x3000, 0xFFFFFFFF):
            with self.subTest(value=value):
                self.fixture.put(self.fixture.optional + 16, value)
                self.reject()

    def test_non_executable_section(self):
        self.fixture.put(self.fixture.section + 36, 0xC0000040)
        self.reject()

    def test_out_of_bounds_or_incomplete_directories(self):
        for rva, size in ((0, 40), (0x1100, 0), (0x2FF0, 40), (0xFFFFFFF0, 40)):
            with self.subTest(rva=rva, size=size):
                self.fixture.directory(1, rva, size)
                self.reject()

    def test_missing_empty_and_unterminated_descriptor_lists(self):
        for size in (0, 20, 39):
            with self.subTest(size=size):
                self.fixture = Fixture()
                self.fixture.directory(1, 0x1100 if size else 0, size)
                self.reject()
        self.fixture = Fixture()
        self.fixture.rput(0x1100, 0, 0, 0, 0, 0)
        self.reject()

    def test_duplicate_and_post_terminator_descriptors(self):
        for destination in (0x1220, 0x1280):
            with self.subTest(destination=destination):
                self.fixture = Fixture()
                source = self.fixture.off(0x1200)
                target = self.fixture.off(destination)
                self.fixture.data[target:target + 32] = self.fixture.data[source:source + 32]
                self.reject()
        self.fixture = Fixture()
        self.fixture.rput(0x1220, *([0] * 8))
        self.reject()

    def test_kernel32_must_not_be_a_normal_import(self):
        self.fixture.rput(0x1100, *self.fixture.import_descriptor("kernel32.dll", False))
        self.reject()

    def test_delay_set_must_be_exact(self):
        self.fixture.rput(0x1200, *self.fixture.import_descriptor("version.dll", True))
        self.reject()

    def test_empty_delay_directory(self):
        self.fixture.rput(0x1200, *([0] * 8))
        self.reject()

    def test_case_insensitive_duplicate_dll(self):
        self.fixture.rput(0x1220, *self.fixture.import_descriptor("kernel32.DLL", True))
        self.reject()

    def test_delay_descriptors_reject_va_fields_and_missing_tables(self):
        for field, value in ((0, 0), (1, 0), (2, 0), (3, 0), (4, 0), (5, 0x1600)):
            with self.subTest(field=field):
                self.fixture = Fixture()
                self.fixture.rput(0x1200 + field * 4, value)
                self.reject()

    def test_empty_unterminated_and_bad_import_thunks(self):
        for value in (0, 0xFFFFFFFF, 0x80010001, 0x2FFF):
            with self.subTest(value=value):
                self.fixture = Fixture()
                lookup = struct.unpack_from("<I", self.fixture.data, self.fixture.off(0x1100))[0]
                self.fixture.rput(lookup, value)
                self.reject()

    def test_delay_thunk_must_point_to_code(self):
        iat = struct.unpack_from("<I", self.fixture.data, self.fixture.off(0x120C))[0]
        self.fixture.rput(iat, 0x10000100)
        self.reject()

    def test_empty_and_unterminated_dll_names(self):
        for content in (b"\0", b"x" * 16):
            with self.subTest(content=content):
                self.fixture = Fixture()
                self.fixture.rput(0x110C, 0x2FF0)
                at = self.fixture.off(0x2FF0)
                self.fixture.data[at:at + len(content)] = content
                self.reject()

    def test_missing_export_invalid_ordinal_and_forwarded_entry(self):
        for field, value in ((24, 0), (20, 0xFFFFFFFF), (36, 0x2FFF)):
            with self.subTest(field=field):
                self.fixture = Fixture()
                self.fixture.rput(0x1400 + field, value)
                self.reject()
        self.fixture = Fixture()
        functions = struct.unpack_from("<I", self.fixture.data, self.fixture.off(0x141C))[0]
        self.fixture.rput(functions, 0x1450)
        at = self.fixture.off(0x1450)
        self.fixture.data[at:at + 9] = b"ntdll.X\0\0"
        self.reject()

    def test_section_overlaps_and_virtual_only_ranges(self):
        for field, value in ((12, 0x100), (20, 0x100), (16, 0x200)):
            with self.subTest(field=field):
                self.fixture = Fixture()
                self.fixture.put(self.fixture.section + field, value)
                self.reject()

    def test_distinct_sections_cannot_overlap(self):
        for virtual, raw in ((0x2000, 0x2200), (0x3000, 0x1200)):
            with self.subTest(virtual=virtual, raw=raw):
                self.fixture = Fixture()
                self.fixture.data.extend(bytearray(0x1000))
                self.fixture.half(0x86, 2)
                self.fixture.put(self.fixture.optional + 56, 0x4000)
                second = self.fixture.section + 40
                self.fixture.put(second + 8, 0x1000, virtual, 0x1000, raw)
                self.reject()


if __name__ == "__main__":
    unittest.main()
