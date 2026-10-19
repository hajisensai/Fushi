// BUG-2691 取证：杜比视界 Profile 5（IPTPQc2）片源在 Windows 上直接在视频纹理里出
// 正确颜色——随包 libmpv 的 gl_video 打了 `mpv-gl-dovi-p5.patch`（像素级对照见
// `tool/bluray/verify_dovi_p5.py`），不再切到 gpu-next 宿主窗（已删除）。
// 对真服务器跑，直接把 DV P5 条目推成播放页（不走库浏览），在 HDR 输出「自动」与
// 「关闭」下各开一次：都必须正常起播、位置前进；「关闭」不开合成器 HDR。
// 「不弹提示」与 debugDolbyVisionColorsUnsupported 在 Windows 上由纯函数决定
// （dolbyVisionColorsUnsupported 恒 false），这里只是端到端复核接线，不是颜色证据；
// 颜色证据是 verify_dovi_p5.py 的像素对照。
//
// 需要真实凭据 + 条目 id，经 --dart-define 注入（runner 用 -DartDefine 转发）：
//   FUSHI_EMBY_URL / FUSHI_EMBY_ITEM + FUSHI_EMBY_TOKEN / FUSHI_EMBY_USERID
// 缺凭据直接失败（不是 skip：本文件只在人工点名时跑，跑了就要给出结论）。

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart' show t;
import 'package:fushi/models.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi/src/sync/jellyfin_video_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;
import 'package:integration_test/integration_test.dart';

import 'helpers/focus_driver.dart';
import 'support/itest_startup_guard.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _serverUrl = String.fromEnvironment('FUSHI_EMBY_URL');
const String _token = String.fromEnvironment('FUSHI_EMBY_TOKEN');
const String _userId = String.fromEnvironment('FUSHI_EMBY_USERID');
const String _itemId = String.fromEnvironment('FUSHI_EMBY_ITEM');

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('真 Emby：DV Profile 5 片源在纹理路径直接起播、不提示偏色', (
    WidgetTester tester,
  ) async {
    expect(
      _serverUrl.isNotEmpty &&
          _itemId.isNotEmpty &&
          _token.isNotEmpty &&
          _userId.isNotEmpty,
      isTrue,
      reason: '需要 --dart-define FUSHI_EMBY_URL / ITEM / TOKEN / USERID',
    );
    await runFushiItest(
      label: 'media-server-dolby-vision-p5',
      body: () async {
        await launchFushiTestApp();
        expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
        final AppModel appModel = await enableFocusNavigation(tester);

        final JellyfinServerConfig config = JellyfinServerConfig(
          serverUrl: JellyfinApi.normalizeServerUrl(_serverUrl),
          username: '',
          userId: _userId,
          accessToken: _token,
        );
        await SyncRepository(appModel.database).upsertJellyfinServer(config);
        final JellyfinVideoClient client = config.buildClient();
        final RemoteVideoInfo info = await client.remoteVideoDetail(
          RemoteVideoInfo(id: _itemId, title: _itemId),
        );
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        VideoFushiTestHooks? readHooks() {
          if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
          return tester.state<State<VideoFushiPage>>(
                find.byType(VideoFushiPage),
              )
              as VideoFushiTestHooks;
        }

        final NavigatorState navigator = tester.state<NavigatorState>(
          find.byType(Navigator).first,
        );

        // 提示 OSD 只停 3.6 s，起播过程中每帧都采一次，别等起播完再看。
        bool warnedSeen = false;
        Future<void> pumpAndSample() async {
          await tester.pump(const Duration(milliseconds: 250));
          if (find
              .textContaining(t.video_dolby_vision_colors_unsupported)
              .evaluate()
              .isNotEmpty) {
            warnedSeen = true;
          }
        }

        Future<VideoFushiTestHooks> openAndPlay(String tag) async {
          warnedSeen = false;
          unawaited(
            navigator.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => VideoFushiPage.neutralizedRemote(
                  info: info,
                  repo: repo,
                  client: client,
                ),
              ),
            ),
          );
          bool ready = false;
          for (int i = 0; i < 360; i++) {
            await pumpAndSample();
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
            await pumpAndSample();
            played = hooks.debugPositionMs ?? 0;
          }
          expect(played, greaterThan(1500), reason: '[$tag] 真流应自然前进');
          return hooks;
        }

        Future<void> closePage() async {
          navigator.pop();
          for (int i = 0; i < 80; i++) {
            await tester.pump(const Duration(milliseconds: 250));
            if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
          }
        }

        try {
          for (final VideoHdrOutputMode mode in <VideoHdrOutputMode>[
            VideoHdrOutputMode.auto,
            VideoHdrOutputMode.off,
          ]) {
            await appModel.setVideoHdrOutputMode(mode);
            final VideoFushiTestHooks hooks = await openAndPlay(mode.name);
            final int before = hooks.debugPositionMs ?? 0;
            for (int i = 0; i < 20; i++) {
              await pumpAndSample();
            }
            debugPrint(
              '[dv-itest] ${mode.name} "${info.title}" '
              'compositor=${hooks.debugHdrCompositorActive} '
              'unsupported=${hooks.debugDolbyVisionColorsUnsupported} '
              'warned=$warnedSeen position=${hooks.debugPositionMs}',
            );
            expect(
              hooks.debugPositionMs ?? 0,
              greaterThan(before),
              reason: '[${mode.name}] 播放应继续',
            );
            expect(
              hooks.debugDolbyVisionColorsUnsupported,
              isFalse,
              reason: '[${mode.name}] Windows 纹理路径自带 DV 重整',
            );
            expect(warnedSeen, isFalse, reason: '[${mode.name}] 能正确显色，不该提示');
            if (mode == VideoHdrOutputMode.off) {
              expect(
                hooks.debugHdrCompositorActive,
                isFalse,
                reason: '关闭 = 永远 SDR 输出',
              );
            }
            await closePage();
          }
        } finally {
          await appModel.setVideoHdrOutputMode(VideoHdrOutputMode.auto);
        }
      },
    );
  });
}
