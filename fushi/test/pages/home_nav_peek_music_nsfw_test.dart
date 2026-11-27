// BUG-5592：侧栏音乐速览卡不模糊 NSFW 专辑封面。音乐分支构造速览条目时没传
// blurCover（书 / 视频 / 游戏都传了）。修法按类：速览各模块统一经
// [NavPeekNsfwJudge] 判，带封面的 [AdaptiveNavPeekEntry] 默认构造强制 blurCover，
// 漏判编不过；音乐判定与系统媒体卡共用 [MediaNsfwSnapshot.isMusicItemNsfw]。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/music/music_output_backend.dart'
    show MusicPlayItem;
import 'package:fushi/src/media/music/music_session.dart'
    show musicMediaSessionArtHidden;
import 'package:fushi/src/media/nsfw/media_nsfw_cover.dart'
    show MediaNsfwTarget;
import 'package:fushi/src/pages/implementations/home_nav_peek.dart';
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show AdaptiveNavPeekEntry;
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/privacy/media_nsfw.dart';

String _code(String path) => File(path).readAsStringSync();

/// [source] 里从 [start] 起、到下一个顶层声明前的那一段。
String _section(String source, String start) {
  final int from = source.indexOf(start);
  expect(from, isNonNegative, reason: start);
  final int next = source.indexOf(
    RegExp(r'\n(Future<|AdaptiveNavPeek|class |typedef )'),
    from + start.length,
  );
  return source.substring(from, next < 0 ? source.length : next);
}

void main() {
  late FushiDatabase db;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    await db.writeMusicScanBatch(
      MusicScanBatchWrite(
        tracks: <MusicTracksCompanion>[
          for (final String uid in <String>['r18', 'safe'])
            MusicTracksCompanion.insert(
              trackUid: '$uid-01',
              path: '/m/$uid/01.mp3',
              title: '01',
              albumUid: Value<String?>(uid),
              fileMtimeAt: 1,
              fileSize: 1,
              addedAt: 1,
            ),
        ],
        albums: <MusicAlbumsCompanion>[
          for (final String uid in <String>['r18', 'safe'])
            MusicAlbumsCompanion.insert(
              albumUid: uid,
              title: uid,
              coverPath: Value<String?>('/covers/$uid.jpg'),
              addedAt: 1,
              updatedAt: 1,
            ),
        ],
        artists: const <MusicArtistsCompanion>[],
        credits: const <MusicTrackCreditsCompanion>[],
      ),
    );
    await db.setMediaNsfw(TagHostKind.musicAlbum, 'r18', true);
  });

  tearDown(() => db.close());

  test('音乐判定：专辑标记或封面图源（目录封面 / 内嵌封面所在音频）', () async {
    final NavPeekNsfwJudge judge = NavPeekNsfwJudge(
      await MediaNsfwSnapshot.load(db),
    );
    expect(judge.music(albumUid: 'r18'), isTrue);
    expect(judge.music(coverPath: '/covers/r18.jpg'), isTrue);
    expect(judge.music(embeddedFromPath: '/m/r18/01.mp3'), isTrue);
    expect(
      judge.music(
        albumUid: 'safe',
        coverPath: '/covers/safe.jpg',
        embeddedFromPath: '/m/safe/01.mp3',
      ),
      isFalse,
    );
    expect(judge.music(), isFalse);
    // 开关关着：什么都不模糊。
    expect(NavPeekNsfwJudge.off.music(albumUid: 'r18'), isFalse);
    expect(
      NavPeekNsfwJudge.off(const MediaNsfwTarget.musicAlbum('r18')),
      isFalse,
    );
    expect(judge(const MediaNsfwTarget.musicAlbum('r18')), isTrue);
  });

  test('速览与系统媒体卡同一口径（isMusicItemNsfw）', () async {
    final MediaNsfwSnapshot snap = await MediaNsfwSnapshot.load(db);
    final NavPeekNsfwJudge judge = NavPeekNsfwJudge(snap);
    for (final MusicPlayItem item in <MusicPlayItem>[
      const MusicPlayItem(
        trackUid: 'r18-01',
        path: '/m/r18/01.mp3',
        title: 'a',
        albumUid: 'r18',
      ),
      const MusicPlayItem(
        trackUid: 'srv:1',
        path: 'https://x/1',
        title: 'b',
        coverPath: '/covers/r18.jpg',
      ),
      const MusicPlayItem(
        trackUid: 'safe-01',
        path: '/m/safe/01.mp3',
        title: 'c',
        albumUid: 'safe',
        coverPath: '/covers/safe.jpg',
      ),
    ]) {
      expect(
        judge.music(albumUid: item.albumUid, coverPath: item.coverPath),
        musicMediaSessionArtHidden(blur: true, snapshot: snap, item: item),
        reason: item.trackUid,
      );
    }
  });

  test('正在播放条目带上模糊判定', () {
    const MusicPlayItem item = MusicPlayItem(
      trackUid: 'r18-01',
      path: '/m/r18/01.mp3',
      title: 'a',
      albumUid: 'r18',
    );
    expect(
      navPeekNowPlayingEntry(
        item,
        cover: null,
        blurCover: true,
        onOpen: () {},
      ).blurCover,
      isTrue,
    );
    expect(
      navPeekNowPlayingEntry(
        item,
        cover: null,
        blurCover: false,
        onOpen: () {},
      ).blurCover,
      isFalse,
    );
    expect(
      const AdaptiveNavPeekEntry.noCover(title: 'x', onOpen: _noop).blurCover,
      isFalse,
    );
  });

  group('守卫：漏判写不出来', () {
    test('带封面的速览条目必须当场给 blurCover（没有默认值）', () {
      final String part = _code(
        'lib/src/utils/adaptive/nav_rail/nav_rail_peek.part.dart',
      );
      final String ctor = _section(part, 'const AdaptiveNavPeekEntry({');
      expect(ctor, contains('required this.cover,'));
      expect(ctor, contains('required this.blurCover,'));
      expect(part, isNot(contains('this.blurCover = false')));
    });

    test('音乐速览的两类条目都按 NavPeekNsfwJudge 判', () {
      final String peek = _code(
        'lib/src/pages/implementations/home_nav_peek.dart',
      );
      final String music = _section(
        peek,
        'Future<AdaptiveNavPeekData> _loadMusic({',
      );
      expect(music, contains('NavPeekNsfwJudge.load(appModel)'));
      expect(music, contains('blurCover: cover.blur'));
      expect(music, contains('blurCover: blurCover'));
      expect(peek, contains('blur: nsfw.music('));
      // 各模块速览只有这一个判定入口，不再各写一份闭包。
      expect(peek, isNot(contains('_loadNsfwJudge')));
      expect(RegExp(r'MediaNsfwSnapshot\.load\(').allMatches(peek).length, 1);
    });
  });
}

void _noop() {}
