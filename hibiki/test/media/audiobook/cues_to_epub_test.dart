import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/audiobook/audiobook_model.dart';
import 'package:hibiki/src/media/audiobook/cues_to_epub.dart';

// ── Minimal ZIP reader for tests (no external deps) ──────────────────────────
//
// Reads the Central Directory to enumerate entries, then reads each Local
// File Header to locate file data.  Supports STORE and DEFLATE.

class _ZipReader {
  _ZipReader(Uint8List bytes) : _b = bytes;
  final Uint8List _b;
  late final Map<String, String> _files = _parseAll();

  /// Returns all file names in the ZIP.
  Set<String> get names => _files.keys.toSet();

  /// Returns the UTF-8 content of [name], or null if absent.
  String? operator [](String name) => _files[name];

  /// Returns the name of the very first entry (by local offset 0).
  String get firstEntry {
    // Signature of local file header: PK\x03\x04
    // The very first local header should be at offset 0.
    final int nameLen = _u16(26);
    return utf8.decode(_b.sublist(30, 30 + nameLen));
  }

  Map<String, String> _parseAll() {
    final result = <String, String>{};
    // Find end of central directory (signature 0x06054b50, last 22 bytes minimum)
    int eocdOffset = _findEocd();
    final int cdOffset = _u32(eocdOffset + 16);
    final int cdEntries = _u16(eocdOffset + 10);

    int pos = cdOffset;
    for (int i = 0; i < cdEntries; i++) {
      // Central directory entry signature: 0x02014b50
      final int nameLen = _u16(pos + 28);
      final int extraLen = _u16(pos + 30);
      final int commentLen = _u16(pos + 32);
      final int localOffset = _u32(pos + 42);
      final String name = utf8.decode(_b.sublist(pos + 46, pos + 46 + nameLen));

      // Read local file header for data offset
      // Local file header sig: 0x04034b50
      final int lNameLen = _u16(localOffset + 26);
      final int lExtraLen = _u16(localOffset + 28);
      final int method = _u16(localOffset + 8);
      final int compSize = _u32(localOffset + 18);
      final int dataStart = localOffset + 30 + lNameLen + lExtraLen;

      final Uint8List raw = _b.sublist(dataStart, dataStart + compSize);
      final Uint8List data;
      if (method == 0) {
        data = raw; // STORE
      } else {
        // DEFLATE (raw, wbits = -15)
        data = Uint8List.fromList(ZLibCodec(raw: true).decode(raw));
      }
      result[name] = utf8.decode(data);

      pos += 46 + nameLen + extraLen + commentLen;
    }
    return result;
  }

  int _findEocd() {
    // Search backwards for EOCD signature 0x06054b50
    for (int i = _b.length - 22; i >= 0; i--) {
      if (_b[i] == 0x50 &&
          _b[i + 1] == 0x4b &&
          _b[i + 2] == 0x05 &&
          _b[i + 3] == 0x06) {
        return i;
      }
    }
    throw StateError('EOCD signature not found — not a valid ZIP');
  }

  int _u16(int offset) =>
      _b[offset] | (_b[offset + 1] << 8);

  int _u32(int offset) =>
      _b[offset] |
      (_b[offset + 1] << 8) |
      (_b[offset + 2] << 16) |
      (_b[offset + 3] << 24);
}


// ── helpers ──────────────────────────────────────────────────────────────────

/// Creates a minimal [AudioCue] for testing.
AudioCue _cue({
  required int idx,
  required int startMs,
  required int endMs,
  required String text,
  String bookUid = 'test-book',
}) {
  return AudioCue()
    ..bookUid = bookUid
    ..chapterHref = 'srt://default'
    ..sentenceIndex = idx
    ..textFragmentId = 'srt://$idx'
    ..text = text
    ..startMs = startMs
    ..endMs = endMs
    ..audioFileIndex = 0;
}

/// Generates an EPUB in [dir] and returns the decoded [_ZipReader].
Future<_ZipReader> _generateAndRead(
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
  return _ZipReader(File(path).readAsBytesSync());
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
      expect(zip['META-INF/container.xml'], contains('full-path="OEBPS/content.opf"'));
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
      expect(zip['OEBPS/content.opf'], contains('<dc:creator>夏目漱石</dc:creator>'));
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
        _cue(idx: 1, startMs: tenMinMs + 1000, endMs: tenMinMs + 2000, text: 'B'),
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
      expect(zip['OEBPS/content.opf'], contains('<dc:title>A &amp; B</dc:title>'));
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
