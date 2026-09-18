// https 直连流在**宿主平台真实 libmpv** 上真播放的集成测试（Apple TLS 崩溃复现 + 回归门）。
//
// 背景：macOS / iOS 随包的 libmpv（FFmpeg 6.1.6 + Mbed TLS）打开 https 流时，在 mpv
// 的 `*/opener` 线程 `demux_open_url → stream_create → Avformat → mbedtls_ssl_handshake
// → ssl_parse_server_hello → ssl_get_next_record` 段错误（Mac 上的崩溃报告
// fushi-2026-09-18-210129.ips），进程直接消失——用户侧就是「播 Emby 闪退」。Windows 的
// libmpv 走 libcurl，无此路径。
//
// 本测试不经 YouTube 解析：直接用一条公网 https mp4 直链构造 UrlStreamVideoClient →
// 打开 VideoFushiPage.neutralizedRemote → 真实播放 → 断言 position 自然前进。基线
// （native 自己做 TLS）在 Apple 上应当以进程崩溃收场（runner 报 lost connection）；
// 修复后（TLS 由 Dart 中继终结）应当稳定播放。
//
// 依赖真实网络，Windows 离屏跑：
//   .\tool\run_windows_itest.ps1 -Visible integration_test\video_https_stream_native_tls_itest.dart
// Mac：.\tool\run_mac_itest.ps1 integration_test/video_https_stream_native_tls_itest.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_engine/sync/fushi_library_host_service.dart'
    show RemoteVideoInfo;

import 'test_helpers.dart';

/// 小体积公网 https mp4（约 1 MB；Google 示例桶在部分出口已回 403，不再用）。
const String _kUrl =
    'https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/360/Big_Buck_Bunny_360_10s_1MB.mp4';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'https direct stream plays on the real libmpv (native TLS path)',
    (WidgetTester tester) async {
      final List<String> caught = <String>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        caught.add(details.exceptionAsString());
        debugPrint('[https-itest] caught: ${details.exceptionAsString()}');
      };
      final Stopwatch guard = Stopwatch()..start();
      try {
        app.main(const <String>[]);
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));
        debugPrint('[https-itest] home ready at ${guard.elapsed}');

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        final UrlStreamVideoClient client = UrlStreamVideoClient(
          streamUrl: _kUrl,
        );
        const RemoteVideoInfo info = RemoteVideoInfo(
          id: 'video/stream/https-itest',
          title: 'https direct stream',
        );

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => VideoFushiPage.neutralizedRemote(
            info: info,
            repo: repo,
            client: client,
          ),
        )));
        debugPrint('[https-itest] pushed player page at ${guard.elapsed}');

        VideoFushiTestHooks? readHooks() {
          if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
          return tester.state<State<VideoFushiPage>>(
              find.byType(VideoFushiPage)) as VideoFushiTestHooks;
        }

        // 等控制器就绪（load 完成 → debugPositionMs 非 null）。
        bool ready = false;
        for (int i = 0; i < 240 && guard.elapsed.inSeconds < 90; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (readHooks()?.debugPositionMs != null) {
            ready = true;
            break;
          }
        }
        debugPrint('[https-itest] ready=$ready at ${guard.elapsed}');
        expect(ready, isTrue, reason: '流控制器应就绪（load 后 debugPositionMs 非 null）');

        final VideoFushiTestHooks hooks = readHooks()!;
        debugPrint('[https-itest] durationMs=${hooks.debugDurationMs}');

        await hooks.debugPlay();
        int played = 0;
        for (int i = 0; i < 240 && guard.elapsed.inSeconds < 90; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          played = hooks.debugPositionMs ?? 0;
          if (i % 8 == 0) {
            debugPrint('[https-itest] t=${i * 250}ms posMs=$played '
                'durMs=${hooks.debugDurationMs}');
          }
          if (played > 1500) break;
        }
        debugPrint('[https-itest] FINAL playedMs=$played '
            'durMs=${hooks.debugDurationMs} elapsed=${guard.elapsed}');
        expect(played, greaterThan(1500),
            reason: 'libmpv 应真实播放前进 >1.5s（实测=$played）——黑屏则永远 0');

        await navigator.maybePop();
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 100));
          if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
        }
      } finally {
        FlutterError.onError = oldHandler;
      }
    },
  );
}
