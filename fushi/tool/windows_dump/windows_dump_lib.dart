// BUG-5568: pure helpers behind tool/windows_dump_symbolize.dart.
//
// A Windows hang / crash minidump shows every Dart frame as a bare address
// (app.so is loaded by Dart's own ELF loader, not LoadLibrary, so it has no
// module entry). The runner writes the image's load base and GNU build-id into
// each dump (user stream `kDartAotImageStreamType`, dart_aot_image.h); the CI
// release keeps the matching debugging-info ELF (`windows-dart-symbols-<seq>`).
// These helpers read both and rewrite cdb's stack output so the Dart frames
// become function names with file:line (via `flutter symbolize`).
import 'dart:typed_data';

/// Must match `kDartAotImageStreamType` in fushi/windows/runner/dart_aot_image.h.
const int kDartAotImageStreamType = 0x46555348;

/// Where the Dart AOT image sat in the dumped process.
class DartAotImage {
  const DartAotImage({
    required this.base,
    required this.span,
    required this.buildId,
  });

  final int base;

  /// Bytes from [base] to the end of the last PT_LOAD segment.
  final int span;

  /// Lower-case hex GNU build-id, or null when the image had none.
  final String? buildId;

  bool contains(int address) => address >= base && address < base + span;
}

final RegExp _aotLineRe = RegExp(
  r'dart_aot base=0x([0-9a-f]+) span=0x([0-9a-f]+) build_id=([0-9a-f]+|none)',
);

/// Parses the `dart_aot base=… span=… build_id=…` line (minidump user stream or
/// hang_watchdog.log). Returns null when [text] has no such line.
DartAotImage? parseDartAotLine(String text) {
  final RegExpMatch? m = _aotLineRe.firstMatch(text);
  if (m == null) return null;
  final String id = m[3]!;
  return DartAotImage(
    base: int.parse(m[1]!, radix: 16),
    span: int.parse(m[2]!, radix: 16),
    buildId: id == 'none' ? null : id,
  );
}

/// Reads the runner's Dart AOT user stream from a minidump file's bytes.
/// Returns null for dumps written before BUG-5568 (or by another writer).
DartAotImage? readDartAotStream(Uint8List dump) {
  if (dump.length < 32) return null;
  final ByteData d = ByteData.sublistView(dump);
  // MINIDUMP_HEADER: Signature 'MDMP', Version, NumberOfStreams,
  // StreamDirectoryRva.
  if (d.getUint32(0, Endian.little) != 0x504d444d) return null;
  final int count = d.getUint32(8, Endian.little);
  final int dir = d.getUint32(12, Endian.little);
  for (int i = 0; i < count; i++) {
    final int at = dir + i * 12;
    if (at + 12 > dump.length) return null;
    // MINIDUMP_DIRECTORY: StreamType, DataSize, Rva.
    if (d.getUint32(at, Endian.little) != kDartAotImageStreamType) continue;
    final int size = d.getUint32(at + 4, Endian.little);
    final int rva = d.getUint32(at + 8, Endian.little);
    if (rva + size > dump.length) return null;
    return parseDartAotLine(String.fromCharCodes(dump, rva, rva + size));
  }
  return null;
}

/// Section names and the GNU build-id of an ELF64 little-endian file.
class ElfSummary {
  const ElfSummary({required this.sections, required this.buildId});

  final Set<String> sections;
  final String? buildId;
}

/// Reads section headers (works on the stripped app.so and on the saved
/// debugging-info ELF alike). Returns null when [elf] is not ELF64 LE.
ElfSummary? summarizeElf(Uint8List elf) {
  if (elf.length < 64 ||
      elf[0] != 0x7f ||
      elf[1] != 0x45 ||
      elf[2] != 0x4c ||
      elf[3] != 0x46 ||
      elf[4] != 2 ||
      elf[5] != 1) {
    return null;
  }
  final ByteData d = ByteData.sublistView(elf);
  final int shoff = d.getUint64(0x28, Endian.little);
  final int shentsize = d.getUint16(0x3a, Endian.little);
  final int shnum = d.getUint16(0x3c, Endian.little);
  final int shstrndx = d.getUint16(0x3e, Endian.little);
  if (shentsize < 64 || shoff + shnum * shentsize > elf.length) return null;
  int field64(int section, int off) =>
      d.getUint64(shoff + section * shentsize + off, Endian.little);
  int field32(int section, int off) =>
      d.getUint32(shoff + section * shentsize + off, Endian.little);
  if (shstrndx >= shnum) return null;
  final int strtab = field64(shstrndx, 0x18);
  String nameAt(int off) {
    final int start = strtab + off;
    int end = start;
    while (end < elf.length && elf[end] != 0) {
      end++;
    }
    return String.fromCharCodes(elf, start, end);
  }

  final Set<String> names = <String>{};
  String? buildId;
  for (int i = 0; i < shnum; i++) {
    names.add(nameAt(field32(i, 0)));
    // SHT_NOTE
    if (field32(i, 4) != 7 || buildId != null) continue;
    int note = field64(i, 0x18);
    final int end = note + field64(i, 0x20);
    while (note + 12 <= end && end <= elf.length) {
      final int namesz = d.getUint32(note, Endian.little);
      final int descsz = d.getUint32(note + 4, Endian.little);
      final int type = d.getUint32(note + 8, Endian.little);
      final int desc = note + 12 + ((namesz + 3) & ~3);
      if (desc + descsz > end) break;
      if (type == 3 &&
          namesz == 4 &&
          String.fromCharCodes(elf, note + 12, note + 15) == 'GNU') {
        buildId = elf
            .sublist(desc, desc + descsz)
            .map((int b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        break;
      }
      note = desc + ((descsz + 3) & ~3);
    }
  }
  return ElfSummary(sections: names, buildId: buildId);
}

/// What CI checks after the Windows release build: the saved debugging info
/// belongs to the shipped app.so and actually carries symbols and line tables.
/// Returns the problems found (empty = OK).
List<String> verifyWindowsDartSymbols({
  required Uint8List shippedAppSo,
  required Uint8List savedSymbols,
}) {
  final List<String> problems = <String>[];
  final ElfSummary? app = summarizeElf(shippedAppSo);
  final ElfSummary? sym = summarizeElf(savedSymbols);
  if (app == null) return <String>['shipped app.so is not an ELF64 file'];
  if (sym == null) return <String>['saved symbols file is not an ELF64 file'];
  if (app.buildId == null) problems.add('shipped app.so has no GNU build-id');
  if (app.buildId != sym.buildId) {
    problems.add(
      'build-id mismatch: app.so ${app.buildId} vs symbols ${sym.buildId}',
    );
  }
  for (final String section in <String>[
    '.symtab',
    '.debug_info',
    '.debug_line',
  ]) {
    if (!sym.sections.contains(section)) {
      problems.add('saved symbols file has no $section');
    }
  }
  return problems;
}

/// One frame of cdb `kn` output whose call site is a bare address.
class RawFrame {
  const RawFrame({required this.lineIndex, required this.address});

  /// Index into the cdb output's lines.
  final int lineIndex;
  final int address;
}

// `11 00000075`9dcfe620 0000021e`f3efec0f     0x0000021e`f3f2966f`
final RegExp _rawFrameRe = RegExp(
  r'^\s*[0-9a-f]+\s+[0-9a-f]{8}`[0-9a-f]{8}\s+[0-9a-f]{8}`[0-9a-f]{8}\s+'
  r'0x([0-9a-f]{8})`([0-9a-f]{8})\s*$',
);

/// Bare-address frames in cdb `kn` output that fall inside [image].
List<RawFrame> findDartFrames(List<String> cdbLines, DartAotImage image) {
  final List<RawFrame> frames = <RawFrame>[];
  for (int i = 0; i < cdbLines.length; i++) {
    final RegExpMatch? m = _rawFrameRe.firstMatch(cdbLines[i]);
    if (m == null) continue;
    final int address = int.parse('${m[1]}${m[2]}', radix: 16);
    if (image.contains(address)) {
      frames.add(RawFrame(lineIndex: i, address: address));
    }
  }
  return frames;
}

/// Marker the trace puts before each frame, so the decoder's output can be
/// split back per address (non-trace lines pass through `flutter symbolize`).
String frameMarker(int address) => '@@fushi-frame ${address.toRadixString(16)}';

/// A non-symbolic (DWARF) Dart stack trace in the format `flutter symbolize`
/// decodes: one frame per distinct address, each with its ELF virtual address.
String buildDwarfTrace(DartAotImage image, Iterable<int> addresses) {
  final StringBuffer b = StringBuffer()
    ..writeln('*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***')
    ..writeln('os: windows arch: x64 comp: yes sim: no');
  if (image.buildId != null) b.writeln("build_id: '${image.buildId}'");
  for (final int address in addresses.toSet()) {
    final String abs = address.toRadixString(16).padLeft(16, '0');
    final String virt = (address - image.base)
        .toRadixString(16)
        .padLeft(16, '0');
    b
      ..writeln(frameMarker(address))
      ..writeln('    #00 abs $abs virt $virt ?');
  }
  return b.toString();
}

// `#0      ClassName.method (package:fushi/src/x.dart:12:3)`
final RegExp _decodedFrameRe = RegExp(r'^#\d+\s+(.*)$');

/// Splits `flutter symbolize` output back into the decoded frames for each
/// address (inlined frames first, as the decoder prints them).
Map<int, List<String>> parseDecodedTrace(String decoded) {
  final Map<int, List<String>> out = <int, List<String>>{};
  List<String>? current;
  final RegExp marker = RegExp(r'^@@fushi-frame ([0-9a-f]+)\s*$');
  for (final String line in decoded.split(RegExp(r'\r?\n'))) {
    final RegExpMatch? m = marker.firstMatch(line);
    if (m != null) {
      current = out.putIfAbsent(int.parse(m[1]!, radix: 16), () => <String>[]);
      continue;
    }
    final RegExpMatch? f = _decodedFrameRe.firstMatch(line.trim());
    if (f != null && current != null) current.add(f[1]!.trim());
  }
  return out;
}

/// cdb output with every Dart frame annotated by its decoded function(s).
List<String> annotateCdbOutput(
  List<String> cdbLines,
  List<RawFrame> frames,
  Map<int, List<String>> decoded,
) {
  final Map<int, RawFrame> byLine = <int, RawFrame>{
    for (final RawFrame f in frames) f.lineIndex: f,
  };
  final List<String> out = <String>[];
  for (int i = 0; i < cdbLines.length; i++) {
    final RawFrame? frame = byLine[i];
    if (frame == null) {
      out.add(cdbLines[i]);
      continue;
    }
    final List<String> names = decoded[frame.address] ?? const <String>[];
    if (names.isEmpty) {
      out.add('${cdbLines[i]}  [dart: not resolved]');
      continue;
    }
    out.add('${cdbLines[i]}  [dart] ${names.first}');
    for (final String inlined in names.skip(1)) {
      out.add('${' ' * 46}[dart, inlined into] $inlined');
    }
  }
  return out;
}
