// 用户导入一本没下载完的 EPUB（130 KB，停在第 6 个正文条目中途，没有 zip 中央
// 目录与尾记录），archive 抛 `FormatException: Could not find End of Central
// Directory Record`，导入弹窗把这句英文原样 toast 出来。解析器须把 zip 层失败
// 统一成 [EpubArchiveCorruptException]，UI 才能提示「文件不完整，请重新下载」。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart' hide ZLibDecoder, ZLibEncoder;
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

Uint8List _validEpubBytes() {
  final Archive archive = Archive();
  void add(String name, String text) {
    final List<int> data = text.codeUnits;
    archive.addFile(ArchiveFile(name, data.length, data));
  }

  add('mimetype', 'application/epub+zip');
  add(
    'META-INF/container.xml',
    '<?xml version="1.0"?><container version="1.0" '
        'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
        '<rootfile full-path="content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
  );
  add(
    'content.opf',
    '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" '
        'version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:title>t</dc:title></metadata><manifest>'
        '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="c1"/></spine></package>',
  );
  add('c1.xhtml', '<html><body><p>${'a' * 4000}</p></body></html>');
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('epub_corrupt_'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('truncated download (no central directory) throws typed error', () {
    final Uint8List full = _validEpubBytes();
    final File truncated = File(p.join(tmp.path, 'book.epub'))
      ..writeAsBytesSync(full.sublist(0, full.length ~/ 2));

    expect(
      () =>
          EpubParser.parseSyncFromPath(truncated.path, p.join(tmp.path, 'out')),
      throwsA(
        isA<EpubArchiveCorruptException>().having(
          (EpubArchiveCorruptException e) => e.message,
          'message',
          contains('End of Central Directory'),
        ),
      ),
    );
  });

  test('typed error stays a FormatException for existing catches', () {
    expect(const EpubArchiveCorruptException('x'), isA<FormatException>());
  });

  test('a CRC-corrupt entry throws the typed error and removes the '
      'half-written extraction it created', () {
    // 流式解压改成边写边核对 CRC：坏条目要在写盘时报出（与旧的整包 verify 同一
    // 异常类型），并且不留下写了一半的解压目录。
    final File bad = File(p.join(tmp.path, 'bad.epub'))
      ..writeAsBytesSync(
        _rawZip(<_RawEntry>[
          ..._textEntries(),
          _RawEntry.stored('images/1.png', Uint8List.fromList(<int>[1, 2, 3]))
            ..crc ^= 0xFFFF,
        ]),
      );
    final String out = p.join(tmp.path, 'out_bad');

    expect(
      () => EpubParser.parseSyncFromPath(bad.path, out),
      throwsA(
        isA<EpubArchiveCorruptException>().having(
          (EpubArchiveCorruptException e) => e.message,
          'message',
          contains('CRC'),
        ),
      ),
    );
    expect(Directory(out).existsSync(), isFalse);
  });

  group('large EPUBs are read entry by entry, not into memory', () {
    // 2 GiB 以上的纯图 EPUB 漫画：旧实现 `readAsBytesSync` 整本读入，再把每个条目
    // 解压缓存在 ArchiveFile 上做 CRC——峰值≈文件体积 + 全部解压内容。这里用一个
    // 512 MiB 的全零条目（压缩后约 0.5 MB），旧实现会让峰值 RSS 多出 ≥ 512 MiB。
    const int bigBytes = 512 * 1024 * 1024;
    late File big;

    setUp(() {
      big = File(p.join(tmp.path, 'big.epub'))
        ..writeAsBytesSync(
          _rawZip(<_RawEntry>[
            ..._textEntries(),
            _RawEntry.deflatedZeros('images/big.png', bigBytes),
          ]),
        );
    });

    void expectBoundedPeak(int rssBefore, int peakBefore) {
      final int peakAfter = ProcessInfo.maxRss;
      expect(
        peakAfter <= peakBefore || peakAfter - rssBefore < 128 * 1024 * 1024,
        isTrue,
        reason:
            'peak RSS grew from $rssBefore to $peakAfter (previous peak '
            '$peakBefore)',
      );
    }

    test('parseSyncFromPath streams entries to disk', () {
      final int rssBefore = ProcessInfo.currentRss;
      final int peakBefore = ProcessInfo.maxRss;
      final String out = p.join(tmp.path, 'out_big');

      EpubParser.parseSyncFromPath(big.path, out);

      expectBoundedPeak(rssBefore, peakBefore);
      expect(File(p.join(out, 'images', 'big.png')).lengthSync(), bigBytes);
    });

    test('readTitleSync only inflates container.xml and the OPF', () {
      final int rssBefore = ProcessInfo.currentRss;
      final int peakBefore = ProcessInfo.maxRss;

      expect(EpubParser.readTitleSync(big.path), 't');

      expectBoundedPeak(rssBefore, peakBefore);
    });
  });

  test('intact EPUB still parses', () {
    final File ok = File(p.join(tmp.path, 'ok.epub'))
      ..writeAsBytesSync(_validEpubBytes());
    expect(
      () => EpubParser.parseSyncFromPath(ok.path, p.join(tmp.path, 'out2')),
      returnsNormally,
    );
  });
}

/// 手拼 zip 的条目：[data] 已按 [method] 编码，[size] / [crc] 原样写入（可以谎报）。
class _RawEntry {
  _RawEntry(this.name, this.data, this.method, this.size, this.crc);

  _RawEntry.stored(String name, Uint8List bytes)
    : this(name, bytes, 0, bytes.length, getCrc32(bytes));

  factory _RawEntry.deflatedZeros(String name, int length) {
    final BytesBuilder out = BytesBuilder(copy: false);
    final ByteConversionSink encoder = ZLibEncoder(
      raw: true,
    ).startChunkedConversion(ByteConversionSink.withCallback(out.add));
    final Uint8List zeros = Uint8List(1024 * 1024);
    int crc = 0;
    for (int done = 0; done < length; done += zeros.length) {
      final int n = length - done < zeros.length ? length - done : zeros.length;
      encoder.addSlice(zeros, 0, n, false);
      crc = getCrc32(n == zeros.length ? zeros : Uint8List(n), crc);
    }
    encoder.close();
    return _RawEntry(name, out.takeBytes(), 8, length, crc);
  }

  final String name;
  final Uint8List data;
  final int method;
  final int size;
  int crc;
}

List<_RawEntry> _textEntries() {
  _RawEntry text(String name, String value) =>
      _RawEntry.stored(name, Uint8List.fromList(utf8.encode(value)));
  return <_RawEntry>[
    text('mimetype', 'application/epub+zip'),
    text(
      'META-INF/container.xml',
      '<?xml version="1.0"?><container version="1.0" '
          'xmlns="urn:oasis:names:tc:opendocument:xmlns:container"><rootfiles>'
          '<rootfile full-path="content.opf" '
          'media-type="application/oebps-package+xml"/></rootfiles></container>',
    ),
    text(
      'content.opf',
      '<?xml version="1.0"?><package xmlns="http://www.idpf.org/2007/opf" '
          'version="2.0"><metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
          '<dc:title>t</dc:title></metadata><manifest>'
          '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>'
          '</manifest><spine><itemref idref="c1"/></spine></package>',
    ),
    text('c1.xhtml', '<html><body><p>${'a' * 4000}</p></body></html>'),
  ];
}

Uint8List _rawZip(List<_RawEntry> entries) {
  final BytesBuilder out = BytesBuilder(copy: false);
  Uint8List u16(int v) =>
      (ByteData(2)..setUint16(0, v, Endian.little)).buffer.asUint8List();
  Uint8List u32(int v) =>
      (ByteData(4)..setUint32(0, v, Endian.little)).buffer.asUint8List();
  final List<int> offsets = <int>[];
  for (final _RawEntry e in entries) {
    final List<int> name = utf8.encode(e.name);
    offsets.add(out.length);
    out
      ..add(u32(0x04034b50))
      ..add(u16(20))
      ..add(u16(0x0800))
      ..add(u16(e.method))
      ..add(u16(0))
      ..add(u16(0x21))
      ..add(u32(e.crc))
      ..add(u32(e.data.length))
      ..add(u32(e.size))
      ..add(u16(name.length))
      ..add(u16(0))
      ..add(name)
      ..add(e.data);
  }
  final int directoryOffset = out.length;
  for (int i = 0; i < entries.length; i++) {
    final _RawEntry e = entries[i];
    final List<int> name = utf8.encode(e.name);
    out
      ..add(u32(0x02014b50))
      ..add(u16(20))
      ..add(u16(20))
      ..add(u16(0x0800))
      ..add(u16(e.method))
      ..add(u16(0))
      ..add(u16(0x21))
      ..add(u32(e.crc))
      ..add(u32(e.data.length))
      ..add(u32(e.size))
      ..add(u16(name.length))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u16(0))
      ..add(u32(0))
      ..add(u32(offsets[i]))
      ..add(name);
  }
  final int directorySize = out.length - directoryOffset;
  out
    ..add(u32(0x06054b50))
    ..add(u16(0))
    ..add(u16(0))
    ..add(u16(entries.length))
    ..add(u16(entries.length))
    ..add(u32(directorySize))
    ..add(u32(directoryOffset))
    ..add(u16(0));
  return out.takeBytes();
}
