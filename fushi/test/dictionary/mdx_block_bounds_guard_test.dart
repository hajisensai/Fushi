import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

// TODO-915: the MDX parser copies key/record blocks straight from the source
// buffer when a block is stored uncompressed (compressed_size ==
// decompressed_size) or is a runt (< 8 bytes). The surrounding code only guards
// `compressed_size` against the buffer, which bounds the *compressed* read. A
// corrupt MDX block whose decompressed_size exceeds the available source bytes
// would then read past `data + size` in those raw-copy branches (OOB read).
//
// Both raw-copy branches must additionally bound the copy by decompressed_size.
// The two paths spell the same bound differently because they walk the file
// differently, and this guard tracks both spellings:
//
//   key blocks    (parse_container_index, cursor-based):
//     if (pos + meta.decompressed_size > size) break;
//     ... block_data.assign(data + pos, ...)
//
//   record blocks (decompress_record_block, random-access by block):
//     if (meta.file_offset + meta.decompressed_size > size) return false;
//     ... out.assign(src, src + meta.decompressed_size)
//
// The record path moved out of the old eager all_records concatenation when MDX
// import became streaming; the bound it needs did not change, only the cursor it
// is expressed against. A regression that drops either bound (re-introducing the
// OOB read) fails here.
void main() {
  final String root = _repoRoot();
  final String mdxCpp = p.join(
      root, 'native', 'fushidicts', 'fushidicts_src', 'mdx', 'mdx_reader.cpp');

  test('mdx_reader bounds both uncompressed-block copies by decompressed_size',
      () {
    final String src = File(mdxCpp).readAsStringSync();

    final RegExp keyGuard = RegExp(
        r'if\s*\(\s*pos\s*\+\s*meta\.decompressed_size\s*>\s*size\s*\)\s*break;');
    final RegExp recordGuard = RegExp(
        r'if\s*\(\s*meta\.file_offset\s*\+\s*meta\.decompressed_size\s*>\s*size\s*\)\s*return\s+false;');

    expect(keyGuard.allMatches(src).length, greaterThanOrEqualTo(1),
        reason: 'the key-block raw copy must bound the source-buffer read by '
            'decompressed_size before assigning');
    expect(recordGuard.allMatches(src).length, greaterThanOrEqualTo(1),
        reason: 'the record-block raw copy must bound the source-buffer read by '
            'decompressed_size before assigning');
  });

  test('mdx_reader key-block else copy is guarded before the assign', () {
    final String src = File(mdxCpp).readAsStringSync();
    final int assignIdx = src.indexOf('block_data.assign(data + pos');
    expect(assignIdx, greaterThanOrEqualTo(0),
        reason: 'key-block raw copy must still exist');
    final int guardIdx = src
        .substring(0, assignIdx)
        .lastIndexOf(RegExp(r'pos\s*\+\s*meta\.decompressed_size\s*>\s*size'));
    expect(guardIdx, greaterThanOrEqualTo(0),
        reason: 'the bound check must precede the block_data.assign copy');
  });

  test('mdx_reader record-block raw copy is guarded before the assign', () {
    final String src = File(mdxCpp).readAsStringSync();
    // Streaming record reader: the raw (stored/runt) branch copies straight out
    // of the mapped file, so it needs the decompressed_size bound just as the
    // old all_records concatenation did.
    final int assignIdx =
        src.indexOf(RegExp(r'out\.assign\(\s*src\s*,\s*src\s*\+\s*meta\.decompressed_size\s*\)'));
    expect(assignIdx, greaterThanOrEqualTo(0),
        reason: 'record-block raw copy must still exist');
    final int guardIdx = src.substring(0, assignIdx).lastIndexOf(
        RegExp(r'meta\.file_offset\s*\+\s*meta\.decompressed_size\s*>\s*size'));
    expect(guardIdx, greaterThanOrEqualTo(0),
        reason: 'the record-block raw copy must be preceded by a '
            'file_offset + decompressed_size > size bound check');
  });

  test('mdx import no longer materialises the whole decompressed record stream',
      () {
    final String src = File(mdxCpp).readAsStringSync();
    // The eager concatenation is what made a 400 MB dictionary need >1 GB of
    // heap and got the app jetsam-killed on iOS mid-import. Streaming replaced
    // it with a sliding window; reintroducing a whole-stream buffer regresses
    // that, so keep the old shape out of the file.
    expect(src.contains('all_records'), isFalse,
        reason: 'record bytes must be streamed a block at a time, not '
            'concatenated into one whole-dictionary buffer');
  });
}

String _repoRoot() {
  Directory dir = Directory.current;
  while (!File(p.join(dir.path, 'native', 'fushidicts', 'CMakeLists.txt'))
      .existsSync()) {
    final Directory parent = dir.parent;
    if (parent.path == dir.path) {
      fail('could not locate repo root from ${Directory.current.path}');
    }
    dir = parent;
  }
  return dir.path;
}
