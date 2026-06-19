import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/drop_decision.dart';

DroppedFiles _files({
  List<String> books = const [],
  List<String> videos = const [],
  List<String> subtitles = const [],
  List<String> audios = const [],
  List<String> playlists = const [],
  List<String> dictionaries = const [],
}) =>
    DroppedFiles(
        books: books,
        videos: videos,
        subtitles: subtitles,
        audios: audios,
        playlists: playlists,
        dictionaries: dictionaries,
        unknown: const []);

void main() {
  group('decideDropIntent — books surface', () {
    test('book file -> importNewBook', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(books: ['/a.epub']),
            cardHit: false),
        DropIntent.importNewBook,
      );
    });
    test('subtitle on a card -> attachToBookCard', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(subtitles: ['/a.srt']),
            cardHit: true),
        DropIntent.attachToBookCard,
      );
    });
    test('audio not on a card -> needCardTarget', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(audios: ['/a.mp3']),
            cardHit: false),
        DropIntent.needCardTarget,
      );
    });
    test('book wins over subtitle when both dropped', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(books: ['/a.epub'], subtitles: ['/a.srt']),
            cardHit: false),
        DropIntent.importNewBook,
      );
    });
    // TODO-558 / BUG-326: 书架拖入视频 → 自动切到视频导入（不再 unsupportedSurface 只提示）。
    test('video on books surface -> importNewVideo (auto-switch)', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mkv']),
            cardHit: false),
        DropIntent.importNewVideo,
      );
    });
    // .mp4 既是 video 又是 audio：拖到书卡时仍优先挂音频（保留原行为），不误判成新建视频。
    test('mp4 on a book card -> attachToBookCard (audio, not new video)', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mp4'], audios: ['/a.mp4']),
            cardHit: true),
        DropIntent.attachToBookCard,
      );
    });
    // .mp4 拖到书架空白处（非命中卡）→ 当作视频自动切到视频导入。
    test('mp4 on books surface blank area -> importNewVideo', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mp4'], audios: ['/a.mp4']),
            cardHit: false),
        DropIntent.importNewVideo,
      );
    });

    test('unknown-only input -> ignore', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: const DroppedFiles(
                books: [],
                videos: [],
                subtitles: [],
                audios: [],
                playlists: [],
                dictionaries: [],
                unknown: ['/a.bin']),
            cardHit: false),
        DropIntent.ignore,
      );
    });
  });

  group('decideDropIntent — video surface', () {
    test('video file -> importNewVideo', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(videos: ['/a.mkv']),
            cardHit: false),
        DropIntent.importNewVideo,
      );
    });
    test('subtitle on a video card -> attachToVideoCard', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(subtitles: ['/a.srt']),
            cardHit: true),
        DropIntent.attachToVideoCard,
      );
    });
    test('subtitle not on a card -> needCardTarget', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(subtitles: ['/a.srt']),
            cardHit: false),
        DropIntent.needCardTarget,
      );
    });
    test('audio-only on video surface -> unsupportedSurface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(audios: ['/a.mp3']),
            cardHit: true),
        DropIntent.unsupportedSurface,
      );
    });
    test('m3u8 playlist -> importNewPlaylist', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importNewPlaylist,
      );
    });
    test('playlist wins over video when both dropped', () {
      expect(
        decideDropIntent(
            surface: DropSurface.video,
            files: _files(videos: ['/a.mkv'], playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importNewPlaylist,
      );
    });
  });

  group('decideDropIntent — playlist on books surface', () {
    // TODO-558 / BUG-326: 书架拖入 m3u8 → 自动切到视频导入（解析多集），不再只提示。
    test('m3u8 on books surface -> importNewPlaylist (auto-switch)', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importNewPlaylist,
      );
    });
    // 播放列表比单视频更具体：两者同拖时优先播放列表（与 video 表面对称）。
    test('playlist wins over video on books surface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mkv'], playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.importNewPlaylist,
      );
    });
  });
}
