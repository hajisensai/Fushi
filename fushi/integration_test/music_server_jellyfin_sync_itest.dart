// 服务器曲库与 Jellyfin 的双向同步（feat/jellyfin-music-sync）对真 Jellyfin 服务器的
// 端到端取证：
//
//   1. 服务器页「主页」分区：最近添加 / 最常播放 / 最近播放；
//   2. 「流派」分区列出服务器的流派 → 点进一个流派（专辑 + 曲目）；
//   3. 专辑页收藏按钮 → 服务器 `UserData.IsFavorite` 翻转（直接问服务器核对），再翻回；
//      「收藏」分区列出收藏的专辑；
//   4. 播放服务器曲目 → 服务器 `PlayCount` +1、`LastPlayedDate` 更新（直接问服务器核对）；
//      停止后上报 Stopped；
//   5. 服务器歌词：带 .lrc 的曲目经歌词链取到 `server` 来源的同步歌词。
//
// 凭据经 --dart-define 注入（runner 用 -DartDefine 转发）：
//   FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER / FUSHI_JELLYFIN_PASS
// 可选 FUSHI_JELLYFIN_ALBUM（带 .lrc 的专辑名，缺省「初恋テスト」）。缺凭据直接失败（本文件
// 只在人工点名时跑）。会改服务器上的播放次数（收藏改完翻回）。证据是 observe-*.png。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi_engine/media/music/lyrics/music_lyrics_sources.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_favorites.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_JELLYFIN_URL');
const String _username = String.fromEnvironment('FUSHI_JELLYFIN_USER');
const String _password = String.fromEnvironment('FUSHI_JELLYFIN_PASS');
const String _albumName = String.fromEnvironment(
  'FUSHI_JELLYFIN_ALBUM',
  defaultValue: '初恋テスト',
);

Future<bool> _waitFor(
  WidgetTester tester,
  FutureOr<bool> Function() predicate, {
  int maxTicks = 80,
}) async {
  for (int i = 0; i < maxTicks; i++) {
    if (await predicate()) return true;
    await tester.pump(const Duration(milliseconds: 250));
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Jellyfin 音乐：主页 / 流派 / 收藏回写 / 播放次数回写 / 服务器歌词', (
    WidgetTester tester,
  ) async {
    expect(
      _serverUrl.isNotEmpty && _username.isNotEmpty,
      isTrue,
      reason: '需要 --dart-define FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER',
    );
    await runFushiItest(
      label: 'music-server-jellyfin-sync',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel app = await enableFocusNavigation(tester);
        final FocusDriver driver = FocusDriver(tester);

        // ── 登录并落配置（产品同一条 authenticateByName + upsert 路径）──
        final String url = JellyfinApi.normalizeServerUrl(_serverUrl);
        final JellyfinAuthResult auth = await JellyfinApi(
          serverUrl: url,
        ).authenticateByName(_username, _password);
        final JellyfinServerConfig config = JellyfinServerConfig(
          serverUrl: url,
          username: _username,
          userId: auth.userId,
          accessToken: auth.accessToken,
          serverName: auth.serverName,
        );
        await SyncRepository(app.database).upsertJellyfinServer(config);
        final JellyfinApi api = JellyfinApi(
          serverUrl: url,
          accessToken: auth.accessToken,
        );
        Future<Map<String, Object?>> userData(String itemId) async {
          final Object? j = await api.getDecodedJson(
            '/Users/${auth.userId}/Items/$itemId',
          );
          return ((j! as Map<String, Object?>)['UserData']!
                  as Map<String, Object?>)
              .cast<String, Object?>();
        }

        final JellyfinMusicClient browser = JellyfinMusicClient(config);
        final MusicServerAlbum album = (await browser.search(
          _albumName,
        )).albums.firstWhere((MusicServerAlbum a) => a.title == _albumName);
        final List<MusicServerTrack> tracks = await browser.albumTracks(
          album.id,
        );
        expect(tracks, isNotEmpty);
        debugPrint(
          '[jf-music] album="${album.title}" (${album.id}) '
          'tracks=${tracks.length}',
        );

        HomePage.debugSelectTab!(HomeTab.music);
        await tester.pump(const Duration(seconds: 2));
        final NavigatorState rootNav = Navigator.of(
          tester.element(find.byType(HomePage)),
          rootNavigator: true,
        );

        // ── 1. 服务器页：缺省落在「主页」分区 ──
        unawaited(
          rootNav.push(
            MaterialPageRoute<void>(
              builder: (_) => MusicServerBrowsePage(browser: browser),
            ),
          ),
        );
        expect(
          await _waitFor(
            tester,
            () =>
                find.text(t.music_server_recently_added).evaluate().isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '主页分区应出现「最近添加」',
        );
        await tester.pump(const Duration(seconds: 2));
        await captureFlutterFrame(tester, 'jfm-01-home', settle: false);

        // 分区页签（LibrarySectionTabs）是整排一个焦点停靠点：Enter 不切段，只认
        // 左右方向键（重设计外壳下画成连体按钮组，不是 TabBar）。分区顺序：
        // 主页 / 专辑 / 艺人 / 歌单 / 流派 / 收藏。
        final List<String> sectionLabels = <String>[
          t.music_apple_music_section_home,
          t.music_section_albums,
          t.music_section_artists,
          t.music_section_playlists,
          t.music_server_section_genres,
          t.music_server_section_favorites,
        ];
        int currentSection = 0;
        Future<void> selectSection(String label) async {
          final int target = sectionLabels.indexOf(label);
          expect(target, greaterThanOrEqualTo(0));
          expect(
            await driver.focusWidget(
              find.text(sectionLabels[currentSection]).first,
            ),
            isTrue,
            reason: '分区页签应可聚焦',
          );
          await driver.adjust(steps: target - currentSection);
          currentSection = target;
          await tester.pump(const Duration(seconds: 2));
        }

        // ── 2. 流派 ──
        await selectSection(t.music_server_section_genres);
        expect(
          await _waitFor(
            tester,
            () => find.text('J-Pop').evaluate().isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '流派分区应列出 J-Pop',
        );
        for (final String g in <String>['J-Pop', 'Rock', 'Ambient']) {
          expect(find.text(g), findsWidgets, reason: '流派分区应列出 $g');
        }
        await tester.pump(const Duration(seconds: 2));
        await captureFlutterFrame(tester, 'jfm-02-genres', settle: false);
        expect(await driver.focusWidget(find.text('J-Pop').first), isTrue);
        await driver.activate();
        expect(
          await _waitFor(
            tester,
            () => find
                .byKey(const ValueKey<String>('music-server-genre-play'))
                .evaluate()
                .isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '流派页应出现「全部播放」',
        );
        await tester.pump(const Duration(seconds: 2));
        await captureFlutterFrame(tester, 'jfm-03-genre-jpop', settle: false);
        rootNav.pop();
        await tester.pump(const Duration(seconds: 2));

        // ── 3. 收藏：专辑页按钮 → 服务器 IsFavorite 翻转 ──
        final bool favBefore = (await userData(album.id))['IsFavorite'] == true;
        unawaited(
          rootNav.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  MusicServerAlbumPage(browser: browser, album: album),
            ),
          ),
        );
        final Finder favButton = find.byWidgetPredicate(
          (Widget w) =>
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith(
                'music-server-favorite-album-${album.id}-',
              ),
        );
        expect(
          await _waitFor(
            tester,
            () => favButton.evaluate().isNotEmpty,
            maxTicks: 120,
          ),
          isTrue,
          reason: '专辑页应有收藏按钮',
        );
        await tester.pump(const Duration(seconds: 2));
        expect(await driver.focusWidget(favButton.first), isTrue);
        await driver.activate();
        expect(
          await _waitFor(
            tester,
            () async => (await userData(album.id))['IsFavorite'] == !favBefore,
            maxTicks: 60,
          ),
          isTrue,
          reason: '服务器上的 IsFavorite 应翻转',
        );
        await tester.pump(const Duration(seconds: 1));
        await captureFlutterFrame(
          tester,
          'jfm-04-album-favorited',
          settle: false,
        );
        rootNav.pop();
        await tester.pump(const Duration(seconds: 1));

        // 「收藏」分区列出它。
        if (!favBefore) {
          await selectSection(t.music_server_section_favorites);
          expect(
            await _waitFor(
              tester,
              () => find
                  .byKey(
                    ValueKey<String>(
                      'music-server-favorites-album-${album.id}',
                    ),
                  )
                  .evaluate()
                  .isNotEmpty,
              maxTicks: 120,
            ),
            isTrue,
            reason: '收藏分区应列出刚收藏的专辑',
          );
          // 收藏里只有专辑时那一段标题是「专辑」（不是「歌曲」）。
          expect(find.text(t.music_section_albums), findsWidgets);
          expect(find.text(t.music_section_songs), findsNothing);
          await tester.pump(const Duration(seconds: 1));
          await captureFlutterFrame(tester, 'jfm-05-favorites', settle: false);
        }
        // 翻回原状态（同一条产品路径）。
        await MusicServerFavoriteStore.instance.setFavorite(
          browser,
          MusicServerItemKind.album,
          album.id,
          favorite: favBefore,
        );
        expect((await userData(album.id))['IsFavorite'] == true, favBefore);

        // ── 4. 播放 → 服务器 PlayCount +1 ──
        final MusicServerTrack first = tracks.first;
        final Map<String, Object?> before = await userData(first.id);
        final int countBefore = (before['PlayCount'] as num?)?.toInt() ?? 0;
        debugPrint('[jf-music] before play: $before');
        await app.musicSession.engine.playQueue(<MusicPlayItem>[
          musicServerPlayItem(browser, first, albumTitle: album.title),
        ]);
        expect(
          await _waitFor(
            tester,
            () async =>
                ((await userData(first.id))['PlayCount'] as num? ?? 0) >
                countBefore,
            maxTicks: 120,
          ),
          isTrue,
          reason: '开播后服务器 PlayCount 应 +1',
        );
        final Map<String, Object?> after = await userData(first.id);
        debugPrint('[jf-music] after play: $after');
        expect(after['LastPlayedDate'], isNotNull);

        // ── 5. 服务器歌词 ──
        final MusicPlayItem playing = app.musicSession.engine.current!;
        final MusicLyricsResolution? lyrics = await app.musicLyrics.resolve(
          MusicLyricsTrackRef(
            trackUid: playing.trackUid,
            path: playing.path,
            title: playing.title,
            artist: playing.artist,
            album: playing.album,
            durationMs: playing.durationMs,
          ),
        );
        expect(lyrics, isNotNull, reason: '带 .lrc 的曲目应取到歌词');
        expect(lyrics!.source, MusicLyricsSource.server);
        expect(lyrics.timeline.lines, isNotEmpty);
        debugPrint(
          '[jf-music] lyrics source=${lyrics.source} '
          'first="${lyrics.timeline.lines.first.text}"',
        );
        await tester.pump(const Duration(seconds: 3));
        await captureFlutterFrame(tester, 'jfm-06-playing', settle: false);

        await app.musicSession.engine.stop();
        await app.musicSession.serverReporting!.idle;
        debugPrint('[jf-music] stopped; final ${await userData(first.id)}');
      },
    );
  });
}
