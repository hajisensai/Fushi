import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// TODO-915: the MDX parser copies key/record blocks straight from the source
// buffer when a block is stored uncompressed (compressed_size ==
// decompressed_size) or is a runt (< 8 bytes). The surrounding loops only guard
// `pos + compressed_size > size`, which bounds the *compressed* read. A corrupt
// MDX block whose decompressed_size exceeds the available source bytes would
// then read past `data + size` in the else branches (OOB read).
//
// Both else branches must additionally bound the copy by decompressed_size:
//   if (pos + meta.decompressed_size > size) break;
// matching the existing pos+compressed_size break-on-overflow style.
//
// This source-scan guard asserts the bound stays in place; a regression that
// drops it (re-introducing the OOB read) fails here.
void main() {
  final String root = _repoRoot();
  final String mdxCpp = p.join(
      root, 'native', 'hoshidicts', 'hoshidicts_src', 'mdx', 'mdx_reader.cpp');

  test('mdx_reader bounds both uncompressed-block copies by decompressed_size',
      () {
    final String src = File(mdxCpp).readAsStringSync();

    // The exact decompressed_size upper-bound guard must appear, and it must
    // appear for BOTH else branches (key blocks + record blocks).
    final RegExp guard = RegExp(
        r'if\s*\(\s*pos\s*\+\s*meta\.decompressed_size\s*>\s*size\s*\)\s*break;');
    final int hits = guard.allMatches(src).length;
    expect(hits, greaterThanOrEqualTo(2),
        reason:
            'both else branches (key block + record block) must bound the '
            'source-buffer copy by decompressed_size before assigning; '
            'found $hits guard(s)');
  });

  test('mdx_reader key-block else copy is guarded before the assign', () {
    final String src = File(mdxCpp).readAsStringSync();
    final int guardIdx =
        src.indexOf(RegExp(r'if\s*\(\s*pos\s*\+\s*meta\.decompressed_size'));
    final int assignIdx = src.indexOf('block_data.assign(data + pos');
    expect(guardIdx, greaterThanOrEqualTo(0),
        reason: 'decompressed_size bound guard must exist');
    expect(assignIdx, greaterThan(guardIdx),
        reason: 'the bound check must precede the block_data.assign copy');
  });

  test('mdx_reader record-block else copy is guarded before the insert', () {
    final String src = File(mdxCpp).readAsStringSync();
    final int insertIdx = src.indexOf(
        'all_records.insert(all_records.end(), data + pos, data + pos +');
    expect(insertIdx, greaterThanOrEqualTo(0),
        reason: 'record-block raw copy must still exist');
    // The nearest preceding decompressed_size guard must sit just above it.
    final String before = src.substring(0, insertIdx);
    final int lastGuard =
        before.lastIndexOf(RegExp(r'pos\s*\+\s*meta\.decompressed_size\s*>\s*size'));
    expect(lastGuard, greaterThanOrEqualTo(0),
        reason:
            'the record-block raw insert must be preceded by a '
            'pos + decompressed_size > size bound check');
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
