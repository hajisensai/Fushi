// qUeubxE-fM（Windows）：「返回跳转前位置」胶囊在鼠标停在边缘时持续闪烁、上下抖动。
//
// 机理：胶囊盖在 media_kit 控制条的 MouseRegion 之上，且 top / visible 跟着控制条可见性
// 走。鼠标落到胶囊 → 控制条那层 onExit 收起 → 胶囊淡出上移 → 鼠标落回控制条那层 →
// onEnter 重新显示 → 胶囊回到鼠标下 → 再 onExit……鼠标不动也自激振荡。
//
// 本测试用真实 MouseTracker 复现这条环（同一套「控制条 MouseRegion + 跟随可见性的胶囊」
// 几何），先证明旧结构确实振荡，再证明 [resolveVideoJumpPillLayout] + [VideoHoverHoldRegion]
// + 「悬停开始时控制条可见就按住」三件一起用时稳定；另钉页面的接线。
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/video/video_jump_pill_hover.dart';

import '../../pages/video_fushi_page_source_corpus.dart';

const double _shownTop = 60;
const double _hiddenTop = 8;
const double _pillHeight = 40;

/// 与视频页同构的最小几何：底层是 media_kit 控制条的 MouseRegion（enter / hover 显示，
/// exit 在没被按住时收起），上层是跟随控制条可见性的胶囊。
class _Harness extends StatefulWidget {
  const _Harness({required this.fixed});

  /// true = 视频页现在的接法；false = 修前（胶囊布局恒取实时值、悬停不按住控制条）。
  final bool fixed;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  bool controlsVisible = true;
  bool held = false;
  bool hovered = false;
  VideoJumpPillLayout? last;
  int toggles = 0;

  void _setVisible(bool v) {
    if (controlsVisible == v) return;
    setState(() {
      controlsVisible = v;
      toggles++;
    });
  }

  void _onHover(bool h) {
    setState(() => hovered = h);
    final bool hold = h && videoJumpPillHoverHoldsControls(last);
    held = hold;
    if (hold) _setVisible(true);
  }

  @override
  Widget build(BuildContext context) {
    final VideoJumpPillLayout live = VideoJumpPillLayout(
      top: controlsVisible ? _shownTop : _hiddenTop,
      visible: controlsVisible,
      chromeShown: controlsVisible,
    );
    final VideoJumpPillLayout layout = widget.fixed
        ? resolveVideoJumpPillLayout(hovered: hovered, frozen: last, live: live)
        : live;
    last = layout;
    final Widget pill = Center(
      child: IgnorePointer(
        ignoring: !layout.visible,
        child: const MouseRegion(
          child: SizedBox(width: 120, height: _pillHeight),
        ),
      ),
    );
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: MouseRegion(
              onEnter: (_) => _setVisible(true),
              onHover: (_) => _setVisible(true),
              onExit: (_) {
                if (!held) _setVisible(false);
              },
            ),
          ),
          Positioned(
            top: layout.top,
            left: 0,
            right: 0,
            child: widget.fixed
                ? VideoHoverHoldRegion(onHoverChanged: _onHover, child: pill)
                : pill,
          ),
        ],
      ),
    );
  }
}

Future<TestGesture> _parkMouseOnPill(WidgetTester tester) async {
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer(location: const Offset(400, 300));
  await tester.pump();
  // 鼠标停在「控制条可见时胶囊所在」的那一行，之后不再移动。
  await mouse.moveTo(Offset(400, _shownTop + _pillHeight / 2));
  for (int i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 16));
  }
  return mouse;
}

void main() {
  group('鼠标停在胶囊上不动', () {
    testWidgets('修前的结构自激振荡（证明复现的就是反馈里的环）', (WidgetTester tester) async {
      await tester.pumpWidget(const _Harness(fixed: false));
      final TestGesture mouse = await _parkMouseOnPill(tester);
      final _HarnessState state = tester.state(find.byType(_Harness));
      expect(state.toggles, greaterThan(4), reason: '控制条在鼠标不动时反复显隐');
      await mouse.removePointer();
    });

    testWidgets('冻结胶囊布局 + 悬停按住控制条：稳定、控制条保持可见', (WidgetTester tester) async {
      await tester.pumpWidget(const _Harness(fixed: true));
      final TestGesture mouse = await _parkMouseOnPill(tester);
      final _HarnessState state = tester.state(find.byType(_Harness));
      final int settled = state.toggles;
      for (int i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(state.toggles, settled, reason: '悬停期间不再有任何显隐翻转');
      expect(state.toggles, lessThanOrEqualTo(2));
      expect(state.controlsVisible, isTrue);
      expect(state.hovered, isTrue);
      expect(state.held, isTrue);
      // 鼠标移开胶囊：放开按住，胶囊恢复跟随控制条。
      await mouse.moveTo(const Offset(400, 400));
      await tester.pump();
      expect(state.hovered, isFalse);
      expect(state.held, isFalse);
      await mouse.removePointer();
    });
  });

  group('resolveVideoJumpPillLayout / videoJumpPillHoverHoldsControls', () {
    const VideoJumpPillLayout shown = VideoJumpPillLayout(
      top: _shownTop,
      visible: true,
      chromeShown: true,
    );
    const VideoJumpPillLayout hidden = VideoJumpPillLayout(
      top: _hiddenTop,
      visible: false,
      chromeShown: false,
    );

    test('悬停中沿用上一帧布局，不悬停取实时值', () {
      expect(
        resolveVideoJumpPillLayout(hovered: true, frozen: shown, live: hidden),
        shown,
      );
      expect(
        resolveVideoJumpPillLayout(hovered: false, frozen: shown, live: hidden),
        hidden,
      );
      expect(
        resolveVideoJumpPillLayout(hovered: true, frozen: null, live: hidden),
        hidden,
      );
    });

    test('只有悬停开始时控制条可见才按住控制条（闪现态不唤出控制条）', () {
      expect(videoJumpPillHoverHoldsControls(shown), isTrue);
      expect(
        videoJumpPillHoverHoldsControls(
          const VideoJumpPillLayout(
            top: _hiddenTop,
            visible: true,
            chromeShown: false,
          ),
        ),
        isFalse,
      );
      expect(videoJumpPillHoverHoldsControls(null), isFalse);
    });
  });

  group('videoJumpPillLiveVisible（自动隐藏）', () {
    test('未过期：闪现或控制条可见时显示，两者都没有不显示', () {
      expect(
        videoJumpPillLiveVisible(
          chromeShown: true,
          flashing: false,
          expired: false,
        ),
        isTrue,
      );
      expect(
        videoJumpPillLiveVisible(
          chromeShown: false,
          flashing: true,
          expired: false,
        ),
        isTrue,
      );
      expect(
        videoJumpPillLiveVisible(
          chromeShown: false,
          flashing: false,
          expired: false,
        ),
        isFalse,
      );
    });

    test('过期后控制条再出现也不显示', () {
      expect(
        videoJumpPillLiveVisible(
          chromeShown: true,
          flashing: true,
          expired: true,
        ),
        isFalse,
      );
    });

    test('选项含 5 / 10 / 15 秒与「不隐藏」(0)，默认值在选项内', () {
      expect(kVideoJumpPillAutoHideOptions, <int>[5, 10, 15, 0]);
      expect(
        kVideoJumpPillAutoHideOptions,
        contains(kVideoJumpPillAutoHideDefaultSeconds),
      );
    });

    test('视频页接线：可见性走 videoJumpPillLiveVisible，历史变化重新计时', () {
      final String src = readVideoFushiSource();
      expect(src.contains('visible: videoJumpPillLiveVisible('), isTrue);
      expect(src.contains('_armVideoJumpPillAutoHide(active: flash);'), isTrue);
      expect(src.contains('appModel.videoJumpPillAutoHideSeconds'), isTrue);
    });
  });

  group('VideoHoverHoldRegion', () {
    testWidgets('只认子树真实命中；悬停中被卸载也补一次 false', (WidgetTester tester) async {
      final List<bool> events = <bool>[];
      Widget build({required bool present}) => Directionality(
        textDirection: TextDirection.ltr,
        child: present
            ? VideoHoverHoldRegion(
                onHoverChanged: events.add,
                child: const Center(
                  child: MouseRegion(child: SizedBox(width: 50, height: 50)),
                ),
              )
            : const SizedBox.expand(),
      );
      await tester.pumpWidget(build(present: true));
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      // 区域内但子树外（Center 留白）：不算悬停。
      await mouse.addPointer(location: const Offset(5, 5));
      await tester.pump();
      expect(events, isEmpty);
      await mouse.moveTo(tester.getCenter(find.byType(SizedBox)));
      await tester.pump();
      expect(events, <bool>[true]);
      await tester.pumpWidget(build(present: false));
      await tester.pump();
      expect(events, <bool>[true, false], reason: 'MouseRegion 被移除时不发 onExit');
      await mouse.removePointer();
    });
  });

  test('视频页接线：胶囊包 VideoHoverHoldRegion、布局走冻结解析、悬停按住控制条', () {
    final String src = readVideoFushiSource();
    expect(
      src.contains('onHoverChanged: _onVideoJumpPillHoverChanged,'),
      isTrue,
    );
    expect(src.contains('resolveVideoJumpPillLayout('), isTrue);
    expect(src.contains('videoJumpPillHoverHoldsControls('), isTrue);
    expect(
      src.contains(
        '_controlsHeld.value = _controlsHoldMenuOpen || _controlsHoldJumpPill;',
      ),
      isTrue,
    );
    expect(
      File('lib/src/media/video/video_jump_pill_hover.dart').existsSync(),
      isTrue,
    );
  });
}
