import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_horizontal_seek_gesture.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'video_fushi_page_source_corpus.dart';

/// Windows 触屏（Surface）视频页的滑动手势：桌面控制条在 touch / stylus 指针下
/// 复用移动端那套横滑 seek / 右半竖滑音量 / 左半竖滑亮度（vendored media_kit 的
/// [TouchSwipeGestureLayer]），鼠标拖动一律不进这些识别器。用真实 touch / mouse
/// 指针拖动驱动生产组件。
void main() {
  const Size surfaceSize = Size(800, 600);
  const Duration mediaDuration = Duration(minutes: 20);
  const Duration base = Duration(minutes: 5);

  // 与页面同一 resolver（[_resolveTouchSeekDelta] → VideoHorizontalSeekGesture）。
  Duration resolver({
    required double dragDx,
    required double surfaceWidth,
    required Duration duration,
    required Duration position,
  }) =>
      VideoHorizontalSeekGesture.resolveDelta(
        dragDx: dragDx,
        surfaceWidth: surfaceWidth,
        duration: duration,
        position: position,
        sensitivity: VideoSeekSensitivity.medium,
      );

  late List<Duration> seeks;
  late List<double> volumes;
  late List<double> brightness;
  late List<DesktopControlsTapAction> taps;
  late int controlTaps;

  setUp(() {
    seeks = <Duration>[];
    volumes = <double>[];
    brightness = <double>[];
    taps = <DesktopControlsTapAction>[];
    controlTaps = 0;
  });

  Widget harness({bool brightnessGesture = false, bool volumeGesture = true}) {
    return MaterialApp(
      home: Center(
        child: SizedBox.fromSize(
          size: surfaceSize,
          // 与桌面控制条同构：点击层是祖先，滑动层在控件下方（Stack 底层），
          // 控件（这里一个顶部按钮）盖在上面。
          child: MaterialDesktopTapRouter(
            playAndPauseOnTap: true,
            touchTapTogglesControls: true,
            controlsVisible: false,
            isInPlayPauseRegion: (_) => true,
            onAction: taps.add,
            child: Stack(
              children: <Widget>[
                Positioned.fill(
                  child: TouchSwipeGestureLayer(
                    seekGesture: true,
                    horizontalSeekResolver: resolver,
                    duration: () => mediaDuration,
                    seekBase: () => base,
                    onSeek: seeks.add,
                    seekIndicatorBuilder: (BuildContext _, Duration delta) =>
                        Text('seek ${delta.inSeconds}'),
                    volumeGesture: volumeGesture,
                    currentVolume: () => 0.5,
                    onVolumeChanged: volumes.add,
                    brightnessGesture: brightnessGesture,
                    currentBrightness: () => 0.5,
                    onBrightnessChanged: brightness.add,
                    verticalGestureSensitivity: 200,
                  ),
                ),
                Positioned(
                  left: 0,
                  top: 0,
                  width: 120,
                  height: 60,
                  child: GestureDetector(
                    onTap: () => controlTaps++,
                    child: const ColoredBox(color: Color(0xFF00FF00)),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Offset at(WidgetTester tester, double dx, double dy) =>
      tester.getTopLeft(find.byType(TouchSwipeGestureLayer)) + Offset(dx, dy);

  testWidgets('touch 横滑：拖动中显示预览，松手按 resolver 增量 seek', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    final TestGesture gesture = await tester.startGesture(
      at(tester, 200, 300),
      kind: PointerDeviceKind.touch,
    );
    for (int i = 0; i < 10; i++) {
      await gesture.moveBy(const Offset(30, 0));
      await tester.pump();
    }
    expect(find.textContaining('seek '), findsOneWidget,
        reason: '拖动中应显示目标时间预览（宿主 seekIndicatorBuilder）');
    expect(seeks, isEmpty, reason: '松手前不 seek');
    await gesture.up();
    await tester.pump();

    expect(seeks, hasLength(1));
    expect(seeks.single, greaterThan(base), reason: '向右拖 = 前进');
    expect(seeks.single, lessThanOrEqualTo(mediaDuration));
    expect(find.textContaining('seek '), findsNothing, reason: '松手后预览收起');
    expect(taps, isEmpty, reason: '拖动不是单击，不得切控制条 / 暂停');
  });

  testWidgets('touch 左滑后退且钳在 0', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.dragFrom(
      at(tester, 700, 300),
      const Offset(-600, 0),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(seeks, hasLength(1));
    expect(seeks.single, lessThan(base));
    expect(seeks.single, greaterThanOrEqualTo(Duration.zero));
  });

  testWidgets('touch 右半竖滑调音量：上滑增大，从当前音量起算', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.dragFrom(
      at(tester, 600, 400),
      const Offset(0, -100),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(volumes, isNotEmpty);
    expect(volumes.last, greaterThan(0.5));
    expect(volumes.every((double v) => v >= 0 && v <= 1), isTrue);
    expect(brightness, isEmpty);
    expect(seeks, isEmpty);
    expect(taps, isEmpty);

    volumes.clear();
    await tester.dragFrom(
      at(tester, 600, 200),
      const Offset(0, 100),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(volumes.last, lessThan(0.5), reason: '下滑减小');
  });

  testWidgets('左半竖滑：亮度不可控（桌面）时无动作，可控时调亮度', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.dragFrom(
      at(tester, 200, 400),
      const Offset(0, -100),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(brightness, isEmpty);
    expect(volumes, isEmpty, reason: '左半不是音量');

    await tester.pumpWidget(harness(brightnessGesture: true));
    await tester.dragFrom(
      at(tester, 200, 400),
      const Offset(0, -100),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(brightness, isNotEmpty);
    expect(brightness.last, greaterThan(0.5));
  });

  testWidgets('stylus 与 touch 同口径', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.dragFrom(
      at(tester, 600, 400),
      const Offset(0, -100),
      kind: PointerDeviceKind.stylus,
    );
    await tester.pump();
    expect(volumes, isNotEmpty);
  });

  testWidgets('鼠标拖动不触发 seek / 音量 / 亮度', (WidgetTester tester) async {
    await tester.pumpWidget(harness(brightnessGesture: true));
    await tester.dragFrom(
      at(tester, 200, 300),
      const Offset(300, 0),
      kind: PointerDeviceKind.mouse,
    );
    await tester.dragFrom(
      at(tester, 600, 400),
      const Offset(0, -100),
      kind: PointerDeviceKind.mouse,
    );
    await tester.dragFrom(
      at(tester, 200, 400),
      const Offset(0, -100),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pump();
    expect(seeks, isEmpty);
    expect(volumes, isEmpty);
    expect(brightness, isEmpty);
  });

  testWidgets('起点落在控件上的拖动让给控件，不 seek', (WidgetTester tester) async {
    await tester.pumpWidget(harness());
    await tester.dragFrom(
      at(tester, 40, 30),
      const Offset(300, 0),
      kind: PointerDeviceKind.touch,
    );
    await tester.pump();
    expect(seeks, isEmpty);
    // 控件本身照常可点。
    await tester.tapAt(at(tester, 40, 30), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(controlTaps, 1);
  });

  testWidgets('纯点击不被滑动层吞掉：touch 单击仍切控制条', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(harness());
    await tester.tapAt(at(tester, 400, 300), kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(taps, <DesktopControlsTapAction>[
      DesktopControlsTapAction.showControls,
    ]);
    expect(seeks, isEmpty);
    expect(volumes, isEmpty);
  });

  group('页面接线', () {
    final String corpus = readVideoFushiSource();
    String desktopTheme() {
      final int start = corpus.indexOf(
        'MaterialDesktopVideoControlsThemeData _desktopControlsTheme(',
      );
      expect(start, greaterThanOrEqualTo(0));
      final int end = corpus.indexOf('Duration _resolveTouchSeekDelta(', start);
      expect(end, greaterThan(start));
      return corpus.substring(start, end).replaceAll(RegExp(r'\s+'), '');
    }

    test('桌面主题开启触屏横滑 / 竖滑，复用移动端 resolver / HUD / 回调', () {
      final String body = desktopTheme();
      for (final String wiring in <String>[
        'touchSeekGesture:true,',
        'horizontalSeekResolver:_resolveTouchSeekDelta,',
        '_buildSeekIndicator(controller,delta)',
        'touchVolumeGesture:_asbConfig.volumeSwipeGesture,',
        'onVolumeChanged:_onMediaKitVolumeChanged,',
        'touchBrightnessGesture:_brightness.canControl&&'
            '_asbConfig.brightnessSwipeGesture,',
        'onBrightnessChanged:_onMediaKitBrightnessChanged,',
        'controller.captureRelativeSeekBaseMs()',
      ]) {
        expect(body.contains(wiring), isTrue, reason: '缺接线：$wiring');
      }
    });

    test('移动端主题与桌面触屏共用同一个横滑 resolver', () {
      final String flat = corpus.replaceAll(RegExp(r'\s+'), '');
      expect(
        'horizontalSeekResolver:_resolveTouchSeekDelta,'
            .allMatches(flat)
            .length,
        2,
      );
    });
  });
}
