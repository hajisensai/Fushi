// HBK-AUDIT-013 / HBK-AUDIT-051：漫画导入的重复解析 / 重复读盘。
//
// - 013：整卷导入纯图 EPUB，此前在调用 isolate（App 里是 UI isolate）上跑两遍
//   `EpubParser.parseSyncFromPath`——中央目录读两遍、OPF / spine 解析两遍、章节页图
//   引用各扫一遍。现在中央目录与 OPF 各一次，且解析、解压、定性、页图清单与挪页
//   整段在后台 isolate 里做，调用 isolate 上一次都不跑。
// - 051：逐页探尺寸时前缀定不了论的格式（WebP / AVIF / BMP…）此前关掉句柄、
//   `readAsBytes` 从头再读整页；现在同一个句柄接着读剩余部分，每页只开一次、
//   每个字节只读一次。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/epub/epub_storage.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:fushi_engine/media/manga/manga_importer.dart';
import 'package:fushi_engine/media/manga/mokuro_payload.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  late Directory root;
  late Directory app;
  late FushiDatabase db;

  setUp(() {
    root = Directory.systemTemp.createTempSync('manga_parse_once_');
    app = Directory.systemTemp.createTempSync('manga_parse_once_app_');
    EpubStorage.debugBaseDirectoryOverride = app.path;
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    EpubParser.debugZipDirectoryReadCount = 0;
    EpubParser.debugParseFromExtractedCount = 0;
  });

  tearDown(() async {
    await db.close();
    EpubStorage.debugBaseDirectoryOverride = null;
    for (final Directory d in <Directory>[root, app]) {
      if (d.existsSync()) d.deleteSync(recursive: true);
    }
  });

  Uint8List png(int width, {int height = 40}) => Uint8List.fromList(
    img.encodePng(img.Image(width: width, height: height)),
  );

  group('HBK-AUDIT-013: image-only EPUB volume import', () {
    test('no EPUB parsing runs on the calling isolate', () async {
      final String path = _writeEpub(
        root,
        pages: <Uint8List>[png(20), png(30), png(40)],
      );
      final List<(int, int)> reports = <(int, int)>[];
      final String key = await MangaArchiveImporter.importArchive(
        db: db,
        archivePath: path,
        onProgress: (int done, int total) => reports.add((done, total)),
      );
      expect(
        (
          EpubParser.debugZipDirectoryReadCount,
          EpubParser.debugParseFromExtractedCount,
        ),
        (0, 0),
        reason:
            '(zip central-directory reads, OPF/spine parses) on the calling '
            'isolate',
      );
      final EpubBookRow row = (await db.getEpubBook(key))!;
      final List<String> pages =
          Directory(p.join(row.extractDir, 'images'))
              .listSync()
              .map((FileSystemEntity e) => p.basename(e.path))
              .toList()
            ..sort();
      expect(pages, <String>[
        'page_000000.png',
        'page_000001.png',
        'page_000002.png',
      ]);
      // 8 个文件条目（container / OPF / 3 页 XHTML / 3 张图）+ 3 页入库，解压段的
      // 进度从后台 isolate 逐条送回、一条不丢。
      expect(reports.first, (0, 11));
      expect(reports, contains((8, 11)));
      expect(reports.last, (11, 11));
      expect(
        reports.where(((int, int) r) => r.$1 > 0 && r.$1 < 8),
        isNotEmpty,
        reason: '解压段逐条推进',
      );
      for (int i = 1; i < reports.length; i++) {
        expect(reports[i].$1, greaterThanOrEqualTo(reports[i - 1].$1));
      }
    });

    test('the background stage reads the central directory and parses the '
        'OPF exactly once', () async {
      final String path = _writeEpub(
        root,
        pages: <Uint8List>[png(20), png(30)],
      );
      final Directory extraction = Directory(p.join(root.path, 'extract'));
      final Directory staging = Directory(p.join(root.path, 'staging'))
        ..createSync();
      int extracted = 0;
      final ({String? rejection, String? seriesMetadata}) result =
          await MangaArchiveImporter.stageImageEpub(
            archivePath: path,
            extractionPath: extraction.path,
            stagingPath: staging.path,
            maxTotalBytes: 1 << 30,
            maxEntryBytes: 1 << 28,
            onEntryExtracted: () => extracted += 1,
          );
      expect(result.rejection, isNull);
      expect(EpubParser.debugZipDirectoryReadCount, 1);
      expect(EpubParser.debugParseFromExtractedCount, 1);
      expect(extracted, 6);
      final List<String> pages =
          staging
              .listSync()
              .map((FileSystemEntity e) => p.basename(e.path))
              .toList()
            ..sort();
      expect(pages, <String>['page_000000.png', 'page_000001.png']);
    });

    test(
      'a text EPUB is rejected before any page image is extracted',
      () async {
        final String path = _writeEpub(
          root,
          pages: <Uint8List>[png(20), png(30)],
          firstBody:
              '<p>${List<String>.filled(400, '本文').join()}</p>'
              '<img src="../images/1.png"/>',
        );
        final Directory extraction = Directory(p.join(root.path, 'extract'));
        final Directory staging = Directory(p.join(root.path, 'staging'))
          ..createSync();
        final ({String? rejection, String? seriesMetadata}) result =
            await MangaArchiveImporter.stageImageEpub(
              archivePath: path,
              extractionPath: extraction.path,
              stagingPath: staging.path,
              maxTotalBytes: 1 << 30,
              maxEntryBytes: 1 << 28,
              onEntryExtracted: () {},
            );
        expect(result.rejection, contains('not image-only'));
        expect(EpubParser.debugZipDirectoryReadCount, 1);
        expect(EpubParser.debugParseFromExtractedCount, 1);
        expect(
          File(
            p.join(extraction.path, 'OEBPS', 'images', '1.png'),
          ).existsSync(),
          isFalse,
          reason: '否决发生在页图落盘之前',
        );
        expect(staging.listSync(), isEmpty);
      },
    );

    test(
      'a text EPUB through importArchive is reported as not manga',
      () async {
        final String path = _writeEpub(
          root,
          pages: <Uint8List>[png(20)],
          firstBody:
              '<p>${List<String>.filled(400, '本文').join()}</p>'
              '<img src="../images/1.png"/>',
        );
        await expectLater(
          MangaArchiveImporter.importArchive(db: db, archivePath: path),
          throwsA(isA<MangaArchiveNotMangaException>()),
        );
        expect(await db.getEpubBookMetas(), isEmpty);
      },
    );
  });

  group('HBK-AUDIT-051: page size probe reads each page once', () {
    test('a WebP whose EXIF chunk sits past the prefix: one open, every '
        'byte read once', () async {
      // VP8L 头 + 300 KB 填充 chunk + 方向 6 的 EXIF chunk：前缀（128 KiB）定不了
      // 论（WebP 一律交全量），全量探测读到尾部的 EXIF 后宽高对调。
      final Uint8List webp = _buildWebp(
        24,
        16,
        padding: 300 * 1024,
        exifOrientation: 6,
      );
      final File real = File(p.join(root.path, 'page.webp'))
        ..writeAsBytesSync(webp);
      final _CountingFile file = _CountingFile(real);
      final MokuroSize size = await MangaImporter.pageSizeOfFile(
        file,
        'page.webp',
      );
      expect((size.width, size.height), (16.0, 24.0));
      expect(
        (file.opens, file.bytesRead),
        (1, webp.length),
        reason: '(file opens, bytes read) for one ${webp.length}-byte page',
      );
    });

    test('a page smaller than the prefix is read once', () async {
      final Uint8List bmp = img.encodeBmp(img.Image(width: 24, height: 16));
      final _CountingFile file = _CountingFile(
        File(p.join(root.path, 'page.bmp'))..writeAsBytesSync(bmp),
      );
      final MokuroSize size = await MangaImporter.pageSizeOfFile(
        file,
        'page.bmp',
      );
      expect((size.width, size.height), (24.0, 16.0));
      expect((file.opens, file.bytesRead), (1, bmp.length));
    });
  });
}

String _xhtml(String body) =>
    '<html xmlns="http://www.w3.org/1999/xhtml"><body>$body</body></html>';

/// 每页一个 XHTML 包一张 PNG 的 EPUB；[firstBody] 覆盖第一页正文。
String _writeEpub(
  Directory root, {
  required List<Uint8List> pages,
  String? firstBody,
}) {
  final StringBuffer manifest = StringBuffer();
  final StringBuffer spine = StringBuffer();
  final Map<String, List<int>> entries = <String, List<int>>{
    'META-INF/container.xml': utf8.encode('''
<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles><rootfile full-path="OEBPS/content.opf"/></rootfiles>
</container>'''),
  };
  for (int i = 1; i <= pages.length; i++) {
    manifest
      ..writeln(
        '<item id="page$i" href="text/$i.xhtml" '
        'media-type="application/xhtml+xml"/>',
      )
      ..writeln(
        '<item id="image$i" href="images/$i.png" media-type="image/png"/>',
      );
    spine.writeln('<itemref idref="page$i"/>');
  }
  entries['OEBPS/content.opf'] = utf8.encode('''
<?xml version="1.0"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>Image EPUB</dc:title>
  </metadata>
  <manifest>
$manifest  </manifest>
  <spine>
$spine  </spine>
</package>''');
  for (int i = 1; i <= pages.length; i++) {
    entries['OEBPS/text/$i.xhtml'] = utf8.encode(
      _xhtml(
        i == 1 && firstBody != null
            ? firstBody
            : '<img src="../images/$i.png"/>',
      ),
    );
  }
  for (int i = 1; i <= pages.length; i++) {
    entries['OEBPS/images/$i.png'] = pages[i - 1];
  }
  final Archive archive = Archive();
  entries.forEach((String name, List<int> bytes) {
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  });
  final String path = p.join(root.path, 'book.epub');
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}

Uint8List _u32le(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

void _addChunk(BytesBuilder out, String fourcc, Uint8List payload) {
  out
    ..add(fourcc.codeUnits)
    ..add(_u32le(payload.length))
    ..add(payload);
  if (payload.length.isOdd) out.addByte(0);
}

/// 最小 VP8L（signature 0x2F + 14bit(w-1) + 14bit(h-1)）+ [padding] 字节的填充
/// chunk + IFD0 只有一条 Orientation 的小端 TIFF `EXIF` chunk。
Uint8List _buildWebp(
  int w,
  int h, {
  required int padding,
  required int exifOrientation,
}) {
  final int bits = (w - 1) | ((h - 1) << 14);
  final BytesBuilder body = BytesBuilder();
  _addChunk(
    body,
    'VP8L',
    Uint8List.fromList(<int>[
      0x2F,
      bits & 0xFF,
      (bits >> 8) & 0xFF,
      (bits >> 16) & 0xFF,
      (bits >> 24) & 0xFF,
      0x00,
    ]),
  );
  _addChunk(body, 'PADD', Uint8List(padding));
  final BytesBuilder tiff = BytesBuilder()
    ..add(<int>[0x49, 0x49, 0x2A, 0x00])
    ..add(_u32le(8))
    ..add(<int>[0x01, 0x00, 0x12, 0x01, 0x03, 0x00])
    ..add(_u32le(1))
    ..add(<int>[exifOrientation & 0xFF, (exifOrientation >> 8) & 0xFF, 0, 0])
    ..add(_u32le(0));
  _addChunk(body, 'EXIF', tiff.toBytes());
  final Uint8List inner = body.toBytes();
  return (BytesBuilder()
        ..add('RIFF'.codeUnits)
        ..add(_u32le(4 + inner.length))
        ..add('WEBP'.codeUnits)
        ..add(inner))
      .toBytes();
}

/// 记录打开次数与读出字节数的 [File]：`open` 与整文件读（`readAsBytes`）都计。
/// [MangaImporter.pageSizeOfFile] 用不到的成员一律抛 [UnimplementedError]。
class _CountingFile implements File {
  _CountingFile(this._inner);

  final File _inner;
  int opens = 0;
  int bytesRead = 0;

  @override
  String get path => _inner.path;

  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) async {
    opens += 1;
    return _CountingRandomAccessFile(await _inner.open(mode: mode), this);
  }

  @override
  Future<Uint8List> readAsBytes() async {
    opens += 1;
    final Uint8List bytes = await _inner.readAsBytes();
    bytesRead += bytes.length;
    return bytes;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}

class _CountingRandomAccessFile implements RandomAccessFile {
  _CountingRandomAccessFile(this._inner, this._owner);

  final RandomAccessFile _inner;
  final _CountingFile _owner;

  @override
  Future<int> length() => _inner.length();

  @override
  Future<Uint8List> read(int count) async {
    final Uint8List bytes = await _inner.read(count);
    _owner.bytesRead += bytes.length;
    return bytes;
  }

  @override
  Future<int> readInto(List<int> buffer, [int start = 0, int? end]) async {
    final int n = await _inner.readInto(buffer, start, end);
    _owner.bytesRead += n;
    return n;
  }

  @override
  Future<void> close() => _inner.close();

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
