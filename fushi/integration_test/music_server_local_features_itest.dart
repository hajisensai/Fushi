// 服务器曲目（Jellyfin）的本机功能对真服务器的端到端取证（feat/server-music-local-features）：
//
//   1. 响度：服务器开了 LUFS 扫描后，专辑曲目列表带 `NormalizationGain`；把一首加入音乐库
//      （v149 行，不存响度）再从音乐库还原成播放项起播，后端起播期向服务器补查，mpv 的
//      `volume-gain` 落到服务器给的增益上（信号路径面板读的就是它）；
//   2. 生成日语字幕：服务器专辑页出现「为本专辑生成字幕」、曲目菜单出现「生成日语字幕」；
//      取音频一步从服务器原样直出的流解码出 16 kHz WAV，目标没有 `remote` 拒绝，管线
//      对这一首跑起来（开发服务器的曲目是正弦波，成功 = 管线端到端跑完、不被拒，不看文字）。
//
// 凭据经 --dart-define 注入（runner 用 -DartDefine 转发）：
//   FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER / FUSHI_JELLYFIN_PASS
// 可选 FUSHI_JELLYFIN_ALBUM（专辑名，缺省第一张）。缺凭据直接失败（只在人工点名时跑）。
// 证据是 observe-*.png 与 [srv-local] 日志行。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/media/music/asr/music_plugin_asr_audio.dart';
import 'package:fushi/src/media/music/asr/music_server_asr_audio.dart';
import 'package:fushi/src/media/music/asr/music_subtitle_target.dart';
import 'package:fushi/src/media/music/music_output_backend.dart';
import 'package:fushi/src/media/music/music_remote_tracks.dart';
import 'package:fushi/src/media/music/music_signal_path.dart';
import 'package:fushi/src/media/music/server/jellyfin_music_client.dart';
import 'package:fushi/src/media/music/server/music_server_play_item.dart';
import 'package:fushi/src/media/video/subtitle/app_video_subtitle_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/home_page.dart';
import 'package:fushi/src/pages/implementations/music/music_server_pages.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/music/server/music_server.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_JELLYFIN_URL');
const String _username = String.fromEnvironment('FUSHI_JELLYFIN_USER');
const String _password = String.fromEnvironment('FUSHI_JELLYFIN_PASS');
const String _albumQuery = String.fromEnvironment('FUSHI_JELLYFIN_ALBUM');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Jellyfin 曲目：起播期补查服务器响度、生成日语字幕入口与取音频管线', (
    WidgetTester tester,
  ) async {
    expect(
      _serverUrl.isNotEmpty && _username.isNotEmpty,
      isTrue,
      reason: '需要 --dart-define FUSHI_JELLYFIN_URL / FUSHI_JELLYFIN_USER',
    );
    await runFushiItest(
      label: 'music-server-local-features',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel appModel = await enableFocusNavigation(tester);
        final FushiDatabase db = appModel.database;

        // ── 登录并落配置（产品同一条 authenticateByName + upsert 路径）──
        final String url = JellyfinApi.normalizeServerUrl(_serverUrl);
        final JellyfinAuthResult auth = await JellyfinApi(
          serverUrl: url,
        ).authenticateByName(_username, _password);
        await SyncRepository(db).upsertJellyfinServer(
          JellyfinServerConfig(
            serverUrl: url,
            username: _username,
            userId: auth.userId,
            accessToken: auth.accessToken,
            serverName: auth.serverName,
          ),
        );
        final Map<String, MusicServerBinding> bindings =
            await musicServerBindingLoader!();
        final JellyfinMusicClient browser = bindings.values
            .map((MusicServerBinding b) => b.browser)
            .whereType<JellyfinMusicClient>()
            .single;

        final List<MusicServerAlbum> albums =
            (await browser.listAlbums()).items;
        final MusicServerAlbum album = _albumQuery.isEmpty
            ? albums.first
            : albums.firstWhere((MusicServerAlbum a) => a.title == _albumQuery);
        final List<MusicServerTrack> tracks = await browser.albumTracks(
          album.id,
        );
        final MusicServerTrack track = tracks.first;
        debugPrint(
          '[srv-local] album="${album.title}" track="${track.title}" '
          'listLoudness=${track.loudness}',
        );
        expect(
          track.loudness?.trackGainDb,
          isNotNull,
          reason: '服务器开了 LUFS 扫描：列表应带 NormalizationGain',
        );

        // ── 1. 响度：音乐库里的服务器曲目（行里没有响度）起播期补查 ──
        final MusicRemoteTracksCompanion row = musicServerRemoteTrackCompanion(
          browser,
          track,
          albumTitle: album.title,
        )!;
        await db.addMusicRemoteTrackToLibrary(
          row,
          at: DateTime.now().millisecondsSinceEpoch,
        );
        final MusicRemoteTrackRow stored = (await db.getMusicRemoteTrack(
          row.trackUid.value,
        ))!;
        final MusicPlayItem libraryItem = musicPlayItemOfRemote(
          stored,
          server: bindings[browser.serverId],
        )!;
        expect(libraryItem.rgTrackGain, isNull, reason: 'v149 行里不存响度');
        await appModel.prefsRepo.setMusicReplayGain(true);
        await appModel.musicSession.engine.playQueue(<MusicPlayItem>[
          libraryItem,
        ]);
        MusicSignalPathSnapshot? snap;
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          snap = await appModel.musicSession.engine.readSignalPath();
          if (snap != null && snap.volumeGainDb.abs() > 1e-6) break;
        }
        debugPrint(
          '[srv-local] library-row play: volume-gain=${snap?.volumeGainDb} dB '
          '(server track gain ${track.loudness?.trackGainDb})',
        );
        expect(
          snap?.volumeGainDb,
          closeTo(track.loudness!.trackGainDb!, 0.01),
          reason: '后端补查到服务器响度后按曲目增益施加',
        );
        await appModel.musicSession.engine.stop();

        // ── 2. 生成字幕入口（服务器专辑页按钮 + 曲目菜单项）──
        final NavigatorState rootNav = Navigator.of(
          tester.element(find.byType(HomePage)),
          rootNavigator: true,
        );
        unawaited(
          rootNav.push(
            MaterialPageRoute<void>(
              builder: (BuildContext _) =>
                  MusicServerAlbumPage(browser: browser, album: album),
            ),
          ),
        );
        final Finder albumButton = find.byKey(
          const ValueKey<String>('music_server_album_generate_subtitles'),
        );
        for (int i = 0; i < 40 && albumButton.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(albumButton, findsOneWidget, reason: '服务器专辑页应有「为本专辑生成字幕」');
        await captureFlutterFrame(tester, 'server-album-generate-subtitles');
        final BuildContext pageContext = tester.element(
          find.byType(MusicServerAlbumPage),
        );
        musicServerTrackMenu(
          pageContext,
          browser,
          track,
          albumTitle: album.title,
        )!.open(null);
        final Finder menuItem = find.text(t.music_subtitle_generate);
        for (int i = 0; i < 40 && menuItem.evaluate().isEmpty; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(menuItem, findsWidgets, reason: '曲目菜单应有「生成日语字幕」');
        await captureFlutterFrame(
          tester,
          'server-track-menu-generate-subtitles',
        );
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.pump(const Duration(milliseconds: 500));

        // ── 3. 取音频 + 管线（与入口同一条：musicServerAsrAudioInput → stager → target）──
        final MusicPlayItem item = musicServerPlayItem(
          browser,
          track,
          albumTitle: album.title,
        );
        final MusicPluginAsrAudioStager stager = MusicPluginAsrAudioStager(
          root: musicPluginAsrAudioRootUnder(
            await AppPaths.supportRootDirectory(),
          ),
        );
        final ({File audio, bool staged}) got = await musicAsrAudioFileOf(
          await musicServerAsrAudioInput(
            item.serverTrack!,
            servers: musicServerBindingLoader!,
          ),
          item: item,
          stager: stager,
          onProgress: (_) {},
          cancel: Completer<void>().future,
        );
        final int wavBytes = await got.audio.length();
        debugPrint(
          '[srv-local] staged ${got.audio.path} ($wavBytes bytes, '
          '~${(wavBytes - 44) / 32000} s of 16 kHz mono)',
        );
        expect(wavBytes, greaterThan(32000), reason: '至少一秒 16 kHz 单声道');

        final AppVideoSubtitleTarget target =
            await MusicSubtitleTargets(
              database: db,
              lyrics: appModel.musicLyrics,
            ).forRemoteTracks(
              tracks: <MusicRemoteAsrTrack>[
                (item: item, audio: got.audio, staged: got.staged),
              ],
              title: item.title,
              key: 'music:track:${item.trackUid}',
            );
        expect(target.unavailable, isEmpty, reason: '不再有 remote 拒绝');
        expect(target.episodes, hasLength(1));
        final AppVideoSubtitleJob job = appVideoSubtitleService(
          appModel,
        ).start(target, const AppVideoSubtitleOptions());
        bool finished = false;
        unawaited(job.done.then((_) => finished = true));
        final DateTime deadline = DateTime.now().add(
          const Duration(minutes: 10),
        );
        while (!finished && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(seconds: 1));
        }
        debugPrint(
          '[srv-local] asr job: status=${job.status} '
          'registered=${job.registeredBookUids} error=${job.errorMessage}',
        );
        await captureFlutterFrame(tester, 'server-asr-job-done', settle: false);
        expect(finished, isTrue, reason: '管线应在 10 分钟内跑完');
      },
    );
  });
}
