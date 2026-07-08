import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
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

    // TODO-558 / BUG-326: 蓝光/录播容器格式拖入也要识别成视频（曾漏 mts/vob/rmvb）。
    test('mts / vob / rmvb container formats classify as video', () {
      final r = classifyDroppedFiles(['/x/a.mts', '/x/b.vob', '/x/c.rmvb']);
      expect(r.videos, ['/x/a.mts', '/x/b.vob', '/x/c.rmvb']);
      expect(r.unknown, isEmpty);
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
      // .zip/.dsl/.mdx now classify as dictionary packages (TODO-059); use a
      // genuinely-unhandled extension to exercise the unknown bucket.
      final r = classifyDroppedFiles(['/x/a.bin']);
      expect(r.unknown, ['/x/a.bin']);
      expect(r.dictionaries, isEmpty);
    });

    test('zip / dsl / mdx classify as dictionary packages (TODO-059)', () {
      final r = classifyDroppedFiles(['/x/a.zip', '/x/b.dsl', '/x/c.mdx']);
      expect(r.dictionaries, ['/x/a.zip', '/x/b.dsl', '/x/c.mdx']);
      expect(r.unknown, isEmpty);
      expect(r.books, isEmpty);
      expect(r.hasAny, isTrue);
    });

    test('dictionary extension match is case-insensitive', () {
      final r = classifyDroppedFiles(['/x/A.ZIP', '/x/B.Dsl']);
      expect(r.dictionaries, ['/x/A.ZIP', '/x/B.Dsl']);
    });

    test('dictionary packages count toward hasAny', () {
      expect(classifyDroppedFiles(['/x/a.zip']).hasAny, isTrue);
    });

    // TODO-1306: 浏览器地址栏/链接拖进来的 http(s) URL 不是文件路径，按 scheme 甄别
    // 落到 urls，绝不当 unknown 丢弃。
    test('http/https url goes to urls (not unknown, not video)', () {
      final r = classifyDroppedFiles(
          ['https://youtu.be/abc', 'http://example.com/live']);
      expect(r.urls, ['https://youtu.be/abc', 'http://example.com/live']);
      expect(r.unknown, isEmpty);
      expect(r.videos, isEmpty);
      expect(r.hasAny, isTrue);
    });

    // URL 末段带 .mp4 也归 urls（交给流媒体导入），不被扩展名分类拽进 videos。
    test('url with a video-looking path stays in urls (not videos)', () {
      final r = classifyDroppedFiles(['https://cdn.test/movie.mp4']);
      expect(r.urls, ['https://cdn.test/movie.mp4']);
      expect(r.videos, isEmpty);
      expect(r.audios, isEmpty);
    });

    // Windows 盘符路径 `C:\...` 的 Uri scheme 会被解析成 'c'，绝不能误判为 URL。
    test('Windows drive path is NOT misclassified as a url', () {
      final r = classifyDroppedFiles([r'C:\movies\a.mkv']);
      expect(r.urls, isEmpty);
      expect(r.videos, [r'C:\movies\a.mkv']);
    });

    // 非 http(s)（file:// / 裸路径 / ftp）不是可导入 URL。
    test('non-http schemes and bare paths are not urls', () {
      final r =
          classifyDroppedFiles(['file:///x/a.mkv', '/x/a.epub', 'ftp://h/x']);
      expect(r.urls, isEmpty);
    });

    // 混合拖入：URL + 本地文件各归各类。
    test('mixed url + local file classify independently', () {
      final r = classifyDroppedFiles(['https://x.test/v', r'C:\x\a.epub']);
      expect(r.urls, ['https://x.test/v']);
      expect(r.books, [r'C:\x\a.epub']);
    });

    test('url counts toward hasAny', () {
      expect(classifyDroppedFiles(['https://x.test/v']).hasAny, isTrue);
    });

    test('isEmpty true when nothing classified into media', () {
      expect(classifyDroppedFiles([]).hasAny, isFalse);
      expect(classifyDroppedFiles(['/x/a.epub']).hasAny, isTrue);
    });
  });

  test('kDragVideoExtensions stays in sync with kVideoExtensions (folder scan)',
      () {
    // 文件夹扫描用 kVideoExtensions（带点），拖放用 kDragVideoExtensions（不带点）。
    // 两者漂移会导致「文件夹按钮能扫到、拖放却识别不出」同一个视频（TODO-558）。
    final Set<String> scan =
        kVideoExtensions.map((String e) => e.replaceFirst('.', '')).toSet();
    expect(
      kDragVideoExtensions,
      equals(scan),
      reason:
          '视频扩展名漂移：更新 kDragVideoExtensions 与 kVideoExtensions（video_filename_parser.dart）保持一致',
    );
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
