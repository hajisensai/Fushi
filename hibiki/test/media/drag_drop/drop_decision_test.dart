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
    test('recognized video on books surface -> unsupportedSurface', () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(videos: ['/a.mkv']),
            cardHit: false),
        DropIntent.unsupportedSurface,
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
    test(
        'm3u8 on books surface -> unsupportedSurface (playlists are video-only)',
        () {
      expect(
        decideDropIntent(
            surface: DropSurface.books,
            files: _files(playlists: ['/a.m3u8']),
            cardHit: false),
        DropIntent.unsupportedSurface,
      );
    });
  });
}
