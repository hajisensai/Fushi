// BUG-2691 取证：杜比视界 Profile 5（IPTPQc2）片源在 SDR 屏 + HDR 输出「自动」下
// 必须切进 gpu-next 宿主窗——纹理路径（vo=libmpv）不做 RPU 重整，画面紫绿反色。
// 对真服务器跑，直接把 DV P5 条目推成播放页（不走库浏览），断言起播后宿主窗激活；
// 再把 HDR 输出设成「关闭」重进，断言不进宿主窗、改为弹出「颜色会偏」提示 OSD。
//
// 需要真实凭据 + 条目 id，经 --dart-define 注入（runner 用 -DartDefine 转发）：
//   FUSHI_EMBY_URL / FUSHI_EMBY_ITEM + FUSHI_EMBY_TOKEN / FUSHI_EMBY_USERID
// 缺凭据直接失败（不是 skip：本文件只在人工点名时跑，跑了就要给出结论）。
// 仅 Windows 有宿主窗；其它平台跑它没有意义。

import 'dart:async';

import 'package:flutter/material.dart';
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

  testWidgets('真 Emby：DV Profile 5 片源起播后进 gpu-next 宿主窗',
      (WidgetTester tester) async {
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
          ) as VideoFushiTestHooks;
        }

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);

        // 提示 OSD 只停 3.6 s，起播过程中每帧都采一次，别等起播完再看。
        bool warnedSeen = false;
        Future<void> pumpAndSample() async {
          await tester.pump(const Duration(milliseconds: 250));
          if (find
              .textContaining(t.video_dolby_vision_colors_enable_hdr_output)
              .evaluate()
              .isNotEmpty) {
            warnedSeen = true;
          }
        }

        Future<VideoFushiTestHooks> openAndPlay(String tag) async {
          warnedSeen = false;
          unawaited(navigator.push<void>(MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage.neutralizedRemote(
              info: info,
              repo: repo,
              client: client,
            ),
          )));
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

        await appModel.setVideoHdrOutputMode(VideoHdrOutputMode.auto);
        final VideoFushiTestHooks hooks = await openAndPlay('auto');

        // video-params 到位后重判是异步的（先问 runner 显示器状态再切 VO）。
        for (int i = 0; i < 80 && !hooks.debugHdrHostActive; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        debugPrint('[dv-itest] "${info.title}" hdrHostActive='
            '${hooks.debugHdrHostActive} position=${hooks.debugPositionMs}');
        expect(hooks.debugHdrHostActive, isTrue,
            reason: 'DV P5 应进 gpu-next 宿主窗，纹理路径会紫绿反色');

        // 宿主窗里 gpu-next 继续出帧：位置还在走。
        final int before = hooks.debugPositionMs ?? 0;
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        expect(hooks.debugPositionMs ?? 0, greaterThan(before),
            reason: '切 VO 后播放应继续');
        expect(warnedSeen, isFalse, reason: 'auto 下能正确显色，不该提示');

        // ── HDR 输出「关闭」：尊重用户、不进宿主窗，但要提示颜色会偏 ──
        navigator.pop();
        for (int i = 0; i < 80; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
        }
        await appModel.setVideoHdrOutputMode(VideoHdrOutputMode.off);
        try {
          final VideoFushiTestHooks offHooks = await openAndPlay('off');
          for (int i = 0; i < 12 && !warnedSeen; i++) {
            await pumpAndSample();
          }
          final bool warned = warnedSeen;
          debugPrint('[dv-itest] off: hdrHostActive='
              '${offHooks.debugHdrHostActive} warned=$warned');
          expect(offHooks.debugHdrHostActive, isFalse,
              reason: '用户关了 HDR 输出就不进宿主窗');
          expect(warned, isTrue, reason: '关闭时 DV P5 应弹出颜色提示 OSD');
        } finally {
          await appModel.setVideoHdrOutputMode(VideoHdrOutputMode.auto);
        }
      },
    );
  });
}
