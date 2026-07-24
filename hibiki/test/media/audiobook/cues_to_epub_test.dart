import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

import '../../helpers/epub_zip_reader.dart';

// ── helpers ──────────────────────────────────────────────────────────────────

/// Creates a minimal [AudioCue] for testing.
AudioCue _cue({
  required int idx,
  required int startMs,
  required int endMs,
  required String text,
  String bookKey = 'test-book',
}) {
  return AudioCue()
    ..bookKey = bookKey
    ..chapterHref = 'srt://default'
    ..sentenceIndex = idx
    ..textFragmentId = 'srt://$idx'
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

/// Generates an EPUB in [dir] and returns the decoded [EpubZipReader].
Future<EpubZipReader> _generateAndRead(
  Directory dir, {
  required List<AudioCue> cues,
  String title = 'テスト',
  String? author,
}) async {
  final String path = '${dir.path}/out.epub';
  await CuesToEpub.convert(
    title: title,
    author: author,
    cues: cues,
    outputPath: path,
  );
  return EpubZipReader(File(path).readAsBytesSync());
}

// ── tests ─────────────────────────────────────────────────────────────────────

void main() {
  late Directory tmpDir;

  setUp(() {
    tmpDir = Directory.systemTemp.createTempSync('cues_to_epub_test_');
  });

  tearDown(() {
    tmpDir.deleteSync(recursive: true);
  });

  // ── File structure ─────────────────────────────────────────────────────────

  group('EPUB file structure', () {
    test('必須ファイルが全て存在する', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 0, endMs: 1000, text: 'こんにちは。')],
      );
      expect(zip.names, contains('mimetype'));
      expect(zip.names, contains('META-INF/container.xml'));
      expect(zip.names, contains('OEBPS/content.opf'));
      expect(zip.names, contains('OEBPS/toc.ncx'));
      expect(zip.names, contains('OEBPS/nav.xhtml'));
      expect(zip.names, contains('OEBPS/chapter-1.xhtml'));
    });

    test('mimetype が最初のエントリで内容が正しい', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 0, endMs: 1000, text: 'テスト')],
      );
      expect(zip.firstEntry, 'mimetype');
      expect(zip['mimetype'], 'application/epub+zip');
    });

    test('container.xml が OPF を正しく参照する', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 0, endMs: 1000, text: 'テスト')],
      );
      expect(zip['META-INF/container.xml'],
          contains('full-path="OEBPS/content.opf"'));
    });

    test('出力ファイルが実際に作成される', () async {
      final path = '${tmpDir.path}/my_book.epub';
      final file = await CuesToEpub.convert(
        title: 'My Book',
        cues: [_cue(idx: 0, startMs: 0, endMs: 1000, text: 'テスト')],
        outputPath: path,
      );
      expect(file.existsSync(), isTrue);
      expect(file.lengthSync(), greaterThan(0));
    });
  });

  // ── OPF metadata ───────────────────────────────────────────────────────────

  group('content.opf', () {
    test('タイトルと著者が埋め込まれる', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 0, endMs: 1000, text: 'テスト')],
        title: '猫の本',
        author: '夏目漱石',
      );
      expect(zip['OEBPS/content.opf'], contains('<dc:title>猫の本</dc:title>'));
      expect(
          zip['OEBPS/content.opf'], contains('<dc:creator>夏目漱石</dc:creator>'));
    });

    test('著者省略時は dc:creator タグがない', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 0, endMs: 1000, text: 'テスト')],
        title: '本',
        // author: null is the default — omit it
      );
      expect(zip['OEBPS/content.opf'], isNot(contains('dc:creator')));
    });

    test('spine に chapter-1 が含まれる', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 0, endMs: 1000, text: 'テスト')],
      );
      expect(zip['OEBPS/content.opf'], contains('idref="chapter-1"'));
    });

    test('3 章なら spine に chapter-1〜3 が含まれる', () async {
      final cues = List.generate(
        1001,
        (i) => _cue(idx: i, startMs: i * 100, endMs: i * 100 + 50, text: 'A'),
      );
      final zip = await _generateAndRead(tmpDir, cues: cues);
      expect(zip['OEBPS/content.opf'], contains('idref="chapter-1"'));
      expect(zip['OEBPS/content.opf'], contains('idref="chapter-2"'));
      expect(zip['OEBPS/content.opf'], contains('idref="chapter-3"'));
    });
  });

  // ── Chapter XHTML content ──────────────────────────────────────────────────

  group('chapter XHTML', () {
    test('cue テキストが data 属性付き span に含まれる', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [
          _cue(idx: 0, startMs: 1000, endMs: 4230, text: '吾輩は猫である。'),
          _cue(idx: 1, startMs: 4500, endMs: 8100, text: '名前はまだない。'),
        ],
      );
      final xhtml = zip['OEBPS/chapter-1.xhtml']!;
      expect(xhtml, contains('data-cue-id="0"'));
      expect(xhtml, contains('data-start="1.000"'));
      expect(xhtml, contains('data-end="4.230"'));
      expect(xhtml, contains('吾輩は猫である。'));
      expect(xhtml, contains('data-cue-id="1"'));
      expect(xhtml, contains('名前はまだない。'));
    });

    test('cue なしでも chapter-1.xhtml が生成される', () async {
      final zip = await _generateAndRead(tmpDir, cues: []);
      expect(zip['OEBPS/chapter-1.xhtml'], isNotNull);
    });
  });

  // ── Paragraph grouping ─────────────────────────────────────────────────────

  group('段落分割', () {
    test('ギャップ < 2s → 同じ <p> に入る', () async {
      // gap = 400ms < 2000ms
      final zip = await _generateAndRead(
        tmpDir,
        cues: [
          _cue(idx: 0, startMs: 0, endMs: 1000, text: 'A'),
          _cue(idx: 1, startMs: 1400, endMs: 2000, text: 'B'),
        ],
      );
      final xhtml = zip['OEBPS/chapter-1.xhtml']!;
      expect(RegExp('<p>').allMatches(xhtml).length, 1);
    });

    test('ギャップ > 2s → 別の <p> に分かれる', () async {
      // gap = 3000ms > 2000ms
      final zip = await _generateAndRead(
        tmpDir,
        cues: [
          _cue(idx: 0, startMs: 0, endMs: 1000, text: 'A'),
          _cue(idx: 1, startMs: 4000, endMs: 5000, text: 'B'),
        ],
      );
      final xhtml = zip['OEBPS/chapter-1.xhtml']!;
      expect(RegExp('<p>').allMatches(xhtml).length, 2);
    });

    test('ちょうど 2000ms のギャップ → 同じ <p>（境界値）', () async {
      // gap = 2000ms is NOT > kParagraphGapMs, so same paragraph
      final zip = await _generateAndRead(
        tmpDir,
        cues: [
          _cue(idx: 0, startMs: 0, endMs: 1000, text: 'A'),
          _cue(idx: 1, startMs: 3000, endMs: 4000, text: 'B'),
        ],
      );
      final xhtml = zip['OEBPS/chapter-1.xhtml']!;
      expect(RegExp('<p>').allMatches(xhtml).length, 1);
    });
  });

  // ── Chapter splitting ──────────────────────────────────────────────────────

  group('チャプター分割', () {
    test('500 cue → 1 章', () async {
      final cues = List.generate(
        500,
        (i) => _cue(idx: i, startMs: i * 100, endMs: i * 100 + 50, text: 'X'),
      );
      final zip = await _generateAndRead(tmpDir, cues: cues);
      expect(zip['OEBPS/chapter-1.xhtml'], isNotNull);
      expect(zip.names, isNot(contains('OEBPS/chapter-2.xhtml')));
    });

    test('501 cue → 2 章', () async {
      final cues = List.generate(
        501,
        (i) => _cue(idx: i, startMs: i * 100, endMs: i * 100 + 50, text: 'X'),
      );
      final zip = await _generateAndRead(tmpDir, cues: cues);
      expect(zip['OEBPS/chapter-1.xhtml'], isNotNull);
      expect(zip['OEBPS/chapter-2.xhtml'], isNotNull);
      expect(zip.names, isNot(contains('OEBPS/chapter-3.xhtml')));
    });

    test('10 分超で章境界', () async {
      const tenMinMs = CuesToEpub.kMaxChapterDurationMs;
      final cues = [
        _cue(idx: 0, startMs: 0, endMs: tenMinMs - 1000, text: 'A'),
        _cue(
            idx: 1,
            startMs: tenMinMs + 1000,
            endMs: tenMinMs + 2000,
            text: 'B'),
      ];
      final zip = await _generateAndRead(tmpDir, cues: cues);
      expect(zip['OEBPS/chapter-2.xhtml'], isNotNull);
    });

    test('空 cue リストでも chapter-1 が生成される', () async {
      final zip = await _generateAndRead(tmpDir, cues: []);
      expect(zip['OEBPS/chapter-1.xhtml'], isNotNull);
      expect(zip.names, isNot(contains('OEBPS/chapter-2.xhtml')));
    });
  });

  // ── XML escaping ───────────────────────────────────────────────────────────

  group('XML エスケープ', () {
    test("& < > \" ' がエスケープされる", () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [
          _cue(
            idx: 0,
            startMs: 0,
            endMs: 1000,
            text: "A&B <tag> \"quote\" 'apos'",
          ),
        ],
      );
      final xhtml = zip['OEBPS/chapter-1.xhtml']!;
      expect(xhtml, contains('A&amp;B'));
      expect(xhtml, contains('&lt;tag&gt;'));
      expect(xhtml, contains('&quot;quote&quot;'));
      expect(xhtml, contains('&apos;apos&apos;'));
    });

    test('タイトルの特殊文字も OPF でエスケープ', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 0, endMs: 1000, text: 'テスト')],
        title: 'A & B',
      );
      expect(
          zip['OEBPS/content.opf'], contains('<dc:title>A &amp; B</dc:title>'));
    });
  });

  // ── Timestamp precision ────────────────────────────────────────────────────

  group('タイムスタンプ精度', () {
    test('ミリ秒が 3 桁小数で出力される', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 1234, endMs: 5678, text: 'テスト')],
      );
      final xhtml = zip['OEBPS/chapter-1.xhtml']!;
      expect(xhtml, contains('data-start="1.234"'));
      expect(xhtml, contains('data-end="5.678"'));
    });

    test('ちょうど 1 秒 (1000ms) は 1.000 になる', () async {
      final zip = await _generateAndRead(
        tmpDir,
        cues: [_cue(idx: 0, startMs: 1000, endMs: 2000, text: 'テスト')],
      );
      final xhtml = zip['OEBPS/chapter-1.xhtml']!;
      expect(xhtml, contains('data-start="1.000"'));
      expect(xhtml, contains('data-end="2.000"'));
    });
  });
}
