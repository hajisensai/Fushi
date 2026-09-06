import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:path/path.dart' as p;

/// `EpubParser.readLanguageSync`：只读 OPF 的 `dc:language`，不解压到磁盘——
/// 转录弹层用它在导入前推语言初值。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('epub_lang_test_');
  });
  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String writeEpub({
    required Map<String, String> entries,
    String name = 'book.epub',
  }) {
    final Archive archive = Archive();
    entries.forEach((String path, String text) {
      final List<int> bytes = utf8.encode(text);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    });
    final File file = File(p.join(tmp.path, name))
      ..writeAsBytesSync(ZipEncoder().encode(archive)!);
    return file.path;
  }

  String opf(String? language) => '''
<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>t</dc:title>
    ${language == null ? '' : '<dc:language>$language</dc:language>'}
  </metadata>
  <manifest/>
  <spine/>
</package>
''';

  const String container = '''
<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>
''';

  test('读出 dc:language，不需要 spine / 章节存在', () {
    final String path = writeEpub(
      entries: <String, String>{
        'META-INF/container.xml': container,
        'OEBPS/content.opf': opf('ja-JP'),
      },
    );
    expect(EpubParser.readLanguageSync(path), 'ja-JP');
    // 没往磁盘解压任何东西。
    expect(
      tmp.listSync().map((FileSystemEntity e) => p.basename(e.path)),
      <String>['book.epub'],
    );
  });

  test('小写 meta-inf 也能定位 container.xml', () {
    final String path = writeEpub(
      entries: <String, String>{
        'meta-inf/container.xml': container,
        'OEBPS/content.opf': opf('en'),
      },
    );
    expect(EpubParser.readLanguageSync(path), 'en');
  });

  test('没写语言 / 缺 container.xml / 缺 OPF → null，不抛', () {
    expect(
      EpubParser.readLanguageSync(
        writeEpub(
          name: 'nolang.epub',
          entries: <String, String>{
            'META-INF/container.xml': container,
            'OEBPS/content.opf': opf(null),
          },
        ),
      ),
      isNull,
    );
    expect(
      EpubParser.readLanguageSync(
        writeEpub(
          name: 'nocontainer.epub',
          entries: <String, String>{'OEBPS/content.opf': opf('ja')},
        ),
      ),
      isNull,
    );
    expect(
      EpubParser.readLanguageSync(
        writeEpub(
          name: 'noopf.epub',
          entries: <String, String>{'META-INF/container.xml': container},
        ),
      ),
      isNull,
    );
  });

  test('不是 zip 的文件照常抛，由调用方决定记日志', () {
    final File bad = File(p.join(tmp.path, 'bad.epub'))
      ..writeAsStringSync('not a zip');
    expect(() => EpubParser.readLanguageSync(bad.path), throwsA(anything));
  });
}
