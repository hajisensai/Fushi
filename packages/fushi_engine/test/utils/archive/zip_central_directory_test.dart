import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi_engine/utils/archive/zip_central_directory.dart';
import 'package:test/test.dart';

/// 按 `name → 内容` 打一份内存 zip。
Uint8List _zip(Map<String, List<int>> files) {
  final Archive a = Archive();
  for (final MapEntry<String, List<int>> e in files.entries) {
    a.addFile(ArchiveFile(e.key, e.value.length, e.value));
  }
  return Uint8List.fromList(ZipEncoder().encode(a)!);
}

/// 给 [zip] 追加一段 [commentLength] 字节的 EOCD 注释（改写 EOCD 末两字节的注释长度）。
Uint8List _withComment(Uint8List zip, int commentLength) {
  final Uint8List out = Uint8List(zip.length + commentLength)
    ..setRange(0, zip.length, zip);
  ByteData.sublistView(
    out,
  ).setUint16(zip.length - 2, commentLength, Endian.little);
  for (int i = 0; i < commentLength; i++) {
    out[zip.length + i] = 0x20;
  }
  return out;
}

/// 记录每次区间读的内存 zip。
class _RangeSource {
  _RangeSource(this.bytes);

  final Uint8List bytes;
  final List<(int, int)> reads = <(int, int)>[];

  int get bytesRead => reads.fold(0, (int sum, (int, int) r) => sum + r.$2);

  Future<Uint8List> read(int offset, int length) async {
    reads.add((offset, length));
    return Uint8List.sublistView(bytes, offset, offset + length);
  }
}

List<int> _noise(int length) {
  // 线性同余噪声：deflate 压不动，让条目数据真的占位。
  final List<int> out = List<int>.filled(length, 0);
  int x = 12345;
  for (int i = 0; i < length; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = x >> 16 & 0xff;
  }
  return out;
}

void main() {
  test(
    'reads every entry name from the tail only, never the entry data',
    () async {
      final Uint8List zip = _zip(<String, List<int>>{
        'manga.json': utf8.encode('{"pages":[]}'),
        'p001.jpg': _noise(200 * 1024),
        'p002.jpg': _noise(200 * 1024),
      });
      final _RangeSource src = _RangeSource(zip);

      final List<ZipCentralDirectoryEntry> entries =
          await readZipCentralDirectory(length: zip.length, read: src.read);

      expect(entries.map((ZipCentralDirectoryEntry e) => e.name), <String>[
        'manga.json',
        'p001.jpg',
        'p002.jpg',
      ]);
      // 中央目录就在 16 KiB 尾巴里：一次读完，远小于 400 KiB 的条目数据。
      expect(src.reads, hasLength(1));
      expect(src.reads.single.$1, zip.length - 16 * 1024);
      expect(src.bytesRead, 16 * 1024);
    },
  );

  test(
    'a central directory outside the first tail costs one more read',
    () async {
      final Uint8List zip = _zip(<String, List<int>>{
        'mimetype': utf8.encode('application/epub+zip'),
        for (int i = 0; i < 40; i++) 'OEBPS/chapter_$i.xhtml': _noise(2048),
      });
      final _RangeSource src = _RangeSource(zip);

      final List<ZipCentralDirectoryEntry> entries =
          await readZipCentralDirectory(
            length: zip.length,
            read: src.read,
            initialTailBytes: 64,
          );

      expect(entries, hasLength(41));
      expect(entries.first.name, 'mimetype');
      expect(src.reads, hasLength(2));
      expect(src.bytesRead, lessThan(zip.length ~/ 10));
    },
  );

  test('a long EOCD comment widens the tail to the spec maximum', () async {
    final Uint8List zip = _withComment(
      _zip(<String, List<int>>{
        'a.txt': utf8.encode('a'),
        'manga.json': <int>[],
      }),
      40000,
    );
    final _RangeSource src = _RangeSource(zip);

    final List<ZipCentralDirectoryEntry> entries =
        await readZipCentralDirectory(length: zip.length, read: src.read);

    expect(
      entries.map((ZipCentralDirectoryEntry e) => e.name),
      contains('manga.json'),
    );
    expect(src.reads, hasLength(2), reason: '16 KiB 里找不到 EOCD，再扩一次');
  });

  test('UTF-8 flagged names decode as UTF-8', () async {
    final Uint8List zip = _zip(<String, List<int>>{
      '漫画/001.png': <int>[1],
    });

    final List<ZipCentralDirectoryEntry> entries =
        await readZipCentralDirectory(
          length: zip.length,
          read: _RangeSource(zip).read,
        );

    expect(entries.single.name, '漫画/001.png');
  });

  test('non-zip bytes throw ZipCentralDirectoryException', () async {
    final Uint8List bytes = Uint8List.fromList(_noise(4096));

    await expectLater(
      readZipCentralDirectory(
        length: bytes.length,
        read: _RangeSource(bytes).read,
      ),
      throwsA(isA<ZipCentralDirectoryException>()),
    );
    await expectLater(
      readZipCentralDirectory(length: 3, read: _RangeSource(bytes).read),
      throwsA(isA<ZipCentralDirectoryException>()),
    );
  });

  test(
    'a central directory above the cap is refused before it is read',
    () async {
      final Uint8List zip = _zip(<String, List<int>>{
        for (int i = 0; i < 20; i++) 'f$i': <int>[i],
      });
      final _RangeSource src = _RangeSource(zip);

      await expectLater(
        readZipCentralDirectory(
          length: zip.length,
          read: src.read,
          initialTailBytes: 22,
          maxCentralDirectoryBytes: 64,
        ),
        throwsA(isA<ZipCentralDirectoryException>()),
      );
      expect(src.reads, hasLength(1), reason: '只读了 EOCD，没去读超限的目录');
    },
  );
}
