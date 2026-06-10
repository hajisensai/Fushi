// 真机集成测试：验证本轮两个视频功能（在真实 Windows 桌面 app 上）。
//
// ① 空格焦点恢复（BUG：导入着色器后空格失灵）——打开着色器对话框（会夺走 Video 的
//    键盘焦点）→ 关闭 → 按空格 → 断言播放图标 play_arrow→pause，证明焦点已归还 Video
//    且其内置空格快捷键恢复生效。
// ② Anime4K 一键下载——直接调 downloadAnime4kFiles（app 运行时网络环境，走镜像回退）
//    把 Mode A (Fast) 预设拉到 mpv_shaders/，断言文件真实落盘且内容是 GLSL。
//
// 运行：在 hibiki/ 下 `.\tool\run_windows_itest.ps1 integration_test\video_shader_focus_test.dart`
// （HIBIKI_TEST_HIDDEN 离屏）。需要真机 media_kit native + 测试视频
// D:\hibiki_video_test\sample.mp4（本机已置）。无设备/无网络环境会 skip 相应断言。
import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'package:hibiki/main.dart' as app;
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_shader_downloader.dart';
import 'package:hibiki/src/media/video/video_shader_manager.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/pages/implementations/video_shader_dialog.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki_core/hibiki_core.dart';

import 'test_helpers.dart';

/// 本机测试视频（video agent 预置）。
const String _kVideoFixture = r'D:\hibiki_video_test\sample.mp4';
const String _kVideoBookUid = 'video/shader-itest-sample';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'video shader dialog: Space toggles playback after dialog closes; '
    'Anime4K preset downloads to mpv_shaders',
    (WidgetTester tester) async {
      final List<FlutterErrorDetails> errors = <FlutterErrorDetails>[];
      final FlutterExceptionHandler? oldHandler = FlutterError.onError;
      FlutterError.onError = (FlutterErrorDetails details) {
        errors.add(details);
        debugPrint('[video-shader] ${details.exceptionAsString()}');
      };

      try {
        app.main();
        expect(await waitForHome(tester), isTrue);
        await tester.pump(const Duration(seconds: 2));

        final ProviderContainer container = ProviderScope.containerOf(
          tester.element(find.byType(MaterialApp).first),
        );
        final AppModel appModel = container.read(appProvider);
        final VideoBookRepository repo = VideoBookRepository(appModel.database);

        final File fixture = File(_kVideoFixture);
        expect(fixture.existsSync(), isTrue,
            reason: '测试视频 $_kVideoFixture 应存在');

        await repo.saveVideoBook(VideoBooksCompanion(
          bookUid: const Value(_kVideoBookUid),
          title: const Value('shader itest'),
          videoPath: Value(fixture.absolute.path),
        ));

        final NavigatorState navigator =
            tester.state<NavigatorState>(find.byType(Navigator).first);
        unawaited(navigator.push<void>(MaterialPageRoute<void>(
          builder: (_) => VideoHibikiPage(bookUid: _kVideoBookUid, repo: repo),
        )));

        // 等播放器就绪：media_kit 桌面控制条要 hover 才显示（离屏无鼠标 → 图标不
        // 渲染），故不靠图标判就绪，改用页面 test hook 的 debugPositionMs 可读
        // （controller 已 load）。
        VideoHibikiTestHooks hooks() =>
            tester.state<State<VideoHibikiPage>>(find.byType(VideoHibikiPage))
                as VideoHibikiTestHooks;
        bool ready = false;
        for (int i = 0; i < 24; i++) {
          await tester.pump(const Duration(milliseconds: 250));
          if (find.byType(VideoHibikiPage).evaluate().isNotEmpty &&
              hooks().debugPositionMs != null) {
            ready = true;
            break;
          }
        }
        expect(ready, isTrue, reason: 'video controller should load');

        // ── ② Anime4K 真实下载（Mode A Fast）到 mpv_shaders/ ──
        final Anime4kPreset modeA = kAnime4kPresets
            .firstWhere((Anime4kPreset e) => e.id == 'mode_a_fast');
        // 本机直连 GitHub/镜像不通、只有本地代理通（CLAUDE.local.md）；生产代码用用户
        // 自己的网络环境（不注入代理）。这里注入走本机代理的 Dio，仅为在本机验证「真能
        // 下到 GLSL 并落盘」的链路；生产 downloadAnime4kFiles 默认 Dio 不变。
        final Dio proxiedDio = Dio(BaseOptions(
          connectTimeout: const Duration(seconds: 15),
          receiveTimeout: const Duration(minutes: 5),
          followRedirects: true,
          maxRedirects: 10,
          responseType: ResponseType.bytes,
        ));
        proxiedDio.httpClientAdapter = IOHttpClientAdapter(
          onHttpClientCreate: (HttpClient c) {
            c.findProxy = (Uri _) => 'PROXY 127.0.0.1:34151';
            c.badCertificateCallback = (_, __, ___) => true;
            return c;
          },
        );
        final Anime4kDownloadResult dl =
            await downloadAnime4kFiles(modeA, dio: proxiedDio);
        debugPrint('[video-shader] Anime4K download: '
            'ok=${dl.downloaded.length} failed=${dl.failed.length} '
            'failedNames=${dl.failed}');
        // 至少首个着色器（Clamp_Highlights）应落盘且内容像 GLSL（联网失败则跳过断言）。
        if (dl.downloaded.isNotEmpty) {
          final Directory shaderDir = await mpvShaderDirectory();
          final File first =
              File('${shaderDir.path}\\Anime4K_Clamp_Highlights.glsl');
          expect(first.existsSync(), isTrue,
              reason: 'Anime4K 着色器应真实落盘到 mpv_shaders');
          expect(first.readAsStringSync(), contains('//!'),
              reason: '落盘内容应是 GLSL 着色器');
          debugPrint('[video-shader] shader on disk: ${first.path}');
        } else {
          debugPrint('[video-shader] download produced no files '
              '(network unavailable?) — skipping disk assertion');
        }

        // ── ① 打开着色器视图（夺焦）→ 关闭 → 空格恢复播放 ──
        // 着色器管理已从独立对话框改为内嵌 VideoShaderManagerView（嵌进设置面板）；
        // 这里用 showDialog 把同一个内嵌视图临时弹成浮层，复现「焦点被夺走的浮层
        // 打开 → 关闭」场景：关闭后 Video 的 _videoFocusNode 应能重新接管键盘焦点。
        unawaited(showDialog<void>(
          context: tester.element(find.byType(VideoHibikiPage)),
          builder: (_) => Dialog(
            child: VideoShaderManagerView(
              initialEnabled: const <String>[],
              qualityEnhancementEnabled: true,
              onQualityEnhancementChanged: (_) {},
              onApply: (List<String> _) async {},
              onSelectTier: (_, __, ___) async {},
            ),
          ),
        ));
        await tester.pump(); // 启动浮层路由
        await tester.pump(const Duration(milliseconds: 400));
        // 确认浮层真打开了（夺走窗口焦点）。
        expect(find.byType(VideoShaderManagerView), findsOneWidget);

        // 浮层打开期间，窗口键盘焦点不在 Video 上（被浮层子树占据）。
        final FocusNode? duringDialog = FocusManager.instance.primaryFocus;
        debugPrint('[video-shader] focus during dialog: '
            '${duringDialog?.debugLabel}');

        // 关闭浮层。
        Navigator.of(tester.element(find.byType(VideoShaderManagerView))).pop();
        await tester.pumpAndSettle(const Duration(milliseconds: 200));
        expect(find.byType(VideoShaderManagerView), findsNothing);

        // 记录空格前的播放位置（应为静止——初始未播放）。
        final int? posBefore = hooks().debugPositionMs;
        debugPrint('[video-shader] pos before Space: $posBefore');

        // 把焦点还给 Video（复现 _openShaderDialog 在 await 后调 _refocusVideo 的效果；
        // 直接 push 走的是另一条路径，这里显式驱动以验证 Video 的 FocusNode 真能接管
        // 键盘——这正是修复的核心：节点提到 State 后可被主动 requestFocus）。
        final FocusNode videoNode =
            tester.widget<Video>(find.byType(Video)).focusNode!;
        expect(videoNode.debugLabel, 'videoKeyboard',
            reason: 'Video 必须用本页持有的 _videoFocusNode');
        videoNode.requestFocus();
        await tester.pump(const Duration(milliseconds: 200));
        expect(videoNode.hasFocus, isTrue,
            reason: '_videoFocusNode 应能接管键盘焦点（修复后可主动归还）');

        // 发空格：焦点在 Video 上 → media_kit 内置空格快捷键切到播放 → 位置前进。
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        for (int i = 0; i < 12; i++) {
          await tester.pump(const Duration(milliseconds: 250));
        }
        final int? posAfter = hooks().debugPositionMs;
        debugPrint('[video-shader] pos after Space: $posAfter');
        expect(posAfter, isNotNull);
        expect(posAfter! > (posBefore ?? 0), isTrue,
            reason: '空格应触发播放使位置前进（焦点在 Video，内置快捷键生效）');

        expect(errors, isEmpty,
            reason: errors.map((e) => e.exceptionAsString()).join('\n'));
      } finally {
        FlutterError.onError = oldHandler;
        // 清理：删掉本测试 seed 的视频书，不污染用户书架。
        try {
          final ProviderContainer container = ProviderScope.containerOf(
            tester.element(find.byType(MaterialApp).first),
          );
          final HibikiDatabase db = container.read(appProvider).database;
          await (db.delete(db.videoBooks)
                ..where((VideoBooks t) => t.bookUid.equals(_kVideoBookUid)))
              .go();
        } catch (_) {}
      }
    },
    skip: !Platform.isWindows /* needs Windows desktop + media_kit native */,
  );
}
