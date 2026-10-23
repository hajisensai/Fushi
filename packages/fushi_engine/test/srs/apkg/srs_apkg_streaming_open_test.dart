// .apkg / .colpkg 从文件流式解包（Android 上 AnkiDroid 导出的带媒体 .colpkg 导入报
// 「Out of Memory」）：包不整体读进内存，集合流式解压到工作目录，媒体按需逐个取。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/apkg/srs_anki_package.dart';
import 'package:fushi_engine/srs/apkg/srs_zip_file_reader.dart';
import 'package:test/test.dart';

/// 一个 zip 条目：[write] 往数据区写（STORE 时就是原文），返回写入的字节数。
class _Entry {
  _Entry.bytes(this.name, Uint8List data, {bool deflate = false})
    : method = deflate ? 8 : 0,
      uncompressed = data.length,
      _data = deflate
          ? Uint8List.fromList(ZLibEncoder(raw: true).convert(data))
          : data,
      _zeros = 0;

  /// [size] 字节的 0（STORE），分块写，测试进程自己也不持有它。
  _Entry.zeros(this.name, int size)
    : method = 0,
      uncompressed = size,
      _data = null,
      _zeros = size;

  final String name;
  final int method;
  final int uncompressed;
  final Uint8List? _data;
  final int _zeros;

  int get compressed => _data?.length ?? _zeros;

  void write(RandomAccessFile out) {
    final Uint8List? d = _data;
    if (d != null) {
      out.writeFromSync(d);
      return;
    }
    final Uint8List chunk = Uint8List(1 << 20);
    int left = _zeros;
    while (left > 0) {
      final int n = left < chunk.length ? left : chunk.length;
      out.writeFromSync(chunk, 0, n);
      left -= n;
    }
  }
}

void _u16(BytesBuilder b, int v) => b.add(<int>[v & 0xff, (v >> 8) & 0xff]);
void _u32(BytesBuilder b, int v) =>
    b.add(<int>[v & 0xff, (v >> 8) & 0xff, (v >> 16) & 0xff, (v >> 24) & 0xff]);

/// 最小 zip 写入器（CRC 记 0：读取方不校验）。
void _writeZip(File file, List<_Entry> entries) {
  final RandomAccessFile out = file.openSync(mode: FileMode.write);
  final List<int> offsets = <int>[];
  try {
    for (final _Entry e in entries) {
      offsets.add(out.positionSync());
      final List<int> name = utf8.encode(e.name);
      final BytesBuilder h = BytesBuilder();
      _u32(h, 0x04034b50);
      _u16(h, 20);
      _u16(h, 0x0800);
      _u16(h, e.method);
      _u16(h, 0);
      _u16(h, 0);
      _u32(h, 0);
      _u32(h, e.compressed);
      _u32(h, e.uncompressed);
      _u16(h, name.length);
      _u16(h, 0);
      h.add(name);
      out.writeFromSync(h.takeBytes());
      e.write(out);
    }
    final int cdStart = out.positionSync();
    final BytesBuilder cd = BytesBuilder();
    for (int i = 0; i < entries.length; i++) {
      final _Entry e = entries[i];
      final List<int> name = utf8.encode(e.name);
      _u32(cd, 0x02014b50);
      _u16(cd, 20);
      _u16(cd, 20);
      _u16(cd, 0x0800);
      _u16(cd, e.method);
      _u16(cd, 0);
      _u16(cd, 0);
      _u32(cd, 0);
      _u32(cd, e.compressed);
      _u32(cd, e.uncompressed);
      _u16(cd, name.length);
      _u16(cd, 0);
      _u16(cd, 0);
      _u16(cd, 0);
      _u16(cd, 0);
      _u32(cd, 0);
      _u32(cd, offsets[i]);
      cd.add(name);
    }
    final Uint8List cdBytes = cd.takeBytes();
    out.writeFromSync(cdBytes);
    final BytesBuilder end = BytesBuilder();
    _u32(end, 0x06054b50);
    _u16(end, 0);
    _u16(end, 0);
    _u16(end, entries.length);
    _u16(end, entries.length);
    _u32(end, cdBytes.length);
    _u32(end, cdStart);
    _u16(end, 0);
    out.writeFromSync(end.takeBytes());
  } finally {
    out.closeSync();
  }
}

Uint8List? _noZstd(Uint8List data) => null;

void main() {
  late Directory tmp;
  late Directory work;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_apkg_stream_test_');
    work = Directory('${tmp.path}${Platform.pathSeparator}work')..createSync();
  });
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // Windows 句柄晚释放。
    }
  });

  Uint8List pseudoSqlite(int size) {
    final Uint8List b = Uint8List(size);
    for (int i = 0; i < size; i++) {
      b[i] = (i * 31 + (i >> 7)) & 0xff;
    }
    b.setRange(0, 16, ascii.encode('SQLite format 3\u0000'));
    return b;
  }

  test('集合流式解压到工作目录；媒体清单解析；媒体按需逐个取', () async {
    final Uint8List col = pseudoSqlite(3 * 1024 * 1024 + 17);
    final File pkg = File('${tmp.path}${Platform.pathSeparator}a.colpkg');
    _writeZip(pkg, <_Entry>[
      _Entry.bytes('collection.anki21', col, deflate: true),
      _Entry.bytes(
        'media',
        Uint8List.fromList(utf8.encode('{"0":"a.mp3","1":"b.jpg"}')),
      ),
      _Entry.bytes('0', Uint8List.fromList(<int>[1, 2, 3]), deflate: true),
      _Entry.bytes('1', Uint8List.fromList(<int>[4, 5])),
    ]);
    final SrsAnkiPackage p = SrsAnkiPackage.openFile(
      pkg.path,
      zstd: _noZstd,
      workDir: work.path,
    );
    expect(p.latestFormat, isFalse);
    expect(p.collectionBytes, isEmpty);
    expect(p.collectionFile!.readAsBytesSync(), col);
    expect(p.mediaIndex, <String, String>{'a.mp3': '0', 'b.jpg': '1'});
    expect(await p.mediaBytes('a.mp3'), <int>[1, 2, 3]);
    expect(await p.mediaBytes('b.jpg'), <int>[4, 5]);
    expect(await p.mediaBytes('missing.png'), isNull);
  });

  test('新格式：collection.anki21b 先流式落盘再 zstd 解码', () {
    final Uint8List col = pseudoSqlite(4096);
    final Uint8List framed = Uint8List.fromList(<int>[
      0x28,
      0xB5,
      0x2F,
      0xFD,
      ...col,
    ]);
    final File pkg = File('${tmp.path}${Platform.pathSeparator}n.apkg');
    _writeZip(pkg, <_Entry>[_Entry.bytes('collection.anki21b', framed)]);
    final SrsAnkiPackage p = SrsAnkiPackage.openFile(
      pkg.path,
      // 假 zstd：去掉 4 字节魔数。
      zstd: (Uint8List d) => Uint8List.sublistView(d, 4),
      workDir: work.path,
    );
    expect(p.latestFormat, isTrue);
    expect(p.collectionFile!.readAsBytesSync(), col);
  });

  test('不是 zip / 没有集合：按损坏 / 缺集合报错', () {
    final File junk = File('${tmp.path}${Platform.pathSeparator}j.apkg')
      ..writeAsBytesSync(List<int>.filled(100, 7));
    expect(
      () =>
          SrsAnkiPackage.openFile(junk.path, zstd: _noZstd, workDir: work.path),
      throwsA(
        isA<SrsImportException>().having(
          (SrsImportException e) => e.code,
          'code',
          SrsImportException.corrupt,
        ),
      ),
    );
    final File empty = File('${tmp.path}${Platform.pathSeparator}e.apkg');
    _writeZip(empty, <_Entry>[
      _Entry.bytes('media', Uint8List.fromList(utf8.encode('{}'))),
    ]);
    expect(
      () => SrsAnkiPackage.openFile(
        empty.path,
        zstd: _noZstd,
        workDir: work.path,
      ),
      throwsA(
        isA<SrsImportException>().having(
          (SrsImportException e) => e.code,
          'code',
          SrsImportException.noCollection,
        ),
      ),
    );
  });

  test('带 384 MB 媒体的包：解包不把媒体读进内存（常驻内存增量远小于包大小）', () async {
    const int mediaSize = 384 * 1024 * 1024;
    final File pkg = File('${tmp.path}${Platform.pathSeparator}big.colpkg');
    _writeZip(pkg, <_Entry>[
      _Entry.bytes('collection.anki21', pseudoSqlite(64 * 1024), deflate: true),
      _Entry.bytes(
        'media',
        Uint8List.fromList(utf8.encode('{"0":"huge.mp4","1":"small.mp3"}')),
      ),
      _Entry.zeros('0', mediaSize),
      _Entry.bytes('1', Uint8List.fromList(<int>[9, 9, 9])),
    ]);
    expect(pkg.lengthSync(), greaterThan(mediaSize));
    final int before = ProcessInfo.currentRss;
    final SrsAnkiPackage p = SrsAnkiPackage.openFile(
      pkg.path,
      zstd: _noZstd,
      workDir: work.path,
    );
    // 旧实现（readAsBytes + archive 整包解码）这里至少多出一整个包（≥ 384 MB）。
    expect(ProcessInfo.currentRss - before, lessThan(64 * 1024 * 1024));
    // 其它媒体照常逐个取，不碰大文件。
    expect(await p.mediaBytes('small.mp3'), <int>[9, 9, 9]);
    expect(ProcessInfo.currentRss - before, lessThan(64 * 1024 * 1024));
    // 中央目录里的大小就是条目真实大小。
    final Map<String, SrsZipEntry> index = srsReadZipIndex(pkg.path);
    expect(index['0']!.compressedSize, mediaSize);
  });

  test('守卫：从文件导入不整包读入（不 readAsBytes 包文件，不经内存版入口）', () {
    final String src = File(
      'lib/srs/apkg/srs_apkg_import.dart',
    ).readAsStringSync();
    final int start = src.indexOf(
      'Future<SrsImportReport> importAnkiPackageFile(',
    );
    expect(start, greaterThan(0));
    final int end = src.indexOf('\n}\n', start);
    final String body = src.substring(start, end);
    expect(body, isNot(contains('readAsBytes')));
    expect(body, isNot(contains('importAnkiPackage(')));
    expect(body, contains('SrsAnkiPackage.openFile('));
  });
}
