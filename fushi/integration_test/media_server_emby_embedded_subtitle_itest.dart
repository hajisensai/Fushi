// BUG-2590 取证：媒体服务器兼容层（「UHD Media Server」等）没有字幕抽取端点时，
// 内嵌文本轨要能 ① 立即交给 libmpv 解码、文本回流成可点 cue（BUG-2648，此前是
// 自绘、不可查词）、② 重进影片恢复到同一轨。对真服务器跑，
// 直接把该条目推成播放页（不走库浏览）。
//
// 需要真实凭据 + 条目 id，经 --dart-define 注入（runner 用 -DartDefine 转发）：
//   FUSHI_EMBY_URL / FUSHI_EMBY_USER / FUSHI_EMBY_PASS / FUSHI_EMBY_ITEM
//   （或用已签发的令牌代替密码：FUSHI_EMBY_TOKEN + FUSHI_EMBY_USERID）
//   FUSHI_EMBY_TRACK（服务器流号，默认 2）
//   FUSHI_EMBY_SHOT_SEEK_MS（① 截图前 seek 到的位置，真片首句常在台标之后）
//   FUSHI_EMBY_EXPECT_FALLBACK（默认 true = 服务器抽不出、走回落；false = 原版
//   Emby / Jellyfin，服务器抽取成功，直接 cue overlay、libmpv 不选轨——回归口径）
// 缺凭据直接失败（不是 skip：本文件只在人工点名时跑，跑了就要给出结论）。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'helpers/observe_capture.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_EMBY_URL');
const String _username = String.fromEnvironment('FUSHI_EMBY_USER');
const String _password = String.fromEnvironment('FUSHI_EMBY_PASS');
const String _token = String.fromEnvironment('FUSHI_EMBY_TOKEN');
const String _userId = String.fromEnvironment('FUSHI_EMBY_USERID');
const String _itemId = String.fromEnvironment('FUSHI_EMBY_ITEM');
const int _trackIndex =
    int.fromEnvironment('FUSHI_EMBY_TRACK', defaultValue: 2);

/// 截图前 seek 到这里（毫秒；0 = 不 seek）：真片首条 cue 可能在片头台标之后。
const int _shotSeekMs = int.fromEnvironment('FUSHI_EMBY_SHOT_SEEK_MS');
const bool _expectFallback =
    bool.fromEnvironment('FUSHI_EMBY_EXPECT_FALLBACK', defaultValue: true);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真 Emby 兼容层：内嵌轨 libmpv 解码回流成 cue → 重进恢复',
      (WidgetTester tester) async {
    final bool hasToken = _token.isNotEmpty && _userId.isNotEmpty;
    expect(
      _serverUrl.isNotEmpty &&
          _itemId.isNotEmpty &&
          (hasToken || (_username.isNotEmpty && _password.isNotEmpty)),
      isTrue,
      reason:
          '需要 --dart-define FUSHI_EMBY_URL / ITEM + (USER/PASS 或 TOKEN/USERID)',
    );
    await runFushiItest(
      label: 'media-server-emby-embedded-subtitle',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel appModel = await enableFocusNavigation(tester);

        // ── 登录并落配置（产品同一条 authenticateByName + upsert 路径）──
        final String url = JellyfinApi.normalizeServerUrl(_serverUrl);
        final JellyfinServerConfig config;
        if (hasToken) {
          config = JellyfinServerConfig(
            serverUrl: url,
            username: _username,
            userId: _userId,
            accessToken: _token,
          );
        } else {
          final JellyfinAuthResult auth =
              await JellyfinApi(serverUrl: url).authenticateByName(
            _username,
            _password,
          );
          config = JellyfinServerConfig(
            serverUrl: url,
            username: _username,
            userId: auth.userId,
            accessToken: auth.accessToken,
            serverName: auth.serverName,
          );
        }
        await SyncRepository(appModel.database).upsertJellyfinServer(config);
        final JellyfinVideoClient client = config.buildClient();
        final RemoteVideoInfo info = await client.remoteVideoDetail(
          RemoteVideoInfo(id: _itemId, title: _itemId),
        );
        debugPrint(
          '[emb-itest] item "${info.title}" size=${info.sizeBytes} '
          'tracks=${info.embeddedSubtitleTracks.map((t) => '${t.streamIndex}/${t.codec}/${t.language}').toList()}',
        );
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        VideoFushiTestHooks? readHooks() {
          if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
          return tester.state<State<VideoFushiPage>>(
            find.byType(VideoFushiPage),
          ) as VideoFushiTestHooks;
        }

        Future<VideoFushiTestHooks> openAndPlay(String tag) async {
          final NavigatorState navigator =
              tester.state<NavigatorState>(find.byType(Navigator).first);
          unawaited(navigator.push<void>(MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage.neutralizedRemote(
              info: info,
              repo: repo,
              client: client,
            ),
          )));
          bool ready = false;
          for (int i = 0; i < 360; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            if (readHooks()?.debugPositionMs != null) {
              ready = true;
              break;
            }
          }
          expect(ready, isTrue, reason: '[$tag] 流控制器应在 90s 内就绪');
          final VideoFushiTestHooks hooks = readHooks()!;
          await hooks.debugPlay();
          int played = 0;
          for (int i = 0; i < 240 && played < 1500; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            played = hooks.debugPositionMs ?? 0;
          }
          expect(played, greaterThan(1500), reason: '[$tag] 真流应自然前进');
          return hooks;
        }

        // ── ① 选内嵌轨：服务器 404 → libmpv 解码回流 ──
        final VideoFushiTestHooks hooks = await openAndPlay('first');
        expect(hooks.debugRemoteEmbeddedStreamIndices, contains(_trackIndex),
            reason: '字幕轨列表应含目标内嵌轨');
        await hooks.debugSelectRemoteEmbeddedSubtitle(_trackIndex);
        final String? sourceAfterSelect = hooks.debugCurrentSubtitleSource;
        final String? mpvTrackAfterSelect = hooks.debugActiveSubtitleTrackId;
        final bool graphicAfterSelect = hooks.debugGraphicSubtitleActive;
        final int cuesAfterSelect = hooks.debugCueCount;
        debugPrint(
          '[emb-itest] after select: source=$sourceAfterSelect '
          'mpvTrack=$mpvTrackAfterSelect graphic=$graphicAfterSelect '
          'cues=$cuesAfterSelect',
        );
        expect(sourceAfterSelect, 'embedded:$_trackIndex',
            reason: '选中后字幕源应记为该轨');
        if (!_expectFallback) {
          // 原版服务器：抽取端点正常 → 直接 cue overlay，libmpv 不选轨（回归口径）。
          expect(cuesAfterSelect, greaterThan(0), reason: '服务器抽取成功应直接得到 cue');
          expect(mpvTrackAfterSelect, 'no');
          expect(graphicAfterSelect, isFalse);
          await tester.pump(const Duration(seconds: 4));
          final ObserveShot shotStock = await captureFlutterFrame(
            tester,
            'emb-01-server-extracted',
          );
          expect(shotStock.saved, isTrue);
        } else {
          expect(
            mpvTrackAfterSelect,
            isNot(anyOf(isNull, 'no', 'auto')),
            reason: 'libmpv 应选中容器内真实字幕轨',
          );
          expect(graphicAfterSelect, isFalse,
              reason: '文本轨不再走自绘（BUG-2648）');
          expect(hooks.debugPlayerDecodedSubtitleActive, isTrue,
              reason: '进入 libmpv 解码 → sub-text 回流模式');
          if (_shotSeekMs > 0) await hooks.debugSeekMs(_shotSeekMs);
          for (int i = 0; i < 80 && hooks.debugCueCount == 0; i++) {
            await tester.pump(const Duration(milliseconds: 250));
          }
          debugPrint('[emb-itest] decoded cues=${hooks.debugCueCount}');
          expect(hooks.debugCueCount, greaterThan(0),
              reason: '播到有字幕处应有 libmpv 回流的可点 cue');
          final ObserveShot shot1 = await captureFlutterFrame(
            tester,
            'emb-01-player-rendered',
          );
          expect(shot1.saved, isTrue);
        }

        // ── ② 重进：按持久化的 embedded:<n> 恢复（原版 → cue；兼容层 → 解码回流）──
        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        navigator.pop();
        for (int i = 0; i < 80; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
        }
        expect(find.byType(VideoFushiPage), findsNothing);
        final VideoFushiTestHooks hooks2 = await openAndPlay('reopen');
        // 回落是 load 之后异步选轨，多给几秒。
        for (int i = 0; i < 40; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (hooks2.debugCurrentSubtitleSource == 'embedded:$_trackIndex' &&
              (hooks2.debugCueCount > 0 ||
                  hooks2.debugPlayerDecodedSubtitleActive)) {
            break;
          }
        }
        debugPrint(
          '[emb-itest] reopen: source=${hooks2.debugCurrentSubtitleSource} '
          'cues=${hooks2.debugCueCount} mpvTrack=${hooks2.debugActiveSubtitleTrackId} '
          'graphic=${hooks2.debugGraphicSubtitleActive} '
          'decoded=${hooks2.debugPlayerDecodedSubtitleActive}',
        );
        expect(hooks2.debugCurrentSubtitleSource, 'embedded:$_trackIndex',
            reason: '重进应恢复上次选的内嵌轨');
        if (!_expectFallback) {
          expect(hooks2.debugCueCount, greaterThan(0),
              reason: '服务器可抽 → 重进直接得到 cue');
        } else {
          expect(hooks2.debugPlayerDecodedSubtitleActive, isTrue,
              reason: '兼容层 → 重进后仍由 libmpv 解码回流');
          expect(hooks2.debugGraphicSubtitleActive, isFalse);
        }
        final ObserveShot shot3 = await captureFlutterFrame(
          tester,
          'emb-02-reopen',
        );
        expect(shot3.saved, isTrue);
      },
    );
  });
}
