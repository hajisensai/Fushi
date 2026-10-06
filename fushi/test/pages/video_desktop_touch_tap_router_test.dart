import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'video_fushi_page_source_corpus.dart';

/// Windows 触屏（Surface）视频页：桌面控制条的点击层按指针类型分流。
///
/// 协作者反馈「视频 surface 只能靠双击切全屏才搞出 UI、也没法快退」。根因：桌面
/// 控制条只靠鼠标 hover 唤出（Flutter `MouseTracker` 不跟踪 touch 指针），单击又被
/// `playAndPauseOnTap` 吃成暂停。现在 touch / stylus 单击走移动端口径（切换控制条
/// 显隐），鼠标单击行为不变。这里用真实的 touch / mouse 指针驱动生产代码
/// [MaterialDesktopTapRouter]（vendored media_kit 里桌面控制条的点击层）。
void main() {
  const Size surfaceSize = Size(800, 600);
  const Offset center = Offset(400, 300);
  // 底栏带（进度条 / 按钮行附近）：路由层的 isInPlayPauseRegion 判 false。
  const Offset bottomStrip = Offset(400, 580);

  Widget harness({
    required List<DesktopControlsTapAction> actions,
    bool playAndPauseOnTap = true,
    bool touchTapTogglesControls = true,
    bool initiallyVisible = false,
    Widget? overlay,
  }) {
    bool visible = initiallyVisible;
    return MaterialApp(
      home: StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) {
          return Center(
            child: SizedBox.fromSize(
              size: surfaceSize,
              child: MaterialDesktopTapRouter(
                playAndPauseOnTap: playAndPauseOnTap,
                touchTapTogglesControls: touchTapTogglesControls,
                controlsVisible: visible,
                isInPlayPauseRegion: (Offset global) {
                  final RenderBox box =
                      context.findRenderObject()! as RenderBox;
                  final Offset local = box.globalToLocal(global);
                  return local.dy < surfaceSize.height - 60;
                },
                onAction: (DesktopControlsTapAction action) {
                  actions.add(action);
                  // 与真实控制条 State 一致：show / keepAlive → 可见，hide → 不可见。
                  setState(() {
                    if (action == DesktopControlsTapAction.showControls ||
                        action == DesktopControlsTapAction.keepControlsAlive) {
                      visible = true;
                    } else if (action ==
                        DesktopControlsTapAction.hideControls) {
                      visible = false;
                    }
                  });
                },
                child: Stack(
                  children: <Widget>[
                    const Positioned.fill(
                      child: ColoredBox(color: Color(0xFF000000)),
                    ),
                    if (overlay != null) overlay,
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  testWidgets('touch 单击：控制条隐藏时唤出、可见时收起，不改播放态', (
    WidgetTester tester,
  ) async {
    final List<DesktopControlsTapAction> actions = <DesktopControlsTapAction>[];
    await tester.pumpWidget(harness(actions: actions));

    await tester.tapAt(center, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(actions, <DesktopControlsTapAction>[
      DesktopControlsTapAction.showControls,
    ]);

    // 隔开双击窗口再点一次：可见 → 收起。
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(center, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(actions, <DesktopControlsTapAction>[
      DesktopControlsTapAction.showControls,
      DesktopControlsTapAction.hideControls,
    ]);
    expect(actions, isNot(contains(DesktopControlsTapAction.playOrPause)));
  });

  testWidgets('stylus 单击与 touch 同口径', (WidgetTester tester) async {
    final List<DesktopControlsTapAction> actions = <DesktopControlsTapAction>[];
    await tester.pumpWidget(harness(actions: actions));
    await tester.tapAt(center, kind: PointerDeviceKind.stylus);
    await tester.pump();
    expect(actions, <DesktopControlsTapAction>[
      DesktopControlsTapAction.showControls,
    ]);
  });

  testWidgets('touch 双击（页面层的左/右快退快进手势）不会顺带暂停再恢复', (
    WidgetTester tester,
  ) async {
    // 页面外层 Listener（_handleVideoPointerUp）按 400ms / 48px 认双击并分左右区
    // seek；此前桌面点击层把两次 tap 都当 playOrPause，双击 seek 时画面先停后放。
    final List<DesktopControlsTapAction> actions = <DesktopControlsTapAction>[];
    await tester.pumpWidget(harness(actions: actions));
    const Offset left = Offset(100, 300);
    await tester.tapAt(left, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(milliseconds: 120));
    await tester.tapAt(left, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(actions, hasLength(2));
    expect(actions, isNot(contains(DesktopControlsTapAction.playOrPause)));
  });

  testWidgets('touch 点底栏带（按钮间隙 / 进度条旁）只续命，不收起', (
    WidgetTester tester,
  ) async {
    final List<DesktopControlsTapAction> actions = <DesktopControlsTapAction>[];
    await tester.pumpWidget(harness(actions: actions, initiallyVisible: true));
    await tester.tapAt(bottomStrip, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(actions, <DesktopControlsTapAction>[
      DesktopControlsTapAction.keepControlsAlive,
    ]);
  });

  testWidgets('鼠标单击行为不变：画面区播放/暂停，底栏带不动作', (
    WidgetTester tester,
  ) async {
    final List<DesktopControlsTapAction> actions = <DesktopControlsTapAction>[];
    await tester.pumpWidget(harness(actions: actions));
    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(bottomStrip, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(actions, <DesktopControlsTapAction>[
      DesktopControlsTapAction.playOrPause,
    ]);
  });

  testWidgets('鼠标单击在「点击画面播放/暂停」关闭时无动作（控制条靠 hover）', (
    WidgetTester tester,
  ) async {
    final List<DesktopControlsTapAction> actions = <DesktopControlsTapAction>[];
    await tester.pumpWidget(
      harness(actions: actions, playAndPauseOnTap: false),
    );
    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(actions, isEmpty);

    // 同一设置下触屏仍能唤出控制条。
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(center, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(actions, <DesktopControlsTapAction>[
      DesktopControlsTapAction.showControls,
    ]);
  });

  testWidgets('未开启 touchTapTogglesControls 时 touch 与上游一致（播放/暂停）', (
    WidgetTester tester,
  ) async {
    final List<DesktopControlsTapAction> actions = <DesktopControlsTapAction>[];
    await tester.pumpWidget(
      harness(actions: actions, touchTapTogglesControls: false),
    );
    await tester.tapAt(center, kind: PointerDeviceKind.touch);
    await tester.pump();
    expect(actions, <DesktopControlsTapAction>[
      DesktopControlsTapAction.playOrPause,
    ]);
  });

  testWidgets('BUG-374：点到控制条按钮时按钮赢竞技场，点击层不动作', (
    WidgetTester tester,
  ) async {
    final List<DesktopControlsTapAction> actions = <DesktopControlsTapAction>[];
    int buttonTaps = 0;
    await tester.pumpWidget(
      harness(
        actions: actions,
        overlay: Positioned(
          left: 350,
          top: 250,
          width: 100,
          height: 100,
          child: GestureDetector(
            onTap: () => buttonTaps++,
            child: const ColoredBox(color: Color(0xFF00FF00)),
          ),
        ),
      ),
    );
    await tester.tapAt(center, kind: PointerDeviceKind.touch);
    await tester.pump(const Duration(seconds: 1));
    await tester.tapAt(center, kind: PointerDeviceKind.mouse);
    await tester.pump();
    expect(buttonTaps, 2);
    expect(actions, isEmpty);
  });

  group('resolveDesktopControlsTap 纯判据', () {
    DesktopControlsTapAction resolve(
      PointerDeviceKind? kind, {
      bool inRegion = true,
      bool visible = false,
      bool playPause = true,
      bool touchToggles = true,
    }) =>
        resolveDesktopControlsTap(
          kind: kind,
          inPlayPauseRegion: inRegion,
          controlsVisible: visible,
          playAndPauseOnTap: playPause,
          touchTapTogglesControls: touchToggles,
        );

    test('触控类指针', () {
      expect(isTouchLikePointerKind(PointerDeviceKind.touch), isTrue);
      expect(isTouchLikePointerKind(PointerDeviceKind.stylus), isTrue);
      expect(isTouchLikePointerKind(PointerDeviceKind.invertedStylus), isTrue);
      expect(isTouchLikePointerKind(PointerDeviceKind.mouse), isFalse);
      expect(isTouchLikePointerKind(PointerDeviceKind.trackpad), isFalse);
      expect(isTouchLikePointerKind(null), isFalse);
    });

    test('鼠标 / 触控板 / 未知类型走桌面口径', () {
      for (final PointerDeviceKind? kind in <PointerDeviceKind?>[
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
        null,
      ]) {
        expect(resolve(kind), DesktopControlsTapAction.playOrPause);
        expect(
            resolve(kind, visible: true), DesktopControlsTapAction.playOrPause);
        expect(resolve(kind, inRegion: false), DesktopControlsTapAction.none);
        expect(resolve(kind, playPause: false), DesktopControlsTapAction.none);
      }
    });

    test('touch 走移动端口径', () {
      const PointerDeviceKind touch = PointerDeviceKind.touch;
      expect(resolve(touch), DesktopControlsTapAction.showControls);
      expect(
          resolve(touch, visible: true), DesktopControlsTapAction.hideControls);
      expect(resolve(touch, visible: true, inRegion: false),
          DesktopControlsTapAction.keepControlsAlive);
      expect(resolve(touch, playPause: false),
          DesktopControlsTapAction.showControls);
      expect(resolve(touch, touchToggles: false),
          DesktopControlsTapAction.playOrPause);
    });
  });

  group('页面接线', () {
    final String corpus = readVideoFushiSource();

    test('桌面控制条主题开启触屏分流', () {
      final String flat = corpus.replaceAll(RegExp(r'\s+'), '');
      expect(flat.contains('touchTapTogglesControls:true,'), isTrue,
          reason: '_desktopControlsTheme 必须开启 touchTapTogglesControls');
    });

    test('双击左/右 seek 不看指针类型；指针类型只决定落空双击（中带）的动作', () {
      final int start = corpus.indexOf(
        'void _handleVideoPointerUp(PointerUpEvent event) {',
      );
      expect(start, greaterThanOrEqualTo(0));
      final int end = corpus.indexOf('void _handleVideoWheelSignal(', start);
      expect(end, greaterThan(start));
      final String body = corpus.substring(start, end);
      final int seekIdx = body.indexOf('_handleDoubleTapSeek(');
      final int kindIdx = body.indexOf('event.kind');
      expect(seekIdx, greaterThanOrEqualTo(0));
      expect(kindIdx, greaterThan(seekIdx),
          reason: '双击左/右 seek 必须对 touch 与 mouse 同样生效（先于指针类型判定）');
      expect('event.kind'.allMatches(body).length, 1);
      expect(body.contains('isTouchLikePointerKind(event.kind)'), isTrue,
          reason: '指针类型只经 isTouchLikePointerKind 喂给中带判据');
    });
  });
}
