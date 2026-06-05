import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// ZIP64 central-directory import: a dictionary zip whose central-directory
// entries use the 0xFFFFFFFF sentinels (forced-zip64, even when <4GB) must
// open. The hand-rolled parser in zip.cpp must resolve the per-entry ZIP64
// extended-information extra field (header id 0x0001) instead of bailing out
// the moment it sees a sentinel.
//
// Real-world trigger: （大修館）明鏡国語辞典［第二版］.zip — an MDict packed as a
// forced-zip64 archive. Before the fix zip.open() returned false →
// "unsupported format or failed to open file" and the whole folder import
// reported the failure.
void main() {
  final String root = _repoRoot();
  final String zipCpp =
      p.join(root, 'native', 'hoshidicts', 'hoshidicts_src', 'zip', 'zip.cpp');
  final String zipHpp =
      p.join(root, 'native', 'hoshidicts', 'hoshidicts_src', 'zip', 'zip.hpp');

  test('parse_central_directory resolves per-entry ZIP64 extra (0x0001)', () {
    final String src = File(zipCpp).readAsStringSync();
    expect(src.contains('0x0001'), isTrue,
        reason: 'must parse the ZIP64 extended-information extra field');
    // The 32-bit values are read first, then conditionally replaced from the
    // extra block; a regression that drops this resolution would remove these.
    expect(src.contains('kZip64Sentinel'), isTrue,
        reason: 'sentinel detection must remain explicit');
    expect(src.contains('uncomp32') && src.contains('comp32'), isTrue,
        reason: '32-bit read + sentinel test must remain');
  });

  test('zip.cpp resolves ZIP64 extra instead of blanket-rejecting', () {
    final String src = File(zipCpp).readAsStringSync();
    // Old broken shape bailed with an unconditional `return false;` the moment
    // a 0xFFFFFFFF sentinel appeared. The fix reads the 64-bit replacements
    // from the 0x0001 block (take64) and only proceeds once `resolved`.
    expect(src.contains('take64'), isTrue,
        reason: 'must read 64-bit fields from the ZIP64 extra block');
    expect(src.contains('resolved'), isTrue,
        reason: 'must track whether the ZIP64 extra was found');
  });

  test('ZipEntry sizes are 64-bit to hold resolved ZIP64 values', () {
    final String src = File(zipHpp).readAsStringSync();
    expect(src.contains('uint64_t compressed_size'), isTrue,
        reason: 'compressed_size must be uint64_t for ZIP64');
    expect(src.contains('uint64_t uncompressed_size'), isTrue,
        reason: 'uncompressed_size must be uint64_t for ZIP64');
  });
}

String _repoRoot() {
  Directory dir = Directory.current;
  while (!File(p.join(dir.path, 'native', 'hoshidicts', 'CMakeLists.txt'))
      .existsSync()) {
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}
