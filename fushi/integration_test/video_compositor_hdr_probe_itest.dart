import 'dart:async';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/main.dart' as app;
import 'package:fushi/src/media/video/video_hdr_output.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/pages/implementations/video_fushi_page.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/video/video_book_repository.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';

import 'test_helpers.dart';

/// 合成器内 HDR 取证（`docs/specs/2026-10-06-hdr-in-flutter-compositor.md`）：在真实 app
/// 里把一个 HDR 片源以「总是」模式播出来，让补丁引擎按 `FUSHI_HDR_PROBE=repeat` 每 30 帧
/// 回读一次 backing store 中线三点（一行 `HDR probe #N at=<epoch> renderer=... store=...`）。
///
/// 同一片源、同一窗口尺寸下，Skia 与 Impeller 两种渲染器的回读值应一致——这是「换渲染器后
/// HDR 效果不变」的证据：Present 的 scRGB 解码 pass 与 ANGLE 交换链两种渲染器共用，渲染器
/// 相关的只有「画进 backing store 的值」。四段：播放（控件自动隐藏）、悬停（控件显示）、
/// 背景滤镜（左四分之一回读点上盖一块 `BackdropFilter`，Impeller 在有背景滤镜的帧里整帧走
/// 离屏层）、暂停。每段打出带 epoch 的控件状态，与回读行的 `at=` 对齐。
///
/// 片源经环境变量给出（仓库不带；PQ / bt.2020 10-bit 即可，例如左右两半不同亮度的纯色）：
///   $env:FUSHI_HDR_ITEST_VIDEO = 'D:/media/hdrsplit.mp4'
///   $env:FUSHI_HDR_PROBE = 'repeat'
///   $env:FUSHI_HDR_PROBE_LOG = 'D:/tmp/probe.log'  # 引擎日志不进 flutter test 输出
///   $env:FUSHI_HDR_ITEST_FAKE_DISPLAY = '1000'     # 可选，见下
///   powershell -File fushi/tool/run_windows_itest.ps1 `
///     -Target integration_test/video_compositor_hdr_probe_itest.dart
const String _kBookUid = 'video/itest-compositor-hdr-probe';

/// `FUSHI_HDR_ITEST_FAKE_DISPLAY=<峰值尼特>`：把 runner 的 `displayInfo` 答成一块 HDR10
/// 显示器（界面白 80 尼特）。SDR 桌面上「总是」模式的参考白对齐界面白、峰值压到 203，
/// backing store 永远 ≤1.0，看不出扩展范围有没有被钳；假装 HDR 显示器后 mpv 按绝对亮度
/// 出，参考白 203 尼特落在界面白的 2.54 倍，回读值 >1 才能证明整条渲染链没钳到 8-bit。
/// 交换链仍在 SDR 桌面上（DWM 截掉 >1 的部分），本测试只看 backing store。
final double _kFakeHdrDisplayPeakNits =
    double.tryParse(
      Platform.environment['FUSHI_HDR_ITEST_FAKE_DISPLAY'] ?? '',
    ) ??
    0;

void _fakeHdrDisplay(IntegrationTestWidgetsFlutterBinding binding) {
  const StandardMethodCodec codec = StandardMethodCodec();
  final TestDefaultBinaryMessenger messenger = binding.defaultBinaryMessenger;
  messenger.setMockMessageHandler(HdrOutputChannel.channelName, (
    ByteData? message,
  ) async {
    final MethodCall call = codec.decodeMethodCall(message);
    if (call.method == 'displayInfo') {
      return codec.encodeSuccessEnvelope(<String, Object>{
        'colorSpace': kDxgiColorSpaceHdr10,
        'maxLuminance': _kFakeHdrDisplayPeakNits,
        'bitsPerColor': 10,
        'sdrWhiteNits': kScRgbWhiteNits,
      });
    }
    return messenger.delegate.send(HdrOutputChannel.channelName, message);
  });
}

void main() {
  final IntegrationTestWidgetsFlutterBinding binding =
      IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final String? videoPath = Platform.environment['FUSHI_HDR_ITEST_VIDEO'];

  testWidgets(
    'HDR source renders into half-float backing stores (probe readback)',
    (WidgetTester tester) async {
      if (_kFakeHdrDisplayPeakNits > 0) _fakeHdrDisplay(binding);
      app.main(const <String>[]);
      expect(await waitForHome(tester), isTrue);
      await tester.pump(const Duration(seconds: 2));

      final ProviderContainer container = ProviderScope.containerOf(
        tester.element(find.byType(MaterialApp).first),
      );
      final AppModel appModel = container.read(appProvider);
      await appModel.setVideoHdrOutputMode(VideoHdrOutputMode.always);
      final VideoBookRepository repo = VideoBookRepository(appModel.database);
      await repo.saveVideoBook(
        VideoBooksCompanion(
          bookUid: const Value(_kBookUid),
          title: const Value('compositor hdr probe'),
          videoPath: Value(File(videoPath!).absolute.path),
        ),
      );

      final NavigatorState navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => VideoFushiPage(bookUid: _kBookUid, repo: repo),
          ),
        ),
      );

      VideoFushiTestHooks? readHooks() {
        if (find.byType(VideoFushiPage).evaluate().isEmpty) return null;
        return tester.state<State<VideoFushiPage>>(find.byType(VideoFushiPage))
            as VideoFushiTestHooks;
      }

      bool ready = false;
      for (int i = 0; i < 120; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (readHooks()?.debugPositionMs != null) {
          ready = true;
          break;
        }
      }
      expect(ready, isTrue, reason: '控制器应在 load 后就绪');
      if (readHooks()?.debugIsPlaying != true) await readHooks()!.debugPlay();

      bool hdrActive = false;
      for (int i = 0; i < 80; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        if (readHooks()?.debugHdrCompositorActive == true) {
          hdrActive = true;
          break;
        }
      }
      debugPrint('[hdr-itest] compositor HDR active=$hdrActive');
      expect(hdrActive, isTrue, reason: '「总是」模式下补丁引擎应接受 HDR 输出');

      final Stopwatch sw = Stopwatch()..start();
      // 悬停唤起控制条：控制条里有 BackdropFilter，Impeller 遇到背景滤镜整帧改走离屏层，
      // 这一段的回读证明离屏层没有把扩展范围钳回 8-bit。
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      final Offset center = tester.getCenter(find.byType(VideoFushiPage));
      await mouse.addPointer(location: center);
      Future<void> phase(
        String label,
        Duration length, {
        bool hover = false,
      }) async {
        bool? lastControls;
        final Duration end = sw.elapsed + length;
        int tick = 0;
        while (sw.elapsed < end) {
          if (hover && tick++ % 5 == 0) {
            await mouse.moveTo(center + Offset((tick % 2) * 8.0, 0));
          }
          await tester.pump(const Duration(milliseconds: 100));
          final bool controls = readHooks()?.debugControlsVisible ?? false;
          if (controls != lastControls) {
            lastControls = controls;
            debugPrint(
              '[hdr-itest] $label t=${sw.elapsedMilliseconds}ms '
              'epoch=${DateTime.now().millisecondsSinceEpoch} '
              'controls=$controls',
            );
          }
        }
        debugPrint(
          '[hdr-itest] $label end epoch=${DateTime.now().millisecondsSinceEpoch}',
        );
      }

      await phase('playing', const Duration(seconds: 6));
      await phase('hover', const Duration(seconds: 6), hover: true);
      // 背景滤镜段：在左四分之一回读点（扁平的亮区）上盖一块 BackdropFilter 模糊。
      // Impeller 遇到背景滤镜时整帧改画进离屏层、模糊本身再走一个子 pass；两者若按上下文
      // 默认的 8-bit 分配，这一点会被钳成 1.0（扁平区域模糊前后同值，>1 才说明没钳）。
      final OverlayEntry backdrop = OverlayEntry(
        builder: (BuildContext context) {
          final Size size = MediaQuery.sizeOf(context);
          return Positioned(
            left: size.width / 4 - 60,
            top: size.height / 2 - 60,
            width: 120,
            height: 120,
            child: IgnorePointer(
              child: ClipRect(
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 8, sigmaY: 8),
                  child: const SizedBox.expand(),
                ),
              ),
            ),
          );
        },
      );
      navigator.overlay!.insert(backdrop);
      debugPrint(
        '[hdr-itest] backdrop t=${sw.elapsedMilliseconds}ms '
        'epoch=${DateTime.now().millisecondsSinceEpoch} controls=backdrop',
      );
      await phase('backdrop', const Duration(seconds: 5));
      backdrop.remove();
      await readHooks()!.debugPause();
      await phase('paused', const Duration(seconds: 4));
      await mouse.removePointer();
      debugPrint(
        '[hdr-itest] done hdrActive='
        '${readHooks()?.debugHdrCompositorActive}',
      );

      await navigator.maybePop();
      for (int i = 0; i < 40; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.byType(VideoFushiPage).evaluate().isEmpty) break;
      }
      await appModel.setVideoHdrOutputMode(VideoHdrOutputMode.auto);
    },
    skip: videoPath == null || !Platform.isWindows,
  );
}
