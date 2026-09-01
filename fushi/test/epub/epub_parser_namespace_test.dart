// BUG-2012：EPUB 规范只要求元素落在 OPF / OCF / NCX 命名空间里，**没规定**必须
// 用默认命名空间。Calibre 4.x 导出的包文档就写成带前缀的
// `<opf:package><opf:manifest><opf:item/>`。而 package:xml 的
// `findAllElements(name)` 在不传 `namespace` 时按 **qualified name** 匹配，
// 裸 `'item'` 匹配不到 `<opf:item>` —— manifest 解析成空 map、spine 里每个
// itemref 查不到条目被逐条静默跳过、最终整本书 0 章，
// `EpubParser.parseSync` 抛 `EPUB spine contains no readable chapters`，
// 用户看到的就是「这本 EPUB 导入不了」。
//
// 用户实例：白夜行_backup.epub（東野圭吾 / calibre 4.99.5），整份 OPF 带
// `opf:` 前缀 → 实测 `findAllElements('item')` = 0（加 `namespace: '*'` = 21）。
// 同书另一份用默认命名空间导出的副本则解析正常，两者内容完全一致。
//
// 本测试锁两层契约：
//   ① 行为层——带前缀的包文档必须和无前缀的解析出**完全一样**的结果；
//   ② 源码层——解析器里不得再出现按 qualified name 的裸查找（下一处新增
//      查找若忘了带 namespace，行为测试可能因为样本没覆盖到而漏网）。
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_parser.dart';

void main() {
  group('EpubParser 命名空间前缀 (BUG-2012)', () {
    late Directory extractDir;

    setUp(() {
      extractDir = Directory.systemTemp.createTempSync('epub_ns_test_');
    });

    tearDown(() {
      if (extractDir.existsSync()) {
        extractDir.deleteSync(recursive: true);
      }
    });

    test('整份带 opf: 前缀的包文档能解析出全部章节（修复前抛 no readable chapters）', () {
      final EpubBook book =
          EpubParser.parseSync(_buildEpub(prefixed: true), extractDir.path);

      expect(book.chapters, hasLength(2),
          reason: 'manifest 按 local-name 匹配后 spine 两章都应落地；'
              '若为 0 章说明 <opf:item> 又没被匹配到');
      expect(book.chapters[0].href, contains('chapter-1.xhtml'));
      expect(book.chapters[1].href, contains('chapter-2.xhtml'));
      expect(book.title, '白夜行');
      expect(book.author, '東野圭吾');
      expect(book.language, 'ja');
      expect(book.coverHref, contains('cover.jpg'),
          reason: '<opf:meta name="cover"> 同样按 qualified name 匹配不到');
    });

    test('带前缀与不带前缀解析出完全一致的结果（前缀不改变任何语义）', () {
      final EpubBook prefixed =
          EpubParser.parseSync(_buildEpub(prefixed: true), extractDir.path);

      final Directory plainDir =
          Directory.systemTemp.createTempSync('epub_ns_plain_');
      addTearDown(() {
        if (plainDir.existsSync()) {
          plainDir.deleteSync(recursive: true);
        }
      });
      final EpubBook plain =
          EpubParser.parseSync(_buildEpub(prefixed: false), plainDir.path);

      expect(prefixed.chapters.length, plain.chapters.length);
      expect(prefixed.title, plain.title);
      expect(prefixed.author, plain.author);
      expect(prefixed.language, plain.language);
      expect(
        prefixed.chapters.map((EpubChapter c) => c.id).toList(),
        plain.chapters.map((EpubChapter c) => c.id).toList(),
      );
      expect(
        prefixed.chapters.map((EpubChapter c) => c.href).toList(),
        plain.chapters.map((EpubChapter c) => c.href).toList(),
      );
      expect(
        prefixed.toc.map((EpubTocItem e) => e.label).toList(),
        plain.toc.map((EpubTocItem e) => e.label).toList(),
      );
      expect(
        prefixed.toc.map((EpubTocItem e) => e.href).toList(),
        plain.toc.map((EpubTocItem e) => e.href).toList(),
      );
    });

    test('NCX 带 ncx: 前缀时目录仍能解析', () {
      final EpubBook book =
          EpubParser.parseSync(_buildEpub(prefixed: true), extractDir.path);

      expect(book.toc, isNotEmpty,
          reason: '<ncx:navMap>/<ncx:navLabel>/<ncx:text> 必须按 local-name 匹配');
      expect(book.toc.first.label, '第一章');
      expect(book.toc.map((EpubTocItem e) => e.label), contains('第二章'));
    });

    test('container.xml 带 ocf: 前缀时仍能找到 rootfile', () {
      // 单独一份：只把 container.xml 加前缀，OPF 保持无前缀，确保
      // _findRootfilePath 这一处被独立覆盖（否则它的修复会被 OPF 那条掩盖）。
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXmlPrefixed),
        _textFile('content.opf', _opf(prefixed: false)),
        _textFile('text/chapter-1.xhtml', _chapterXhtml('第一章', '本文その一。')),
        _textFile('text/chapter-2.xhtml', _chapterXhtml('第二章', '本文その二。')),
        _textFile('toc.ncx', _ncx(prefixed: false)),
        _binaryFile('images/cover.jpg'),
      ]);

      final EpubBook book = EpubParser.parseSync(bytes, extractDir.path);
      expect(book.chapters, hasLength(2),
          reason: '<ocf:rootfile> 匹配不到会更早抛 no rootfile in container.xml');
    });

    test('EPUB 3 nav 文档的 epub:type 属性按 local-name 读', () {
      final Uint8List bytes = _encodeArchive(<ArchiveFile>[
        _textFile('META-INF/container.xml', _containerXmlPlain),
        _textFile('content.opf', _opfWithNav),
        _textFile('nav.xhtml', _navXhtml),
        _textFile('text/chapter-1.xhtml', _chapterXhtml('第一章', '本文その一。')),
      ]);

      final EpubBook book = EpubParser.parseSync(bytes, extractDir.path);
      expect(book.toc, isNotEmpty,
          reason: 'nav 走 <nav epub:type="toc">，属性同样带前缀；'
              '读不到就会静默回落 NCX，这里没有 NCX 所以目录会是空');
      expect(book.toc.first.label, '第一章');
    });
  });

  group('EpubParser 源码守卫：不得再出现按 qualified name 的裸查找 (BUG-2012)', () {
    test('epub_parser.dart 里所有标签查找都走 _elements/_childElement', () {
      final String source =
          File('lib/src/epub/epub_parser.dart').readAsStringSync();

      // 剥掉注释，否则文档里解释坑的那几行会被判据自己命中（假红）。
      final String code = source
          .split('\n')
          .where((String line) => !line.trimLeft().startsWith('//'))
          .join('\n');

      // 裸 findAllElements('foo') —— 即不带 namespace 参数的调用。
      final RegExp bareFindAll =
          RegExp(r"findAllElements\(\s*'[^']*'\s*\)", multiLine: true);
      expect(bareFindAll.allMatches(code).map((Match m) => m.group(0)).toList(),
          isEmpty,
          reason: 'findAllElements 不传 namespace 时按 qualified name 匹配，'
              '带 opf:/ncx: 前缀的包文档会解析成空 → 整本书 0 章。改走 _elements()');

      final RegExp bareGetElement =
          RegExp(r"getElement\(\s*'[^']*'\s*\)", multiLine: true);
      expect(
          bareGetElement.allMatches(code).map((Match m) => m.group(0)).toList(),
          isEmpty,
          reason: 'getElement 同理，改走 _childElement()');

      // 两个原语必须还在，且确实传了 namespace: '*'——否则上面两条断言会
      // 因为「一处调用都没有」而恒真空转。
      expect(
          code.contains("findAllElements(localName, namespace: '*')"), isTrue,
          reason: '_elements 原语被改名/删除，本组守卫已失去锚点');
      expect(code.contains("getElement(localName, namespace: '*')"), isTrue,
          reason: '_childElement 原语被改名/删除，本组守卫已失去锚点');
      expect(RegExp(r'_elements\(').allMatches(code).length, greaterThan(5),
          reason: '解析器应有多处走 _elements；数量塌到个位说明查找被改回裸调用');
    });
  });
}

// ── 样本构造 ────────────────────────────────────────────────────────────────

/// 复刻用户样本 白夜行_backup.epub 的形状：OPF **在 zip 根目录**（不是 OEBPS/），
/// [prefixed] 为 true 时 OPF 与 NCX 整份带前缀。
Uint8List _buildEpub({required bool prefixed}) {
  return _encodeArchive(<ArchiveFile>[
    _textFile('META-INF/container.xml', _containerXmlPlain),
    _textFile('content.opf', _opf(prefixed: prefixed)),
    _textFile('text/chapter-1.xhtml', _chapterXhtml('第一章', '本文その一。')),
    _textFile('text/chapter-2.xhtml', _chapterXhtml('第二章', '本文その二。')),
    _textFile('toc.ncx', _ncx(prefixed: prefixed)),
    _binaryFile('images/cover.jpg'),
  ]);
}

Uint8List _encodeArchive(List<ArchiveFile> files) {
  final Archive archive = Archive();
  for (final ArchiveFile file in files) {
    archive.addFile(file);
  }
  return Uint8List.fromList(ZipEncoder().encode(archive)!);
}

ArchiveFile _textFile(String name, String content) {
  final List<int> bytes = utf8.encode(content);
  return ArchiveFile(name, bytes.length, bytes);
}

/// 一个最小的 JPEG 头，够 parser 把它当图片资源。
ArchiveFile _binaryFile(String name) {
  final List<int> bytes = <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46];
  return ArchiveFile(name, bytes.length, bytes);
}

const String _containerXmlPlain = '<?xml version="1.0" encoding="UTF-8"?>'
    '<container xmlns="urn:oasis:names:tc:opendocument:xmlns:container" '
    'version="1.0"><rootfiles>'
    '<rootfile full-path="content.opf" '
    'media-type="application/oebps-package+xml"/>'
    '</rootfiles></container>';

const String _containerXmlPrefixed = '<?xml version="1.0" encoding="UTF-8"?>'
    '<ocf:container '
    'xmlns:ocf="urn:oasis:names:tc:opendocument:xmlns:container" '
    'version="1.0"><ocf:rootfiles>'
    '<ocf:rootfile full-path="content.opf" '
    'media-type="application/oebps-package+xml"/>'
    '</ocf:rootfiles></ocf:container>';

/// [prefixed] 为 true 时产出 calibre 4.x 那种 `<opf:package>` 形状。
String _opf({required bool prefixed}) {
  final String p = prefixed ? 'opf:' : '';
  final String ns = prefixed
      ? 'xmlns:opf="http://www.idpf.org/2007/opf" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/"'
      : 'xmlns="http://www.idpf.org/2007/opf" '
          'xmlns:dc="http://purl.org/dc/elements/1.1/" '
          'xmlns:opf="http://www.idpf.org/2007/opf"';
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<${p}package $ns unique-identifier="uuid_id" version="2.0">'
      '<${p}metadata>'
      '<dc:language>ja</dc:language>'
      '<dc:title>白夜行</dc:title>'
      '<dc:creator opf:role="aut">東野圭吾</dc:creator>'
      '<${p}meta name="cover" content="cover"/>'
      '</${p}metadata>'
      '<${p}manifest>'
      '<${p}item href="images/cover.jpg" id="cover" media-type="image/jpeg"/>'
      '<${p}item href="text/chapter-1.xhtml" id="c1" '
      'media-type="application/xhtml+xml"/>'
      '<${p}item href="text/chapter-2.xhtml" id="c2" '
      'media-type="application/xhtml+xml"/>'
      '<${p}item href="toc.ncx" id="ncx" '
      'media-type="application/x-dtbncx+xml"/>'
      '</${p}manifest>'
      '<${p}spine toc="ncx">'
      '<${p}itemref idref="c1"/>'
      '<${p}itemref idref="c2"/>'
      '</${p}spine>'
      '</${p}package>';
}

const String _opfWithNav = '<?xml version="1.0" encoding="utf-8"?>'
    '<package xmlns="http://www.idpf.org/2007/opf" '
    'xmlns:dc="http://purl.org/dc/elements/1.1/" '
    'unique-identifier="uuid_id" version="3.0">'
    '<metadata><dc:language>ja</dc:language>'
    '<dc:title>白夜行</dc:title></metadata>'
    '<manifest>'
    '<item href="nav.xhtml" id="nav" media-type="application/xhtml+xml" '
    'properties="nav"/>'
    '<item href="text/chapter-1.xhtml" id="c1" '
    'media-type="application/xhtml+xml"/>'
    '</manifest>'
    '<spine><itemref idref="c1"/></spine>'
    '</package>';

const String _navXhtml = '<?xml version="1.0" encoding="utf-8"?>'
    '<html xmlns="http://www.w3.org/1999/xhtml" '
    'xmlns:epub="http://www.idpf.org/2007/ops"><head><title>目次</title></head>'
    '<body><nav epub:type="toc"><ol>'
    '<li><a href="text/chapter-1.xhtml">第一章</a></li>'
    '</ol></nav></body></html>';

/// [prefixed] 为 true 时产出 `<ncx:navMap>` 形状。
String _ncx({required bool prefixed}) {
  final String p = prefixed ? 'ncx:' : '';
  final String ns = prefixed
      ? 'xmlns:ncx="http://www.daisy.org/z3986/2005/ncx/"'
      : 'xmlns="http://www.daisy.org/z3986/2005/ncx/"';
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<${p}ncx $ns version="2005-1">'
      '<${p}head/>'
      '<${p}docTitle><${p}text>白夜行</${p}text></${p}docTitle>'
      '<${p}navMap>'
      '<${p}navPoint id="n1" playOrder="1">'
      '<${p}navLabel><${p}text>第一章</${p}text></${p}navLabel>'
      '<${p}content src="text/chapter-1.xhtml"/>'
      '</${p}navPoint>'
      '<${p}navPoint id="n2" playOrder="2">'
      '<${p}navLabel><${p}text>第二章</${p}text></${p}navLabel>'
      '<${p}content src="text/chapter-2.xhtml"/>'
      '</${p}navPoint>'
      '</${p}navMap>'
      '</${p}ncx>';
}

String _chapterXhtml(String title, String body) {
  return '<?xml version="1.0" encoding="utf-8"?>'
      '<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="ja">'
      '<head><title>$title</title></head>'
      '<body><h1>$title</h1><p>$body</p></body></html>';
}
