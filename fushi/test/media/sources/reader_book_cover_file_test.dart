// BUG-4913：阅读器制卡 / 播放条的封面必须与书架字幕书卡同序——配对
// srt_books.cover_path 优先，再退回正文 EPUB 封面。字幕 + 音频导入的乐曲正文 EPUB
// 没有 cover-image，以前只看 EPUB，制出的卡 Lapis Picture 一律为空。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/sources/book_cover_file_resolver.dart';
import 'package:path/path.dart' as p;

void main() {
  late Directory root;
  late String extractDir;

  setUp(() {
    root = Directory.systemTemp.createTempSync('bug4913_cover_');
    extractDir = p.join(root.path, 'extract');
    Directory(p.join(extractDir, 'OEBPS')).createSync(recursive: true);
  });

  tearDown(() => root.deleteSync(recursive: true));

  String writeFile(String path) {
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(<int>[0xFF, 0xD8, 0xFF]);
    return path;
  }

  test('字幕生成的正文 EPUB 没有封面时，用配对字幕书的封面（乐曲制卡）', () {
    final String srtCover = writeFile(
      p.join(root.path, 'persist', 'cover.jpg'),
    );

    expect(
      resolveReaderBookCoverFilePath(
        pairedSrtCoverPath: srtCover,
        extractDir: extractDir,
        coverHref: null,
      ),
      srtCover,
    );
  });

  test('两处都有时与书架同序：字幕书封面优先于 EPUB 封面', () {
    final String srtCover = writeFile(
      p.join(root.path, 'persist', 'cover.png'),
    );
    writeFile(p.join(extractDir, 'OEBPS', 'cover.jpg'));

    expect(
      resolveReaderBookCoverFilePath(
        pairedSrtCoverPath: srtCover,
        extractDir: extractDir,
        coverHref: 'OEBPS/cover.jpg',
      ),
      srtCover,
    );
  });

  test('字幕书封面文件已不在时退回 EPUB 封面', () {
    final String epubCover = writeFile(
      p.join(extractDir, 'OEBPS', 'cover.jpg'),
    );

    expect(
      resolveReaderBookCoverFilePath(
        pairedSrtCoverPath: p.join(root.path, 'persist', 'gone.jpg'),
        extractDir: extractDir,
        coverHref: 'OEBPS/cover.jpg',
      ),
      epubCover,
    );
  });

  test('没有配对字幕书：普通 EPUB 照旧解析自己的封面', () {
    final String epubCover = writeFile(
      p.join(extractDir, 'OEBPS', 'cover.jpg'),
    );

    expect(
      resolveReaderBookCoverFilePath(
        extractDir: extractDir,
        coverHref: 'OEBPS/cover.jpg',
      ),
      epubCover,
    );
  });

  test('哪儿都没有封面返回 null；解压目录未就绪也不抛', () {
    expect(
      resolveReaderBookCoverFilePath(
        pairedSrtCoverPath: '',
        extractDir: extractDir,
      ),
      isNull,
    );
    expect(resolveReaderBookCoverFilePath(), isNull);
  });

  // 制卡 / 播放条 / 快捷设置 / TTS 通知 / 伴屏都得走 `_bookCoverFilePath`；直接调
  // EPUB-only 的 resolveCoverFilePath 就是本 bug 的原样回归。歌词插图那一处只拿 OPF
  // 封面去重插图（不是展示封面），保留。
  test('阅读器的封面消费点不绕过共享入口直读 EPUB 封面', () {
    const String dir = 'lib/src/pages/implementations/reader_fushi';
    final Map<String, int> allowed = <String, int>{'lyrics.part.dart': 1};
    for (final String name in <String>[
      'mining.part.dart',
      'chrome.part.dart',
      'tts.part.dart',
      'companion.part.dart',
      'lyrics.part.dart',
    ]) {
      final String src = File(p.join(dir, name)).readAsStringSync();
      expect(
        'resolveCoverFilePath('.allMatches(src).length,
        allowed[name] ?? 0,
        reason: name,
      );
    }
    final String mining = File(
      p.join(dir, 'mining.part.dart'),
    ).readAsStringSync();
    expect(mining, contains(': _bookCoverFilePath;'));
  });
}
