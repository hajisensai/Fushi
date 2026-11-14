// 用户导入一本没下载完的 EPUB（130 KB，停在第 6 个正文条目中途，没有 zip 中央
// 目录与尾记录），archive 抛 `FormatException: Could not find End of Central
// Directory Record`，导入弹窗把这句英文原样 toast 出来。解析器须把 zip 层失败
// 统一成 [EpubArchiveCorruptException]，UI 才能提示「文件不完整，请重新下载」。
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
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

  test('intact EPUB still parses', () {
    final File ok = File(p.join(tmp.path, 'ok.epub'))
      ..writeAsBytesSync(_validEpubBytes());
    expect(
      () => EpubParser.parseSyncFromPath(ok.path, p.join(tmp.path, 'out2')),
      returnsNormally,
    );
  });
}
