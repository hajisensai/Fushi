import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/audiobook/text_to_epub.dart';

import '../../helpers/epub_zip_reader.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

Future<EpubZipReader> _convertText(
  Directory dir,
  String content, {
  String name = 'input.txt',
  String title = 'テスト本',
  String? author,
}) async {
  final File file = File('${dir.path}/$name');
  file.writeAsStringSync(content);
  final bytes = await TextToEpub.convert(
    file: file,
    title: title,
    author: author,
  );
  return EpubZipReader(bytes);
}

// ── tests ────────────────────────────────────────────────────────────────────

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('text_to_epub_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  test('isSupported accepts known extensions and rejects others', () {
    expect(TextToEpub.isSupported('a.txt'), isTrue);
    expect(TextToEpub.isSupported('a.md'), isTrue);
    expect(TextToEpub.isSupported('a.HTML'), isTrue);
    expect(TextToEpub.isSupported('a.epub'), isFalse);
    expect(TextToEpub.isSupported('a.mp3'), isFalse);
  });

  test('mimetype is the first entry, stored, with the EPUB media type',
      () async {
    final reader = await _convertText(tmpDir, 'こんにちは。\n\n二段落目。');
    expect(reader.firstEntry, 'mimetype');
    expect(reader.firstEntryMethod, 0); // STORE per EPUB spec
    expect(reader['mimetype'], 'application/epub+zip');
  });

  test('container structure and OPF metadata are generated', () async {
    final reader = await _convertText(
      tmpDir,
      'こんにちは。',
      title: 'A & B <C>',
      author: "O'Brien",
    );
    expect(
      reader.names,
      containsAll(<String>{
        'META-INF/container.xml',
        'OEBPS/content.opf',
        'OEBPS/toc.ncx',
        'OEBPS/nav.xhtml',
        'OEBPS/chapter-1.xhtml',
      }),
    );
    expect(
      reader['META-INF/container.xml'],
      contains('full-path="OEBPS/content.opf"'),
    );

    final String opf = reader['OEBPS/content.opf']!;
    // Identity prefix distinguishes text-generated books; must stay stable.
    expect(opf, contains('<dc:identifier id="uid">hibiki-text-'));
    expect(opf, contains('<dc:title>A &amp; B &lt;C&gt;</dc:title>'));
    expect(opf, contains('<dc:creator>O&apos;Brien</dc:creator>'));
    expect(opf, contains('<itemref idref="chapter-1"/>'));
  });

  test('plain text paragraphs become <p>, single newlines become <br/>',
      () async {
    final reader = await _convertText(
      tmpDir,
      '一行目\n二行目\n\n次の段落',
    );
    final String chapter = reader['OEBPS/chapter-1.xhtml']!;
    expect(chapter, contains('<p>一行目<br/>二行目</p>'));
    expect(chapter, contains('<p>次の段落</p>'));
  });

  test('markdown headings map to <hN>', () async {
    final reader = await _convertText(
      tmpDir,
      '# 見出し\n\n本文です。',
      name: 'input.md',
    );
    final String chapter = reader['OEBPS/chapter-1.xhtml']!;
    expect(chapter, contains('<h1>見出し</h1>'));
    expect(chapter, contains('<p>本文です。</p>'));
  });

  test('html input keeps only body content', () async {
    final reader = await _convertText(
      tmpDir,
      '<html><head><title>t</title></head>'
      '<body><p>中身</p></body></html>',
      name: 'input.html',
    );
    final String chapter = reader['OEBPS/chapter-1.xhtml']!;
    expect(chapter, contains('<p>中身</p>'));
    expect(chapter, isNot(contains('<title>t</title>')));
  });

  test('long input splits into multiple chapters at paragraph boundaries',
      () async {
    // Build > kMaxCharsPerChapter of HTML from many paragraphs.
    final String para = '${'あ' * 200}。';
    final String content =
        List<String>.filled(200, para).join('\n\n'); // ~40k chars of <p>
    final reader = await _convertText(tmpDir, content);

    expect(reader.names, contains('OEBPS/chapter-1.xhtml'));
    expect(reader.names, contains('OEBPS/chapter-2.xhtml'));

    final String opf = reader['OEBPS/content.opf']!;
    expect(opf, contains('<itemref idref="chapter-2"/>'));
    // NCX and nav must list every chapter.
    final int chapterCount =
        reader.names.where((n) => n.startsWith('OEBPS/chapter-')).length;
    expect(
      RegExp('<navPoint ').allMatches(reader['OEBPS/toc.ncx']!).length,
      chapterCount,
    );
    expect(
      RegExp('<li>').allMatches(reader['OEBPS/nav.xhtml']!).length,
      chapterCount,
    );
  });
}
