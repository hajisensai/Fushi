import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki_audio/hibiki_audio.dart';

void main() {
  group('classifyDroppedFiles', () {
    test('epub goes to books', () {
      final r = classifyDroppedFiles([r'C:\x\a.epub']);
      expect(r.books, [r'C:\x\a.epub']);
      expect(r.videos, isEmpty);
      expect(r.subtitles, isEmpty);
      expect(r.audios, isEmpty);
    });

    test('text formats go to books', () {
      final r = classifyDroppedFiles(['/x/a.txt', '/x/b.md']);
      expect(r.books, ['/x/a.txt', '/x/b.md']);
    });

    test('subtitle extensions go to subtitles', () {
      final r = classifyDroppedFiles(
          ['/x/a.srt', '/x/b.vtt', '/x/c.ass', '/x/d.ssa', '/x/e.lrc']);
      expect(r.subtitles, hasLength(5));
    });

    test('mp4 is BOTH video and audio (resolved by drop surface)', () {
      final r = classifyDroppedFiles(['/x/movie.mp4']);
      expect(r.videos, ['/x/movie.mp4']);
      expect(r.audios, ['/x/movie.mp4']);
    });

    test('mkv is video only', () {
      final r = classifyDroppedFiles(['/x/a.mkv']);
      expect(r.videos, ['/x/a.mkv']);
      expect(r.audios, isEmpty);
    });

    test('mp3 is audio only', () {
      final r = classifyDroppedFiles(['/x/a.mp3']);
      expect(r.audios, ['/x/a.mp3']);
      expect(r.videos, isEmpty);
    });

    test('extension match is case-insensitive', () {
      final r = classifyDroppedFiles(['/x/A.EPUB', '/x/B.SRT']);
      expect(r.books, ['/x/A.EPUB']);
      expect(r.subtitles, ['/x/B.SRT']);
    });

    test('m3u8 / m3u go to playlists (not unknown, not video)', () {
      final r = classifyDroppedFiles(['/x/a.m3u8', '/x/b.m3u']);
      expect(r.playlists, ['/x/a.m3u8', '/x/b.m3u']);
      expect(r.videos, isEmpty);
      expect(r.unknown, isEmpty);
    });

    test('m3u8 match is case-insensitive', () {
      final r = classifyDroppedFiles(['/x/A.M3U8']);
      expect(r.playlists, ['/x/A.M3U8']);
    });

    test('playlist counts toward hasAny', () {
      expect(classifyDroppedFiles(['/x/a.m3u8']).hasAny, isTrue);
    });

    test('unknown extension goes to unknown', () {
      final r = classifyDroppedFiles(['/x/a.zip']);
      expect(r.unknown, ['/x/a.zip']);
    });

    test('isEmpty true when nothing classified into media', () {
      expect(classifyDroppedFiles([]).hasAny, isFalse);
      expect(classifyDroppedFiles(['/x/a.epub']).hasAny, isTrue);
    });
  });

  test(
      'kDragAudioExtensions stays in sync with AudiobookStorage.audioExtensions',
      () {
    // AudiobookStorage 用带点小写扩展名；本表不带点。规整后比较。
    final Set<String> storage = AudiobookStorage.audioExtensions
        .map((String e) => e.replaceFirst('.', ''))
        .toSet();
    expect(
      kDragAudioExtensions,
      equals(storage),
      reason:
          '音频扩展名漂移：更新 kDragAudioExtensions 与 AudiobookStorage.audioExtensions 保持一致',
    );
  });
}
