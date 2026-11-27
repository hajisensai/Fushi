// BUG-5568: the helpers that turn the bare Dart frames of a Windows hang dump
// into function names (tool/windows_dump_symbolize.dart).
import 'dart:typed_data';

import 'package:test/test.dart';

import '../../tool/windows_dump/windows_dump_lib.dart';

/// Minimal ELF64 LE file with the given section names; the first note section
/// carries [buildId] (hex) as an NT_GNU_BUILD_ID note.
Uint8List _elf(List<String> sectionNames, {String? buildId}) {
  final List<String> names = <String>[
    '',
    '.shstrtab',
    '.note.gnu.build-id',
    ...sectionNames,
  ];
  final BytesBuilder strtab = BytesBuilder();
  final List<int> nameOffsets = <int>[];
  for (final String n in names) {
    nameOffsets.add(strtab.length);
    strtab
      ..add(n.codeUnits)
      ..addByte(0);
  }
  final List<int> idBytes = <int>[
    if (buildId != null)
      for (int i = 0; i < buildId.length; i += 2)
        int.parse(buildId.substring(i, i + 2), radix: 16),
  ];
  final ByteData note = ByteData(12 + 4 + idBytes.length)
    ..setUint32(0, 4, Endian.little)
    ..setUint32(4, idBytes.length, Endian.little)
    ..setUint32(8, 3, Endian.little);
  final Uint8List noteBytes = note.buffer.asUint8List()
    ..setRange(12, 16, 'GNU\u0000'.codeUnits)
    ..setRange(16, 16 + idBytes.length, idBytes);

  const int strOff = 0x40;
  final int noteOff = strOff + strtab.length;
  final int shoff = (noteOff + noteBytes.length + 7) & ~7;
  final ByteData out = ByteData(shoff + names.length * 64);
  final Uint8List bytes = out.buffer.asUint8List();
  bytes.setRange(0, 4, <int>[0x7f, 0x45, 0x4c, 0x46]);
  bytes[4] = 2;
  bytes[5] = 1;
  out
    ..setUint64(0x28, shoff, Endian.little)
    ..setUint16(0x3a, 64, Endian.little)
    ..setUint16(0x3c, names.length, Endian.little)
    ..setUint16(0x3e, 1, Endian.little);
  bytes.setRange(strOff, strOff + strtab.length, strtab.toBytes());
  bytes.setRange(noteOff, noteOff + noteBytes.length, noteBytes);
  for (int i = 0; i < names.length; i++) {
    final int sh = shoff + i * 64;
    out.setUint32(sh, nameOffsets[i], Endian.little);
    if (i == 1) {
      out
        ..setUint32(sh + 4, 3, Endian.little)
        ..setUint64(sh + 0x18, strOff, Endian.little)
        ..setUint64(sh + 0x20, strtab.length, Endian.little);
    } else if (i == 2 && buildId != null) {
      out
        ..setUint32(sh + 4, 7, Endian.little)
        ..setUint64(sh + 0x18, noteOff, Endian.little)
        ..setUint64(sh + 0x20, noteBytes.length, Endian.little);
    }
  }
  return bytes;
}

/// Minidump bytes with one stream of [type] holding [payload].
Uint8List _minidump(int type, String payload) {
  const int dir = 32;
  const int data = dir + 12;
  final ByteData d = ByteData(data + payload.length)
    ..setUint32(0, 0x504d444d, Endian.little)
    ..setUint32(8, 1, Endian.little)
    ..setUint32(12, dir, Endian.little)
    ..setUint32(dir, type, Endian.little)
    ..setUint32(dir + 4, payload.length, Endian.little)
    ..setUint32(dir + 8, data, Endian.little);
  final Uint8List bytes = d.buffer.asUint8List()
    ..setRange(data, data + payload.length, payload.codeUnits);
  return bytes;
}

const String _id = '6822c6102a7a2c3d77fc297b8bf734d1';
const String _line = 'dart_aot base=0x21eec9a0000 span=0x758c068 build_id=$_id';

void main() {
  group('Dart AOT image record', () {
    test('parses the runner line (stream and hang_watchdog.log share it)', () {
      final DartAotImage? image = parseDartAotLine(
        '[2026-11-27 10:31:40] pid=97936 $_line',
      );
      expect(image, isNotNull);
      expect(image!.base, 0x21eec9a0000);
      expect(image.span, 0x758c068);
      expect(image.buildId, _id);
      expect(image.contains(0x21ef3f2966f), isTrue);
      expect(image.contains(0x7ffd91c3adfc), isFalse);
    });

    test('build_id=none means no build-id', () {
      expect(
        parseDartAotLine('dart_aot base=0x10 span=0x20 build_id=none')!.buildId,
        isNull,
      );
    });

    test('reads the user stream out of a minidump', () {
      final DartAotImage? image = readDartAotStream(
        _minidump(kDartAotImageStreamType, _line),
      );
      expect(image?.base, 0x21eec9a0000);
      expect(image?.buildId, _id);
    });

    test(
      'dumps without the stream (pre-BUG-5568) and non-dumps yield null',
      () {
        expect(readDartAotStream(_minidump(7, _line)), isNull);
        expect(readDartAotStream(Uint8List(64)), isNull);
        expect(readDartAotStream(Uint8List(4)), isNull);
      },
    );
  });

  group('CI symbols verification', () {
    final Uint8List shipped = _elf(<String>['.text'], buildId: _id);

    test('matching build-id with symbol and line tables passes', () {
      expect(
        verifyWindowsDartSymbols(
          shippedAppSo: shipped,
          savedSymbols: _elf(<String>[
            '.text',
            '.symtab',
            '.debug_info',
            '.debug_line',
          ], buildId: _id),
        ),
        isEmpty,
      );
    });

    test('a symbols file from another build is rejected', () {
      final List<String> problems = verifyWindowsDartSymbols(
        shippedAppSo: shipped,
        savedSymbols: _elf(<String>[
          '.symtab',
          '.debug_info',
          '.debug_line',
        ], buildId: 'aa' * 16),
      );
      expect(problems.single, contains('build-id mismatch'));
    });

    test('a stripped file passed as symbols is rejected', () {
      final List<String> problems = verifyWindowsDartSymbols(
        shippedAppSo: shipped,
        savedSymbols: shipped,
      );
      expect(problems, hasLength(3));
      expect(problems.join('\n'), contains('.debug_line'));
    });

    test('not an ELF', () {
      expect(
        verifyWindowsDartSymbols(
          shippedAppSo: Uint8List(80),
          savedSymbols: shipped,
        ).single,
        contains('not an ELF64'),
      );
    });
  });

  group('cdb stack annotation', () {
    const DartAotImage image = DartAotImage(
      base: 0x21eec9a0000,
      span: 0x758c068,
      buildId: _id,
    );
    // Lines as cdb prints them for the 10:31 hang dump (BUG-5568).
    final List<String> cdb = <String>[
      '10 00000075`9dcfe0a0 0000021e`f3f2966f     flutter_windows!dart::NativeEntry::BootstrapNativeCallWrapper+0xf5',
      '11 00000075`9dcfe620 0000021e`f3efec0f     0x0000021e`f3f2966f',
      '12 00000075`9dcfe670 0000021e`eff813c2     0x0000021e`f3efec0f',
      '13 00000075`9dcfe6a8 0000021e`eff7e0be     0x0000000a`00000000',
      '14 00000075`9dcfe6d0 0000021e`f0b8cb70     0x0000021e`f3f2966f',
    ];

    test('finds bare frames inside the image only', () {
      final List<RawFrame> frames = findDartFrames(cdb, image);
      expect(frames.map((RawFrame f) => f.lineIndex), <int>[1, 2, 4]);
      expect(frames.first.address, 0x21ef3f2966f);
    });

    test('the trace carries the build-id and ELF virtual addresses', () {
      final String trace = buildDwarfTrace(image, <int>[
        0x21ef3f2966f,
        0x21ef3f2966f,
        0x21ef3efec0f,
      ]);
      expect(trace, contains("build_id: '$_id'"));
      expect(
        trace,
        contains('#00 abs 0000021ef3f2966f virt 000000000758966f ?'),
      );
      expect(
        RegExp('@@fushi-frame').allMatches(trace),
        hasLength(2),
        reason: 'one frame per distinct address',
      );
    });

    test('decoded frames go back onto their cdb lines, inlines included', () {
      final List<RawFrame> frames = findDartFrames(cdb, image);
      final Map<int, List<String>> decoded = parseDecodedTrace(
        '${frameMarker(0x21ef3f2966f)}\n'
        '#0      _StringBase.substring (dart:core-patch/string_patch.dart:401:7)\n'
        '#1      Foo.parse (package:fushi/src/foo.dart:12:3)\n'
        '${frameMarker(0x21ef3efec0f)}\r\n'
        '#2      Bar.run (package:fushi/src/bar.dart:9:5)\r\n',
      );
      final List<String> out = annotateCdbOutput(cdb, frames, decoded);
      expect(out[0], cdb[0]);
      expect(
        out[1],
        endsWith(
          '[dart] _StringBase.substring (dart:core-patch/string_patch.dart:401:7)',
        ),
      );
      expect(
        out[2],
        contains(
          '[dart, inlined into] Foo.parse (package:fushi/src/foo.dart:12:3)',
        ),
      );
      expect(
        out[3],
        endsWith('[dart] Bar.run (package:fushi/src/bar.dart:9:5)'),
      );
      expect(out[4], cdb[3], reason: 'addresses outside the image stay as-is');
      expect(out[5], startsWith(cdb[4]));
      expect(out[5], contains('_StringBase.substring'));
    });

    test('an address the decoder could not resolve is marked', () {
      final List<RawFrame> frames = findDartFrames(cdb, image);
      final List<String> out = annotateCdbOutput(
        cdb,
        frames,
        <int, List<String>>{},
      );
      expect(out[1], endsWith('[dart: not resolved]'));
    });
  });
}
