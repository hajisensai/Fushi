// 同一个 media_kit VideoController 同时挂两个画面时的颜色实测（Windows runner，手动跑）。
//
// 复习卡「放大查看」把卡面上的片段播放器在对话框里再挂一次（同一个纹理 id 画两遍），
// 对话框里画面整片偏红。这里绕开 SRS / 对话框，只用 media_kit：同一个 controller 依次
// 挂「单个画面」「两个画面（第二个小）」「两个画面（第二个大）」「第二个换成裸 Texture」，
// 量每个画面区域的 RGB 均值，判断偏色跟「画两遍」还是跟「放大」有关。结果打
// `[mk-dual]` 行。
//
//   .\tool\run_windows_itest.ps1 integration_test/media_kit_dual_view_probe_itest.dart `
//     -DartDefine @('FUSHI_PROBE_CLIP=C:/path/clip720.mp4')
import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart'
    show resolvePlatformHwdec;
import 'package:fushi/src/pages/implementations/srs/srs_card_video_clip.dart'
    show SrsCardVideoExpandedView;
import 'package:fushi/src/startup/test_environment.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:integration_test/integration_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'helpers/observe_capture.dart';
import 'support/test_app_launcher.dart';
import 'test_helpers.dart';

const String _clip = String.fromEnvironment('FUSHI_PROBE_CLIP');

void _log(String line) {
  final String full = '[mk-dual] $line';
  debugPrint(full);
  final Directory? docs = fushiTestDirectory('app-documents');
  if (docs == null) return;
  File(
    '${docs.path}${Platform.pathSeparator}mk_dual_probe.txt',
  ).writeAsStringSync('$full\n', mode: FileMode.append, flush: true);
}

Future<void> _pumpFor(WidgetTester tester, Duration d) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < d) {
    await tester.pump(const Duration(milliseconds: 16));
  }
}

/// 根图层整帧 → 某区域 RGB 均值。
Future<String> _rgb(WidgetTester tester, Rect rect) async {
  final RenderView view = tester.binding.renderViews.first;
  final OffsetLayer layer = view.debugLayer! as OffsetLayer;
  final double dpr = tester.view.devicePixelRatio;
  final ui.Image? image = await tester.runAsync(
    () => layer.toImage(Offset.zero & view.size, pixelRatio: dpr),
  );
  if (image == null) return 'no image';
  final ByteData? px = await tester.runAsync<ByteData?>(
    () => image.toByteData(format: ui.ImageByteFormat.rawRgba),
  );
  if (px == null) return 'no bytes';
  final int x0 = (rect.left * dpr).round().clamp(0, image.width - 1);
  final int y0 = (rect.top * dpr).round().clamp(0, image.height - 1);
  final int x1 = (rect.right * dpr).round().clamp(0, image.width);
  final int y1 = (rect.bottom * dpr).round().clamp(0, image.height);
  double r = 0, g = 0, b = 0;
  int n = 0;
  for (int y = y0; y < y1; y += 2) {
    for (int x = x0; x < x1; x += 2) {
      final int i = (y * image.width + x) * 4;
      r += px.getUint8(i);
      g += px.getUint8(i + 1);
      b += px.getUint8(i + 2);
      n++;
    }
  }
  if (n == 0) return 'empty';
  return 'R=${(r / n).toStringAsFixed(0)} G=${(g / n).toStringAsFixed(0)} '
      'B=${(b / n).toStringAsFixed(0)}';
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('同一个 VideoController 挂两个画面的颜色', (WidgetTester tester) async {
    await launchFushiTestApp();
    expect(await waitForHome(tester), isTrue, reason: '主页应在 90s 内出现');
    await tester.pump(const Duration(seconds: 2));

    final Player player = Player();
    // 与复习卡片段 / 视频页同一套硬解取值（Windows：d3d11va 零拷贝优先）。
    final VideoController controller = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        hwdec: resolvePlatformHwdec('auto-safe'),
      ),
    );
    _log('home ready, opening $_clip');
    unawaited(player.open(Media(_clip), play: false));
    await _pumpFor(tester, const Duration(seconds: 3));
    unawaited(player.seek(const Duration(seconds: 2)));
    await _pumpFor(tester, const Duration(seconds: 1));
    _log(
      'opened size=${player.state.width}x${player.state.height} '
      'hwdec=${resolvePlatformHwdec('auto-safe')}',
    );

    // 0 = 单个；1 = 第二个小；2 = 第二个大；3 = 第二个是裸 Texture（大）；4 = 只有大的一个。
    final ValueNotifier<int> mode = ValueNotifier<int>(0);
    final GlobalKey a = GlobalKey();
    final GlobalKey b = GlobalKey();
    Widget video(Key key, double w) => SizedBox(
      key: key,
      width: w,
      height: w * 9 / 16,
      child: Video(
        controller: controller,
        controls: NoVideoControls,
        fill: Colors.black,
      ),
    );
    unawaited(
      Navigator.of(tester.element(find.byType(Navigator).first)).push(
        MaterialPageRoute<void>(
          builder: (BuildContext _) => Material(
            color: Colors.black,
            child: ValueListenableBuilder<int>(
              valueListenable: mode,
              builder: (BuildContext context, int m, Widget? _) => Stack(
                children: <Widget>[
                  if (m != 4)
                    Positioned(left: 20, top: 20, child: video(a, 320)),
                  if (m == 1)
                    Positioned(left: 20, top: 260, child: video(b, 320)),
                  if (m == 2 || m == 4)
                    Positioned(left: 380, top: 20, child: video(b, 960)),
                  if (m == 3)
                    Positioned(
                      left: 380,
                      top: 20,
                      child: ValueListenableBuilder<int?>(
                        valueListenable: controller.notifier.value!.id,
                        builder: (BuildContext context, int? id, Widget? _) =>
                            SizedBox(
                              key: b,
                              width: 960,
                              height: 540,
                              child: id == null
                                  ? const SizedBox()
                                  : Texture(textureId: id),
                            ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 2));
    for (int m = 0; m <= 4; m++) {
      mode.value = m;
      await _pumpFor(tester, const Duration(seconds: 2));
      final String ra = find.byKey(a).evaluate().isEmpty
          ? '-'
          : await _rgb(tester, tester.getRect(find.byKey(a)));
      final String rb = find.byKey(b).evaluate().isEmpty
          ? '-'
          : await _rgb(tester, tester.getRect(find.byKey(b)));
      _log('mode=$m first(320)=$ra second=$rb');
      await captureFlutterFrame(tester, 'mk-dual-mode-$m');
    }
    // 5：复习卡「放大查看」同一条路径（showAppDialog + SrsCardVideoExpandedView），
    // 底下的页面仍挂着 320 宽的那个画面。
    mode.value = 0;
    await _pumpFor(tester, const Duration(milliseconds: 500));
    final BuildContext pageContext = tester.element(find.byKey(a));
    unawaited(
      showAppDialog<void>(
        context: pageContext,
        builder: (BuildContext context) => SrsCardVideoExpandedView(
          aspect: 16 / 9,
          view: Video(
            controller: controller,
            controls: NoVideoControls,
            fill: Colors.transparent,
          ),
          onToggle: () {},
        ),
      ),
    );
    await _pumpFor(tester, const Duration(seconds: 2));
    final Finder dialogView = find.byKey(
      const ValueKey<String>('srs-card-video-expanded'),
    );
    final String rd = dialogView.evaluate().isEmpty
        ? '-'
        : await _rgb(tester, tester.getRect(dialogView));
    _log('mode=5 (showAppDialog + SrsCardVideoExpandedView) dialog=$rd');
    await captureFlutterFrame(tester, 'mk-dual-mode-5-dialog');
    _log('done');
    unawaited(player.dispose());
  }, skip: _clip.isEmpty);
}
