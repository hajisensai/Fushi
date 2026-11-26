import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_library_data.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/pages/implementations/music/music_cover.dart';
import 'package:fushi/src/pages/implementations/music/music_lyrics_backdrop.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

/// BUG-5504（反馈 qGNRXaXNEv / EMjx7gJftH）：只有内嵌封面、没有目录封面的本地曲目，
/// 曲目行有图，播放页 / 迷你播放条 / 队列却是占位音符——播放项只带目录封面。

MusicTrackRow _track(
  String uid, {
  String? albumUid,
  bool hasEmbeddedCover = false,
}) => MusicTrackRow(
  trackUid: uid,
  path: '/music/$uid.flac',
  title: 'Title $uid',
  albumUid: albumUid,
  isLossless: true,
  fileMtimeAt: 1,
  fileSize: 1,
  hasEmbeddedCover: hasEmbeddedCover,
  addedAt: 1,
);

MusicAlbumRow _album(String uid, {String? coverPath, String? coverTrackUid}) =>
    MusicAlbumRow(
      albumUid: uid,
      title: 'Album $uid',
      coverPath: coverPath,
      coverTrackUid: coverTrackUid,
      addedAt: 1,
      updatedAt: 1,
    );

String _read(String path) => File(path).readAsStringSync();

void main() {
  group('musicPlayItemOf 封面来源（与曲目行同一规则）', () {
    test('没有目录封面、曲目带内嵌封面 → 播放项带内嵌封面来源', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', albumUid: 'al', hasEmbeddedCover: true),
        album: _album('al'),
      );
      expect(item.coverPath, isNull);
      expect(item.embeddedCoverPath, '/music/a.flac');
    });

    test('没有专辑的单曲同样带上自己的内嵌封面', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', hasEmbeddedCover: true),
      );
      expect(item.embeddedCoverPath, '/music/a.flac');
    });

    test('目录封面优先：有目录封面时不带内嵌来源', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', albumUid: 'al', hasEmbeddedCover: true),
        album: _album('al', coverPath: '/music/cover.jpg'),
      );
      expect(item.coverPath, '/music/cover.jpg');
      expect(item.embeddedCoverPath, isNull);
    });

    test('显式 coverPath 覆盖专辑封面且不带内嵌来源', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', hasEmbeddedCover: true),
        coverPath: '/cache/x.jpg',
      );
      expect(item.coverPath, '/cache/x.jpg');
      expect(item.embeddedCoverPath, isNull);
    });

    test('专辑选定的封面曲目路径（调用方查好）优先于这首自己的', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('b', albumUid: 'al'),
        album: _album('al', coverTrackUid: 'a'),
        albumEmbeddedPath: '/music/a.flac',
      );
      expect(item.embeddedCoverPath, '/music/a.flac');
    });

    test('都没有 → 两个都为 null（占位）', () {
      final MusicPlayItem item = musicPlayItemOf(
        _track('a', albumUid: 'al'),
        album: _album('al'),
      );
      expect(item.coverPath, isNull);
      expect(item.embeddedCoverPath, isNull);
    });
  });

  group('只认 ImageProvider 的消费方接上内嵌封面', () {
    test('MusicEmbeddedCoverImage 按音频路径判等', () {
      expect(
        const MusicEmbeddedCoverImage('/m/a.flac'),
        const MusicEmbeddedCoverImage('/m/a.flac'),
      );
      expect(
        const MusicEmbeddedCoverImage('/m/a.flac') ==
            const MusicEmbeddedCoverImage('/m/b.flac'),
        isFalse,
      );
    });

    test('取色 provider：无封面文件时退到内嵌封面', () {
      final ImageProvider? p = musicCoverImageProvider(
        null,
        size: 128,
        embeddedFromPath: '/m/a.flac',
      );
      expect(p, isA<ResizeImage>());
      expect(
        (p! as ResizeImage).imageProvider,
        const MusicEmbeddedCoverImage('/m/a.flac'),
      );
      expect(musicCoverImageProvider(null), isNull);
    });

    test('歌词页背景 / 取色 provider：无封面文件时退到内嵌封面', () {
      expect(
        musicLyricsBackdropCoverProvider(null, embeddedFromPath: '/m/a.flac'),
        const MusicEmbeddedCoverImage('/m/a.flac'),
      );
      expect(musicLyricsBackdropCoverProvider(null), isNull);
    });
  });

  test('播放页 / Apple 播放页 / 播放条 / 队列的封面都传了内嵌来源', () {
    const String dir = 'lib/src/pages/implementations/music';
    final Map<String, int> minUses = <String, int>{
      '$dir/music_lyrics_page.dart': 5,
      '$dir/music_lyrics_page_apple.part.dart': 1,
      '$dir/music_now_playing_bar.dart': 2,
      '$dir/music_queue_panel.dart': 2,
    };
    for (final MapEntry<String, int> e in minUses.entries) {
      final int uses = RegExp(
        r'embeddedCoverPath',
      ).allMatches(_read(e.key)).length;
      expect(uses, greaterThanOrEqualTo(e.value), reason: e.key);
    }
  });
}
