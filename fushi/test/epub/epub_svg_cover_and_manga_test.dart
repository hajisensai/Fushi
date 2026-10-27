// Yg_v6Tnmc0 / OjZ-K53WBY：封面页 / 漫画页用 SVG `<image>` 引用光栅图的 EPUB。
//
// ① 封面：`<meta name="cover">` / `<guide type="cover">` / `cover-image` 指到的
//    是 XHTML 封面页或 SVG 文档时，`coverHref` 必须解析成其中引用的那张光栅图
//    （书架只会解码图片，旧实现把 xhtml/svg 原样当封面 → 书架没封面）。
// ② 漫画：每页都是 `<svg><image xlink:href>` 包 JPEG/PNG 的 EPUB 必须被认成
//    纯图片漫画（`looksLikeImageArchive`）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/epub/epub_book.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi_engine/foundation/engine_log.dart';
import 'package:fushi_engine/media/manga/manga_archive_importer.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

const String _svgNs =
    'xmlns="http://www.w3.org/2000/svg" '
    'xmlns:xlink="http://www.w3.org/1999/xlink"';

String _svgPage(String href) =>
    '<?xml version="1.0" encoding="UTF-8"?>\n'
    '<!DOCTYPE html>\n'
    '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
    '<head><title>p</title><meta name="viewport" content="width=20, height=40"/>'
    '</head><body>'
    '<div class="main"><svg $_svgNs version="1.1" width="100%" height="100%" '
    'viewBox="0 0 20 40"><image width="20" height="40" xlink:href="$href"/>'
    '</svg></div></body></html>';

Uint8List _png(int w) =>
    Uint8List.fromList(img.encodePng(img.Image(width: w, height: 40)));

String _writeEpub(
  Directory root, {
  required String manifest,
  required String spine,
  required Map<String, List<int>> files,
  String metadataExtra = '',
  String guide = '',
  String name = 'book.epub',
}) {
  final Map<String, List<int>> entries = <String, List<int>>{
    'mimetype': utf8.encode('application/epub+zip'),
    'META-INF/container.xml': utf8.encode('''
<?xml version="1.0"?>
<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" version="1.0">
  <rootfiles><rootfile full-path="item/standard.opf" media-type="application/oebps-package+xml"/></rootfiles>
</container>'''),
    'item/standard.opf': utf8.encode('''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="uid">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>SVG book</dc:title>
    <dc:identifier id="uid">x</dc:identifier>
    $metadataExtra
  </metadata>
  <manifest>
$manifest
  </manifest>
  <spine>
$spine
  </spine>
  $guide
</package>'''),
    ...files,
  };
  final Archive archive = Archive();
  entries.forEach((String n, List<int> bytes) {
    archive.addFile(ArchiveFile(n, bytes.length, bytes));
  });
  final String path = p.join(root.path, name);
  File(path).writeAsBytesSync(ZipEncoder().encode(archive)!);
  return path;
}

void main() {
  late Directory root;
  late Directory extract;

  setUp(() {
    root = Directory.systemTemp.createTempSync('epub_svg_');
    extract = Directory.systemTemp.createTempSync('epub_svg_x_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
    if (extract.existsSync()) extract.deleteSync(recursive: true);
  });

  group('Yg_v6Tnmc0：封面声明指向页面时取页内光栅图', () {
    test('EPUB2 meta name=cover 指向 SVG 包图的 XHTML 封面页', () {
      final String path = _writeEpub(
        root,
        metadataExtra: '<meta name="cover" content="p-cover"/>',
        manifest: '''
    <item id="p-cover" href="xhtml/p-cover.xhtml" media-type="application/xhtml+xml" properties="svg"/>
    <item id="p-001" href="xhtml/p-001.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover-img" href="image/cover.jpg" media-type="image/jpeg"/>
    <item id="i-001" href="image/i-001.png" media-type="image/png"/>''',
        spine: '<itemref idref="p-cover"/><itemref idref="p-001"/>',
        files: <String, List<int>>{
          'item/xhtml/p-cover.xhtml': utf8.encode(
            _svgPage('../image/cover.jpg'),
          ),
          'item/xhtml/p-001.xhtml': utf8.encode(
            '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
            '<p>本文</p><img src="../image/i-001.png"/></body></html>',
          ),
          'item/image/cover.jpg': _png(20),
          'item/image/i-001.png': _png(30),
        },
      );
      final EpubBook book = EpubParser.parseSync(
        File(path).readAsBytesSync(),
        extract.path,
      );
      expect(
        book.coverHref,
        'item/image/cover.jpg',
        reason: '封面必须是图片，而不是 xhtml 封面页本身',
      );
    });

    test('cover-image 指向 SVG 文档 → 取 SVG 里引用的光栅图', () {
      final String path = _writeEpub(
        root,
        manifest: '''
    <item id="cov" href="image/cover.svg" media-type="image/svg+xml" properties="cover-image"/>
    <item id="p-001" href="xhtml/p-001.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover-img" href="image/real.png" media-type="image/png"/>
    <item id="other" href="image/other.png" media-type="image/png"/>''',
        spine: '<itemref idref="p-001"/>',
        files: <String, List<int>>{
          'item/image/cover.svg': utf8.encode(
            '<svg $_svgNs viewBox="0 0 20 40"><image width="20" height="40" '
            'href="real.png"/></svg>',
          ),
          'item/xhtml/p-001.xhtml': utf8.encode(
            '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>x</p></body></html>',
          ),
          'item/image/other.png': _png(10),
          'item/image/real.png': _png(20),
        },
      );
      final EpubBook book = EpubParser.parseSync(
        File(path).readAsBytesSync(),
        extract.path,
      );
      expect(book.coverHref, 'item/image/real.png');
    });

    test('guide type=cover 指向 XHTML 封面页（无 meta / cover-image）', () {
      final String path = _writeEpub(
        root,
        guide:
            '<guide><reference type="cover" title="Cover" '
            'href="xhtml/p-cover.xhtml"/></guide>',
        manifest: '''
    <item id="i-000" href="image/aaa_first.png" media-type="image/png"/>
    <item id="p-cover" href="xhtml/p-cover.xhtml" media-type="application/xhtml+xml"/>
    <item id="cover-img" href="image/cover.png" media-type="image/png"/>''',
        spine: '<itemref idref="p-cover"/>',
        files: <String, List<int>>{
          'item/xhtml/p-cover.xhtml': utf8.encode(
            _svgPage('../image/cover.png'),
          ),
          'item/image/aaa_first.png': _png(10),
          'item/image/cover.png': _png(20),
        },
      );
      final EpubBook book = EpubParser.parseSync(
        File(path).readAsBytesSync(),
        extract.path,
      );
      expect(
        book.coverHref,
        'item/image/cover.png',
        reason: 'guide 声明的封面页优先于「manifest 第一张图」兜底',
      );
    });

    test('纯矢量 SVG 封面（无光栅引用）→ 落到 manifest 第一张光栅图', () {
      final String path = _writeEpub(
        root,
        manifest: '''
    <item id="cov" href="image/cover.svg" media-type="image/svg+xml" properties="cover-image"/>
    <item id="p-001" href="xhtml/p-001.xhtml" media-type="application/xhtml+xml"/>
    <item id="i-001" href="image/i-001.png" media-type="image/png"/>''',
        spine: '<itemref idref="p-001"/>',
        files: <String, List<int>>{
          'item/image/cover.svg': utf8.encode(
            '<svg $_svgNs viewBox="0 0 20 40"><rect width="20" height="40"/></svg>',
          ),
          'item/xhtml/p-001.xhtml': utf8.encode(
            '<html xmlns="http://www.w3.org/1999/xhtml"><body><p>x</p></body></html>',
          ),
          'item/image/i-001.png': _png(10),
        },
      );
      final EpubBook book = EpubParser.parseSync(
        File(path).readAsBytesSync(),
        extract.path,
      );
      expect(book.coverHref, 'item/image/i-001.png');
    });
  });

  group('OjZ-K53WBY：SVG 包页图的漫画 EPUB', () {
    test('每页 <svg><image xlink:href> 包图 → 认成纯图片漫画', () {
      final String path = _writeEpub(
        root,
        metadataExtra:
            '<meta property="rendition:layout">pre-paginated</meta>'
            '<meta name="cover" content="cover-img"/>',
        manifest: '''
    <item id="nav" href="navigation-documents.xhtml" media-type="application/xhtml+xml" properties="nav"/>
    <item id="p-cover" href="xhtml/p-cover.xhtml" media-type="application/xhtml+xml" properties="svg"/>
    <item id="p-001" href="xhtml/p-001.xhtml" media-type="application/xhtml+xml" properties="svg"/>
    <item id="cover-img" href="image/cover.jpg" media-type="image/jpeg" properties="cover-image"/>
    <item id="i-001" href="image/i-001.jpg" media-type="image/jpeg"/>''',
        spine:
            '<itemref linear="yes" idref="p-cover" properties="rendition:page-spread-left"/>'
            '<itemref linear="yes" idref="p-001" properties="page-spread-right"/>',
        files: <String, List<int>>{
          'item/navigation-documents.xhtml': utf8.encode(
            '<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">'
            '<body><nav epub:type="toc"><ol><li><a href="xhtml/p-cover.xhtml">表紙</a></li>'
            '</ol></nav></body></html>',
          ),
          'item/xhtml/p-cover.xhtml': utf8.encode(
            _svgPage('../image/cover.jpg'),
          ),
          'item/xhtml/p-001.xhtml': utf8.encode(_svgPage('../image/i-001.jpg')),
          'item/image/cover.jpg': _png(20),
          'item/image/i-001.jpg': _png(30),
        },
      );
      expect(MangaArchiveImporter.looksLikeImageArchive(path), isTrue);
    });

    test('spine 直接是 SVG 文档（image/svg+xml）：判不成漫画时日志写明原因', () {
      // 已知限制（未修）：EpubParser 只收 HTML 类 spine 项，SVG 内容文档作 spine
      // 的书解析即抛「no readable chapters」。OjZ-K53WBY 没有样本，不能确认是
      // 这一形态；先保证否决理由进诊断日志，下一份反馈能定位。
      final String path = _writeEpub(
        root,
        name: 'svgspine.epub',
        manifest: '''
    <item id="p-001" href="image/p-001.svg" media-type="image/svg+xml"/>
    <item id="p-002" href="image/p-002.svg" media-type="image/svg+xml"/>
    <item id="i-001" href="image/i-001.jpg" media-type="image/jpeg"/>
    <item id="i-002" href="image/i-002.jpg" media-type="image/jpeg"/>''',
        spine: '<itemref idref="p-001"/><itemref idref="p-002"/>',
        files: <String, List<int>>{
          'item/image/p-001.svg': utf8.encode(
            '<svg $_svgNs viewBox="0 0 20 40"><image width="20" height="40" '
            'xlink:href="i-001.jpg"/></svg>',
          ),
          'item/image/p-002.svg': utf8.encode(
            '<svg $_svgNs viewBox="0 0 20 40"><image width="20" height="40" '
            'xlink:href="i-002.jpg"/></svg>',
          ),
          'item/image/i-001.jpg': _png(20),
          'item/image/i-002.jpg': _png(30),
        },
      );
      final List<String> logged = <String>[];
      final EngineLogSink previous = engineLog;
      engineLog = _CapturingSink(logged);
      addTearDown(() => engineLog = previous);
      expect(MangaArchiveImporter.looksLikeImageArchive(path), isFalse);
      expect(
        logged.single,
        allOf(contains('svgspine.epub'), contains('no readable chapters')),
      );
    });

    test('含文字页的 EPUB：日志写明是哪一章有文字', () {
      final String path = _writeEpub(
        root,
        name: 'textpage.epub',
        manifest: '''
    <item id="p-001" href="xhtml/p-001.xhtml" media-type="application/xhtml+xml"/>
    <item id="p-002" href="xhtml/p-002.xhtml" media-type="application/xhtml+xml"/>
    <item id="i-001" href="image/i-001.jpg" media-type="image/jpeg"/>''',
        spine: '<itemref idref="p-001"/><itemref idref="p-002"/>',
        files: <String, List<int>>{
          'item/xhtml/p-001.xhtml': utf8.encode(_svgPage('../image/i-001.jpg')),
          'item/xhtml/p-002.xhtml': utf8.encode(
            '<html xmlns="http://www.w3.org/1999/xhtml"><body>'
            '<p>この本の奥付です。発行者・印刷所などの文字がここに並びます。</p>'
            '<p>著者紹介と著作権表示もここに長く書かれていて画像ページではない。</p>'
            '</body></html>',
          ),
          'item/image/i-001.jpg': _png(20),
        },
      );
      final List<String> logged = <String>[];
      final EngineLogSink previous = engineLog;
      engineLog = _CapturingSink(logged);
      addTearDown(() => engineLog = previous);
      expect(MangaArchiveImporter.looksLikeImageArchive(path), isFalse);
      expect(
        logged.single,
        allOf(
          contains('textpage.epub'),
          contains('p-002.xhtml'),
          contains('not image-only'),
        ),
      );
    });
  });
}

class _CapturingSink implements EngineLogSink {
  _CapturingSink(this.lines);

  final List<String> lines;

  @override
  void log(String source, Object error, [StackTrace? stack]) =>
      lines.add('$source: $error');

  @override
  void logDiagnostic(String source, Object info) => lines.add('$source: $info');

  @override
  void logFatal(String source, Object error, [StackTrace? stack]) =>
      lines.add('$source: $error');
}
