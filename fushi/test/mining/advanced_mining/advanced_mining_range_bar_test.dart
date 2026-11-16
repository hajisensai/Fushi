import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_capabilities.dart';
import 'package:fushi/src/mining/advanced_mining/advanced_mining_sections.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:material_ui/material_ui.dart';

/// 区间条端点可拖（反馈 66LR2RsYcl）：命中区、吸附、Shift / Ctrl 换档、方向键焦点
/// 路径。宿主用一个不夹取的最小实现，只验区间条自己的像素 ↔ 毫秒换算与手势分派。
void main() {
  // 原区间 [10000, 13000]、无偏移：域 = [9000, 14000]（外扩 1000），500px 宽 = 10ms/px；
  // 起点标记在 x=100，终点在 x=400。
  const int base0 = 10000;
  const int base1 = 13000;
  const double width = 500;

  late int startDelta;
  late int endDelta;
  late int dragEnds;
  late List<bool> lives;

  setUp(() {
    startDelta = 0;
    endDelta = 0;
    dragEnds = 0;
    lives = <bool>[];
  });

  Future<void> pumpBar(
    WidgetTester tester, {
    bool interactive = true,
    int stepMs = 250,
  }) async {
    tester.view.physicalSize = const Size(800, 400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(
          extensions: const <ThemeExtension<dynamic>>[
            FushiGlassTheme(FushiGlassMaterial.off),
          ],
        ),
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: width,
              child: StatefulBuilder(
                builder: (BuildContext context, StateSetter setState) =>
                    AdvancedMiningRangeBar(
                      window: AdvancedMiningAudioWindow(
                        startMs: base0 + startDelta,
                        endMs: base1 + endDelta,
                      ),
                      startDeltaMs: startDelta,
                      endDeltaMs: endDelta,
                      stepMs: stepMs,
                      onEdgeChanged: interactive
                          ? ({
                              required bool start,
                              required int deltaMs,
                              required bool live,
                            }) => setState(() {
                              lives.add(live);
                              if (start) {
                                startDelta = deltaMs;
                              } else {
                                endDelta = deltaMs;
                              }
                            })
                          : null,
                      onEdgeDragEnd: () => dragEnds++,
                    ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Offset at(WidgetTester tester, double x) {
    final Offset topLeft = tester.getTopLeft(
      find.byType(AdvancedMiningRangeBar),
    );
    return topLeft + Offset(x, AdvancedMiningRangeBar.height / 2);
  }

  Future<void> drag(WidgetTester tester, double fromX, double dx) async {
    await tester.dragFrom(at(tester, fromX), Offset(dx, 0));
    await tester.pumpAndSettle();
  }

  testWidgets('拖起点标记：10ms/px 换算、途中 live、松手回调一次', (WidgetTester tester) async {
    await pumpBar(tester);
    await drag(tester, 100, 30);
    expect(startDelta, 300);
    expect(endDelta, 0);
    expect(lives, isNotEmpty);
    expect(lives.every((bool l) => l), isTrue, reason: '拖动途中只做乐观更新');
    expect(dragEnds, 1);
  });

  testWidgets('拖终点标记往左', (WidgetTester tester) async {
    await pumpBar(tester);
    await drag(tester, 400, -45);
    expect(endDelta, -450);
    expect(startDelta, 0);
  });

  testWidgets('命中区 48dp：离标记 >24dp 按下不拖', (WidgetTester tester) async {
    await pumpBar(tester);
    await drag(tester, 250, 40);
    expect(startDelta, 0);
    expect(endDelta, 0);
    expect(dragEnds, 0);
    // 标记边上 20dp 仍算命中。
    await drag(tester, 120, 20);
    expect(startDelta, 200);
  });

  testWidgets('按住 Shift 拖：吸附到当前步长整数倍', (WidgetTester tester) async {
    await pumpBar(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await drag(tester, 100, 33);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    expect(startDelta, 250, reason: '330ms 吸到 250 的倍数');
  });

  testWidgets('按住 Ctrl 拖：位移减速到 1/5（精调）', (WidgetTester tester) async {
    await pumpBar(tester);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await drag(tester, 100, 50);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    expect(startDelta, 100, reason: '50px × 10ms ÷ 5');
  });

  testWidgets('焦点驱动：←/→ 按步长微调，Shift ×10、Ctrl 更细', (WidgetTester tester) async {
    await pumpBar(tester);
    final Focus handle = tester.widget<Focus>(
      find
          .ancestor(
            of: find.byKey(const ValueKey<String>('advancedMiningRangeStart')),
            matching: find.byType(Focus),
          )
          .first,
    );
    handle.focusNode!.requestFocus();
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(startDelta, 250);
    expect(lives.last, isFalse, reason: '方向键是完整改动，宿主要 describe');
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pumpAndSettle();
    expect(startDelta, 250 + 2500);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
    expect(startDelta, 250 + 2500 - 50);
    expect(endDelta, 0);
  });

  testWidgets('触摸拖完不留焦点环；改用键盘后才画', (WidgetTester tester) async {
    double ringWidth() {
      final Iterable<AnimatedContainer> dots = tester
          .widgetList<AnimatedContainer>(
            find.descendant(
              of: find.byKey(
                const ValueKey<String>('advancedMiningRangeStart'),
              ),
              matching: find.byType(AnimatedContainer),
            ),
          )
          .where(
            (AnimatedContainer c) =>
                (c.decoration as BoxDecoration?)?.shape == BoxShape.circle,
          );
      final BoxDecoration d = dots.single.decoration! as BoxDecoration;
      return (d.border! as Border).top.width;
    }

    await pumpBar(tester);
    await drag(tester, 100, 30);
    expect(
      FocusManager.instance.highlightMode,
      FocusHighlightMode.touch,
      reason: '前提：刚才是触摸输入',
    );
    expect(ringWidth(), 2, reason: '触摸拖完把手拿着焦点，但不画焦点环');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(startDelta, 300 + 250, reason: '焦点仍在起点，方向键接着微调');
    expect(ringWidth(), 3, reason: '键盘模式下显示焦点环');
  });

  testWidgets('读屏：两个端点是 slider，带标签与当前时刻', (WidgetTester tester) async {
    final SemanticsHandle semantics = tester.ensureSemantics();
    await pumpBar(tester);
    expect(
      tester.getSemantics(
        find.byKey(const ValueKey<String>('advancedMiningRangeEnd')),
      ),
      containsSemantics(
        isSlider: true,
        label: t.popup_advanced_mining_audio_end,
        value: formatAdvancedMiningTime(base1),
      ),
    );
    semantics.dispose();
  });

  testWidgets('不交互（锁定）：没有把手、拖动无效', (WidgetTester tester) async {
    await pumpBar(tester, interactive: false);
    expect(
      find.byKey(const ValueKey<String>('advancedMiningRangeStart')),
      findsNothing,
    );
    await drag(tester, 100, 30);
    expect(startDelta, 0);
  });
}
