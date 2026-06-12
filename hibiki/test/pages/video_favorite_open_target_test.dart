import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/pages/implementations/collections_page.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki_core/hibiki_core.dart';

void main() {
  group('resolveVideoFavoriteOpenTarget', () {
    test(
        'playlist favorite carries episode index and cue startMs to video page',
        () {
      final target = resolveVideoFavoriteOpenTarget(
        row: _row(
          playlistJson:
              '[{"title":"E1","path":"/e1.mkv"},{"title":"E2","path":"/e2.mkv"}]',
          currentEpisode: 0,
        ),
        favoriteSectionIndex: 1,
        favoriteStartMs: 42000,
      );

      expect(target.episodeIndex, 1);
      expect(target.startMs, 42000);
    });

    test(
        'playlist legacy favorite without episode anchor degrades to current open',
        () {
      final target = resolveVideoFavoriteOpenTarget(
        row: _row(
          playlistJson:
              '[{"title":"E1","path":"/e1.mkv"},{"title":"E2","path":"/e2.mkv"}]',
          currentEpisode: 1,
        ),
        favoriteSectionIndex: null,
        favoriteStartMs: 42000,
      );

      expect(target.episodeIndex, isNull);
      expect(
        target.startMs,
        isNull,
        reason: '缺少 episode identity 的旧播放列表收藏不能只靠 bookUid+startMs 假装稳定定位',
      );
    });

    test('single video favorite keeps startMs without requiring episode anchor',
        () {
      final target = resolveVideoFavoriteOpenTarget(
        row: _row(playlistJson: null, currentEpisode: 0),
        favoriteSectionIndex: null,
        favoriteStartMs: 12345,
      );

      expect(target.episodeIndex, isNull);
      expect(target.startMs, 12345);
    });

    test('playlist favorite clamps stale episode index before opening video',
        () {
      final target = resolveVideoFavoriteOpenTarget(
        row: _row(
          playlistJson:
              '[{"title":"E1","path":"/e1.mkv"},{"title":"E2","path":"/e2.mkv"}]',
          currentEpisode: 0,
        ),
        favoriteSectionIndex: 99,
        favoriteStartMs: 12345,
      );

      expect(target.episodeIndex, 1);
      expect(target.startMs, 12345);
    });
  });

  group('videoFavoriteCacheKey', () {
    test(
        'single video persisted sectionIndex 0 still matches live cue star key',
        () {
      final String liveCueKey = videoFavoriteCacheKey(
        text: '字幕行',
        startMs: 12345,
        episodeIndex: null,
        isPlaylist: false,
      );
      final String restoredPersistedKey = videoFavoriteCacheKey(
        text: '字幕行',
        startMs: 12345,
        episodeIndex: 0,
        isPlaylist: false,
      );

      expect(restoredPersistedKey, liveCueKey);
      expect(liveCueKey, 'cue|single|12345|字幕行');
    });

    test('playlist keeps episode index in cue favorite cache keys', () {
      final String episode0Key = videoFavoriteCacheKey(
        text: '字幕行',
        startMs: 12345,
        episodeIndex: 0,
        isPlaylist: true,
      );
      final String episode1Key = videoFavoriteCacheKey(
        text: '字幕行',
        startMs: 12345,
        episodeIndex: 1,
        isPlaylist: true,
      );

      expect(episode0Key, 'cue|0|12345|字幕行');
      expect(episode1Key, 'cue|1|12345|字幕行');
      expect(episode0Key, isNot(episode1Key));
    });
  });
}

VideoBookRow _row({
  required String? playlistJson,
  required int currentEpisode,
}) =>
    VideoBookRow(
      bookUid: 'video/playlist/show',
      title: 'Show',
      videoPath: '/e1.mkv',
      lastPositionMs: 0,
      playlistJson: playlistJson,
      currentEpisode: currentEpisode,
      delayMs: 0,
    );
