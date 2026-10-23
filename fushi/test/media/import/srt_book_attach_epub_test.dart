import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/import/srt_book_attach_epub.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_engine/media/import/epub_backed_srt_book.dart';
import 'package:path/path.dart' as p;

import '../../pages/reader_history_source_corpus.dart';

/// 反馈 Q0kWQNkF2f / Ulw9gIyZGk：下载 + 自动转录生成的字幕书之后没有任何入口能配上
/// 对应的 EPUB。这里守三件事：
/// 1. 哪些字幕书能「添加书籍文件」（EPUB 有声书的配对行不能——它已有用户正文）；
/// 2. 预填的音频按播放侧口径解析、排序且只含真实存在的文件，字幕缺失时为 null；
/// 3. 书架入口确实把预填交给书籍导入对话框，并强制要求选书（否则没选书点导入会
///    落进字幕书分支，悄悄再生成一本一模一样的字幕书）。
SrtBook _book({
  required String uid,
  String bookKey = '',
  String srtPath = '',
  List<String>? audioPaths,
  String? audioRoot,
}) {
  return SrtBook()
    ..uid = uid
    ..title = 't'
    ..srtPath = srtPath
    ..importedAt = 0
    ..bookKey = bookKey
    ..audioPaths = audioPaths
    ..audioRoot = audioRoot;
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('fushi_srt_attach_epub');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('srtBookCanAttachEpub', () {
    test('cue-generated body book can attach an EPUB', () {
      expect(
        srtBookCanAttachEpub(_book(uid: 'srtbook_1', bookKey: 'k1')),
        isTrue,
      );
    });

    test('orphan subtitle book without body can attach an EPUB', () {
      expect(srtBookCanAttachEpub(_book(uid: 'srtbook_2')), isTrue);
    });

    test('EPUB-backed audiobook pair row cannot attach another EPUB', () {
      expect(
        srtBookCanAttachEpub(
          _book(uid: epubBackedSrtBookUid('k3'), bookKey: 'k3'),
        ),
        isFalse,
      );
    });
  });

  group('resolveSrtBookEpubAttachPrefill', () {
    test('audioRoot is enumerated in playback order; subtitle kept', () async {
      final Directory root = Directory(p.join(tmp.path, 'audio'))..createSync();
      for (final String name in <String>['10.mp3', '2.mp3', '1.mp3']) {
        File(p.join(root.path, name)).writeAsStringSync('x');
      }
      File(p.join(root.path, 'notes.txt')).writeAsStringSync('x');
      final File srt = File(p.join(tmp.path, 'book.srt'))
        ..writeAsStringSync('1\n00:00:00,000 --> 00:00:01,000\nあ\n');

      final SrtBookEpubAttachPrefill prefill =
          await resolveSrtBookEpubAttachPrefill(
            _book(uid: 'srtbook_1', srtPath: srt.path, audioRoot: root.path),
          );

      expect(prefill.audioPaths.map(p.basename).toList(), <String>[
        '1.mp3',
        '2.mp3',
        '10.mp3',
      ]);
      expect(prefill.subtitlePath, srt.path);
    });

    test('explicit audioPaths keep order and drop missing files', () async {
      final File a = File(p.join(tmp.path, 'b.m4a'))..writeAsStringSync('x');
      final File b = File(p.join(tmp.path, 'a.m4a'))..writeAsStringSync('x');
      final String missing = p.join(tmp.path, 'gone.m4a');

      final SrtBookEpubAttachPrefill prefill =
          await resolveSrtBookEpubAttachPrefill(
            _book(
              uid: 'srtbook_1',
              srtPath: p.join(tmp.path, 'missing.srt'),
              audioPaths: <String>[a.path, missing, b.path],
            ),
          );

      expect(prefill.audioPaths, <String>[a.path, b.path]);
      expect(prefill.subtitlePath, isNull);
    });
  });

  test('shelf entry prefills BookImportDialog and requires a book', () {
    final String history = readReaderHistorySource();
    final int start = history.indexOf('Future<void> _attachEpubToSrtBook(');
    expect(start, isNonNegative);
    final int next = history.indexOf('\n  Future<', start + 10);
    final String body = history.substring(start, next < 0 ? null : next);
    expect(body, contains('resolveSrtBookEpubAttachPrefill('));
    expect(body, contains('BookImportDialog('));
    expect(body, contains('requireBook: true'));
    expect(body, contains('initialSubtitlePath: prefill.subtitlePath'));
    expect(history, contains('srtBookCanAttachEpub(book)'));
  });
}
