// EPUB 导入报 `RangeError (length): Invalid value: Not in inclusive range 0..36: 37`：
// archive 3.6.1 遍历 zip extra field 时以 `!isEOS` 为循环条件，extra field 末尾不足 4 字节的
// 填充会被当成下一个块头去读，`readUint16` 的 `buffer[offset++]` 越界（37 字节的 extra 读到
// 下标 37）。修复是 ci/patches/hosted/archive-3.6.1（与 archive 4.x 同款 `length >= 4`）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// 一个条目：名字、内容、写进中央目录的 extra field。
typedef _Entry = ({String name, List<int> data, List<int> centralExtra});

/// 不压缩（STORE）的 zip：本地头不带 extra，中央目录按 [_Entry.centralExtra] 原样写。
Uint8List _storedZip(List<_Entry> entries) {
  final BytesBuilder out = BytesBuilder();
  final BytesBuilder central = BytesBuilder();
  void u16(BytesBuilder b, int v) => b.add(<int>[v & 0xff, (v >> 8) & 0xff]);
  void u32(BytesBuilder b, int v) => b.add(<int>[
    v & 0xff,
    (v >> 8) & 0xff,
    (v >> 16) & 0xff,
    (v >> 24) & 0xff,
  ]);
  for (final _Entry e in entries) {
    final List<int> name = utf8.encode(e.name);
    final int crc = getCrc32(e.data);
    final int offset = out.length;
    u32(out, 0x04034b50);
    u16(out, 20); // version needed
    u16(out, 0x0800); // flags: UTF-8 names
    u16(out, 0); // STORE
    u16(out, 0); // time
    u16(out, 0x21); // date 1980-01-01
    u32(out, crc);
    u32(out, e.data.length);
    u32(out, e.data.length);
    u16(out, name.length);
    u16(out, 0); // local extra
    out.add(name);
    out.add(e.data);

    u32(central, 0x02014b50);
    u16(central, 20); // version made by
    u16(central, 20);
    u16(central, 0x0800);
    u16(central, 0);
    u16(central, 0);
    u16(central, 0x21);
    u32(central, crc);
    u32(central, e.data.length);
    u32(central, e.data.length);
    u16(central, name.length);
    u16(central, e.centralExtra.length);
    u16(central, 0); // comment
    u16(central, 0); // disk
    u16(central, 0); // internal attrs
    u32(central, 0); // external attrs
    u32(central, offset);
    central.add(name);
    central.add(e.centralExtra);
  }
  final int centralOffset = out.length;
  final Uint8List dir = central.takeBytes();
  out.add(dir);
  u32(out, 0x06054b50);
  u16(out, 0);
  u16(out, 0);
  u16(out, entries.length);
  u16(out, entries.length);
  u32(out, dir.length);
  u32(out, centralOffset);
  u16(out, 0);
  return out.takeBytes();
}

/// 37 字节的 extra field：UT 时间戳块（4+5）+ 一个未知块（4+23）+ 1 字节尾部填充。
/// 两个块消费完后剩 1 字节，未修复的 archive 3.6.1 会去读 `extra[37]`。
final List<int> _paddedExtra = <int>[
  0x55, 0x54, 5, 0, 1, 0, 0, 0, 0, //
  0xfe, 0xca, 23, 0, ...List<int>.filled(23, 0x20), //
  0x00,
];

Uint8List _epub(List<int> extraOnChapter) {
  List<int> text(String s) => utf8.encode(s);
  return _storedZip(<_Entry>[
    (
      name: 'mimetype',
      data: text('application/epub+zip'),
      centralExtra: const <int>[],
    ),
    (
      name: 'META-INF/container.xml',
      data: text(
        '<?xml version="1.0"?>'
        '<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">'
        '<rootfiles><rootfile full-path="OEBPS/content.opf" '
        'media-type="application/oebps-package+xml"/></rootfiles></container>',
      ),
      centralExtra: const <int>[],
    ),
    (
      name: 'OEBPS/content.opf',
      data: text(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="id">'
        '<metadata xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<dc:identifier id="id">x</dc:identifier>'
        '<dc:title>Re：ゼロから始める異世界生活 01</dc:title><dc:language>ja</dc:language>'
        '</metadata><manifest>'
        '<item id="c1" href="c1.xhtml" media-type="application/xhtml+xml"/>'
        '</manifest><spine><itemref idref="c1"/></spine></package>',
      ),
      centralExtra: const <int>[],
    ),
    (
      name: 'OEBPS/c1.xhtml',
      data: text(
        '<?xml version="1.0" encoding="utf-8"?>'
        '<html xmlns="http://www.w3.org/1999/xhtml"><head><title>c1</title></head>'
        '<body><p>本文</p></body></html>',
      ),
      centralExtra: extraOnChapter,
    ),
  ]);
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('epub_extra_pad'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('中央目录 extra field 末尾不足一个块头的填充不让 EPUB 解析越界', () {
    expect(_paddedExtra, hasLength(37));
    final EpubBook book = EpubParser.parseSync(
      _epub(_paddedExtra),
      p.join(tmp.path, 'out'),
    );
    expect(book.title, 'Re：ゼロから始める異世界生活 01');
    expect(book.chapters, hasLength(1));
    expect(
      File(p.join(tmp.path, 'out', 'OEBPS', 'c1.xhtml')).readAsStringSync(),
      contains('本文'),
    );
  });

  test('声明长度超过剩余字节的截断块被跳过，不影响条目本身', () {
    // 一个声称 40 字节、实际只剩 2 字节的块：补丁在这里 break，条目照常解出。
    final List<int> truncated = <int>[0xfe, 0xca, 40, 0, 0x20, 0x20];
    final EpubBook book = EpubParser.parseSync(
      _epub(truncated),
      p.join(tmp.path, 'out'),
    );
    expect(book.chapters, hasLength(1));
  });

  test('合法 extra field（zip64 以外的块）解析结果不变', () {
    final List<int> clean = _paddedExtra.sublist(0, 36);
    final Archive archive = ZipDecoder().decodeBytes(_epub(clean));
    final ArchiveFile chapter = archive.files.firstWhere(
      (ArchiveFile f) => f.name == 'OEBPS/c1.xhtml',
    );
    expect(utf8.decode(chapter.content as List<int>), contains('本文'));
  });
}
