import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/adaptive/adaptive_navigation.dart'
    show
        AdaptiveNavPeekAction,
        AdaptiveNavPeekCoverList,
        AdaptiveNavPeekEntry,
        AdaptiveNavPeekStatusTone;
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:material_ui/material_ui.dart';

// 2026-11-20 反馈 #6：侧栏漫画速览卡底部四行，鼠标快速划过时变深要过一会才跟上；
// 每行缺一个「加声音」入口。
//
// 根因：行外壳是分段分组的形变 FushiCard，悬停时圆角随弹簧逐帧变化，而卡把这个
// 圆角作为 InkWell.borderRadius 传入——InkWell 在 borderRadius 变化时把悬停高亮
// 销毁重建（从透明重新淡入），于是弹簧走完之前高亮一直被拉回 0。修法：状态层
// 外形改走 customBorder（变化时原地更新高亮外形），见 FushiCard._buildMd3Surface。

final ColorScheme _scheme = ColorScheme.fromSeed(seedColor: Colors.indigo);

Future<void> _pump(WidgetTester tester, List<AdaptiveNavPeekEntry> entries) {
  tester.view.physicalSize = const Size(420, 520);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ThemeData theme = buildFushiThemeData(
    scheme: _scheme,
    textTheme: Typography.material2021().black,
    glass: FushiGlassMaterial.off,
    glassDesign: false,
  );
  return tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(14),
            child: FushiEntranceScope(
              child: AdaptiveNavPeekCoverList(
                entries: entries,
                fallbackIcon: FushiIcons.manga,
                onOpen: (AdaptiveNavPeekEntry e) => e.onOpen(),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

Finder _row(int i) => find.byKey(ValueKey<String>('nav-peek-row-$i'));

/// 第 [i] 行行内动作的目标不透明度（1 = 本行处于悬停 / 焦点态）。
double _actionOpacity(WidgetTester tester, int i) => tester
    .widget<AnimatedOpacity>(
      find.descendant(
        of: _row(i),
        matching: find.byKey(const ValueKey<String>('nav-peek-row-action')),
      ),
    )
    .opacity;

/// 第 [i] 行状态层（InkWell 悬停高亮，onSurface 色）此刻实际画出的不透明度。
double _stateLayerAlpha(WidgetTester tester, int i) {
  final Element ink = tester.element(
    find.descendant(of: _row(i), matching: find.byType(InkWell)).first,
  );
  final RenderObject features = Material.of(ink) as RenderObject;
  final TestRecordingCanvas canvas = TestRecordingCanvas();
  features.paint(TestRecordingPaintingContext(canvas), Offset.zero);
  final Color onSurface = Theme.of(ink).colorScheme.onSurface;
  double alpha = 0;
  for (final RecordedInvocation call in canvas.invocations) {
    for (final Object? arg in call.invocation.positionalArguments) {
      if (arg is! Paint) continue;
      final Color c = arg.color;
      final bool sameHue =
          (c.r - onSurface.r).abs() < 0.01 &&
          (c.g - onSurface.g).abs() < 0.01 &&
          (c.b - onSurface.b).abs() < 0.01;
      if (sameHue && c.a > alpha) alpha = c.a;
    }
  }
  return alpha;
}

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.zhCn));

  int added = 0;
  int opened = 0;
  List<AdaptiveNavPeekEntry> entries() => <AdaptiveNavPeekEntry>[
    for (int i = 0; i < 3; i++)
      AdaptiveNavPeekEntry.noCover(
        title: '漫画 $i',
        subtitle: '${i + 1} · 10%',
        progress: 0.1,
        onOpen: () => opened++,
        action: AdaptiveNavPeekAction(
          icon: FushiIcons.audio,
          label: t.manga_audio_workbench_add_sound,
          onPressed: () => added++,
        ),
      ),
    AdaptiveNavPeekEntry.noCover(
      title: '有声的那本',
      onOpen: () => opened++,
      status: t.manga_audio_workbench_has_audio,
      statusIcon: FushiIcons.audio,
      statusTone: AdaptiveNavPeekStatusTone.active,
    ),
  ];

  setUp(() {
    added = 0;
    opened = 0;
  });

  testWidgets('鼠标从一行移到下一行：一帧后新行即悬停态、旧行不是；变深不等形变弹簧', (
    WidgetTester tester,
  ) async {
    await _pump(tester, entries());
    await tester.pumpAndSettle();
    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: const Offset(400, 510));
    addTearDown(mouse.removePointer);

    // 先停在第 0 行等一切落定，量出「完全变深」的不透明度。
    await mouse.moveTo(tester.getCenter(_row(0)));
    await tester.pumpAndSettle();
    final double full = _stateLayerAlpha(tester, 0);
    expect(full, greaterThan(0), reason: '悬停应画出状态层');

    // 划到第 1 行，只 pump 一帧：悬停归属立刻换到新行。
    await mouse.moveTo(tester.getCenter(_row(1)));
    await tester.pump();
    expect(_actionOpacity(tester, 1), 1);
    expect(_actionOpacity(tester, 0), 0);

    // 再过一个悬停淡入时长（InkWell 50ms，取 60ms）：新行已完全变深，而形变弹簧
    // 还在走——旧实现这里每帧重建高亮，不透明度只有满值的三分之一左右。
    await tester.pump(const Duration(milliseconds: 60));
    expect(tester.hasRunningAnimations, isTrue, reason: '形变弹簧应仍在动画中');
    expect(_stateLayerAlpha(tester, 1), greaterThanOrEqualTo(full * 0.95));
    await tester.pump(const Duration(milliseconds: 200));
    expect(_stateLayerAlpha(tester, 0), lessThan(full * 0.05));
    await tester.pumpAndSettle();
  });

  testWidgets('有声的行常显「有声」签、没有「加声音」；「加声音」只在悬停时出现且可点', (
    WidgetTester tester,
  ) async {
    await _pump(tester, entries());
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: _row(3), matching: find.text('有声')),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: _row(3),
        matching: find.byKey(const ValueKey<String>('nav-peek-row-action')),
      ),
      findsNothing,
    );
    // 没悬停：按钮透明且不接指针，点它的位置等于点整行（打开作品）。
    expect(_actionOpacity(tester, 0), 0);

    final TestGesture mouse = await tester.createGesture(
      kind: PointerDeviceKind.mouse,
    );
    await mouse.addPointer(location: tester.getCenter(_row(0)));
    addTearDown(mouse.removePointer);
    await tester.pumpAndSettle();
    expect(_actionOpacity(tester, 0), 1);
    await tester.tap(
      find.descendant(of: _row(0), matching: find.text('加声音')),
      kind: PointerDeviceKind.mouse,
    );
    await tester.pumpAndSettle();
    expect(added, 1);
    expect(opened, 0, reason: '点「加声音」不应同时打开作品');
  });

  testWidgets('键盘焦点落到行上时「加声音」出现，Tab 能走到它', (WidgetTester tester) async {
    await _pump(tester, entries());
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    expect(_actionOpacity(tester, 0), 1);
    expect(_actionOpacity(tester, 1), 0);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    // 焦点从行走到同一行的按钮：仍算本行聚焦，按钮保持可见。
    expect(_actionOpacity(tester, 0), 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(added, 1);
  });
}
