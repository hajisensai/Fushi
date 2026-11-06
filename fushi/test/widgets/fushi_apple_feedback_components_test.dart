// Apple 设计系统下的反馈类共享件（用户「所有组件都要遵循原有的 Cupertino」）：
// 下拉刷新是 iOS 菊花而不是 Material 圆盘；按压 / 悬停照常缩放（所有者
// 2026-10-13 拍板；切换设计系统不重建子 State）；轮播项不缩放不压暗；标签点击是按下变淡（无 InkWell）；滑动操作
// 底是满高、图标在上文字在下。MD3 路径保持原样。
import 'dart:async';

import 'package:cupertino_ui/cupertino_ui.dart' show CupertinoActivityIndicator;
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_carousel.dart';
import 'package:fushi/src/utils/components/fushi_hover_lift.dart';
import 'package:fushi/src/utils/components/fushi_m3e_feedback.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_tag.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:material_ui/material_ui.dart';

final ColorScheme _scheme = ColorScheme.fromSeed(seedColor: Colors.teal);

Widget _app(
  Widget body, {
  required bool glass,
  TargetPlatform platform = TargetPlatform.android,
}) {
  final ThemeData theme = buildFushiThemeData(
    scheme: _scheme,
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  ).copyWith(platform: platform);
  return MaterialApp(
    theme: theme,
    home: FushiGlassScope(child: Scaffold(body: body)),
  );
}

Widget _refreshList(RefreshCallback onRefresh) => FushiRefreshIndicator(
  onRefresh: onRefresh,
  child: ListView(
    physics: const AlwaysScrollableScrollPhysics(),
    children: <Widget>[
      for (int i = 0; i < 5; i++) SizedBox(height: 60, child: Text('row $i')),
    ],
  ),
);

Future<void> _pullDown(WidgetTester tester, {required double distance}) async {
  final TestGesture gesture = await tester.startGesture(
    tester.getCenter(find.text('row 1')),
  );
  const int steps = 12;
  for (int i = 0; i < steps; i++) {
    await gesture.moveBy(Offset(0, distance / steps));
    await tester.pump(const Duration(milliseconds: 16));
  }
  await gesture.up();
  await tester.pump();
}

void main() {
  group('FushiRefreshIndicator', () {
    testWidgets('MD3：仍是 Material RefreshIndicator', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(_app(_refreshList(() async {}), glass: false));
      expect(find.byType(RefreshIndicator), findsOneWidget);
    });

    for (final TargetPlatform platform in <TargetPlatform>[
      TargetPlatform.iOS,
      TargetPlatform.android,
    ]) {
      testWidgets('Apple（${platform.name} 物理）：下拉过阈值触发一次，菊花转到完成再收回', (
        WidgetTester tester,
      ) async {
        int calls = 0;
        final Completer<void> done = Completer<void>();
        await tester.pumpWidget(
          _app(
            _refreshList(() {
              calls++;
              return done.future;
            }),
            glass: true,
            platform: platform,
          ),
        );
        expect(find.byType(RefreshIndicator), findsNothing);
        expect(find.byType(CupertinoActivityIndicator), findsNothing);

        // 拉一小段：菊花逐格显现，但不触发。
        final TestGesture short = await tester.startGesture(
          tester.getCenter(find.text('row 1')),
        );
        for (int i = 0; i < 4; i++) {
          await short.moveBy(const Offset(0, 8));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
        expect(calls, 0);
        await short.up();
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoActivityIndicator), findsNothing);

        await _pullDown(tester, distance: 480);
        expect(calls, 1, reason: '过阈值只触发一次 onRefresh');
        await tester.pump(const Duration(milliseconds: 600));
        expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
        // 刷新期间内容停在 60 高处。
        expect(
          tester.getTopLeft(find.text('row 0')).dy,
          greaterThanOrEqualTo(59),
        );

        done.complete();
        await tester.pumpAndSettle();
        expect(find.byType(CupertinoActivityIndicator), findsNothing);
        expect(tester.getTopLeft(find.text('row 0')).dy, closeTo(0, 0.5));
        expect(calls, 1);
      });
    }
  });

  group('FushiPressScale / FushiHoverLift', () {
    testWidgets('Apple：按压照常缩放（所有者拍板保留按压缩放）', (WidgetTester tester) async {
      const Key box = Key('box');
      await tester.pumpWidget(
        _app(
          const Center(
            // 子节点要能被命中：空 SizedBox 不参与 hit-test，按下根本到不了 Listener。
            child: FushiPressScale(
              child: SizedBox(
                key: box,
                width: 40,
                height: 40,
                child: ColoredBox(color: Color(0xFF000000)),
              ),
            ),
          ),
          glass: true,
        ),
      );
      final Finder transition = find.descendant(
        of: find.byType(FushiPressScale),
        matching: find.byType(ScaleTransition),
      );
      expect(transition, findsOneWidget);
      final TestGesture press = await tester.startGesture(
        tester.getCenter(find.byKey(box)),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<ScaleTransition>(transition).scale.value,
        lessThan(1.0),
        reason: 'Apple 下按住时内容缩小',
      );
      await press.up();
      await tester.pumpAndSettle();
      expect(
        tester.widget<ScaleTransition>(transition).scale.value,
        closeTo(1.0, 0.001),
      );
    });

    testWidgets('切换设计系统不重建子 State（不按设计系统增删包装层）', (WidgetTester tester) async {
      final List<String> inits = <String>[];
      Widget tree({required bool glass}) => _app(
        Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiPressScale(
                child: _InitProbe(tag: 'press', log: inits),
              ),
              FushiHoverLift(
                builder: (BuildContext context, bool hovering) =>
                    _InitProbe(tag: 'hover', log: inits),
              ),
            ],
          ),
        ),
        glass: glass,
      );
      await tester.pumpWidget(tree(glass: false));
      expect(inits, <String>['press', 'hover']);
      await tester.pumpWidget(tree(glass: true));
      await tester.pumpAndSettle();
      await tester.pumpWidget(tree(glass: false));
      await tester.pumpAndSettle();
      expect(inits, <String>[
        'press',
        'hover',
      ], reason: 'MD3 与 Apple 来回切换，子 State 一次都不重建');
    });

    testWidgets('MD3：按压仍缩放', (WidgetTester tester) async {
      await tester.pumpWidget(
        _app(
          const Center(
            child: FushiPressScale(child: SizedBox(width: 40, height: 40)),
          ),
          glass: false,
        ),
      );
      expect(
        find.descendant(
          of: find.byType(FushiPressScale),
          matching: find.byType(ScaleTransition),
        ),
        findsOneWidget,
      );
    });

    testWidgets('Apple：悬停轻微放大，悬停态照常交给 builder', (WidgetTester tester) async {
      bool hovering = false;
      const Key card = Key('card');
      await tester.pumpWidget(
        _app(
          Center(
            child: FushiHoverLift(
              builder: (BuildContext context, bool value) {
                hovering = value;
                return const SizedBox(key: card, width: 100, height: 100);
              },
            ),
          ),
          glass: true,
        ),
      );
      final Rect rectBefore = tester.getRect(find.byKey(card));
      final TestGesture mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.byKey(card)));
      await tester.pumpAndSettle();
      expect(hovering, isTrue);
      final Rect rectAfter = tester.getRect(find.byKey(card));
      expect(
        rectAfter.width,
        closeTo(rectBefore.width * kFushiAppleHoverLiftScale, 0.01),
        reason: 'Apple 默认放大倍数是更轻的 kFushiAppleHoverLiftScale',
      );
      expect(rectAfter.center.dx, closeTo(rectBefore.center.dx, 0.01));
    });
  });

  testWidgets('FushiCarouselItemTransform / FushiParallax：Apple 不缩放不压暗', (
    WidgetTester tester,
  ) async {
    const Key item = Key('item');
    await tester.pumpWidget(
      _app(
        const Center(
          child: SizedBox(
            width: 200,
            height: 100,
            child: FushiCarouselItemOffset(
              offset: 0.6,
              child: FushiCarouselItemTransform(
                child: FushiParallax(child: SizedBox.expand(key: item)),
              ),
            ),
          ),
        ),
        glass: true,
      ),
    );
    expect(
      find.ancestor(of: find.byKey(item), matching: find.byType(Opacity)),
      findsNothing,
    );
    expect(tester.getSize(find.byKey(item)), const Size(200, 100));
    expect(
      find.descendant(
        of: find.byType(FushiCarouselItemTransform),
        matching: find.byType(Transform),
      ),
      findsNothing,
    );
  });

  testWidgets('FushiTag：Apple 可点标签按下变淡，无 InkWell', (WidgetTester tester) async {
    await tester.pumpWidget(
      _app(
        const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              FushiTag(
                text: 'noun',
                message: 'a noun',
                tone: FushiTagTone.neutral,
              ),
              FushiTag(text: 'plain', tone: FushiTagTone.neutral),
            ],
          ),
        ),
        glass: true,
      ),
    );
    expect(
      find.descendant(
        of: find.byType(FushiTag),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.text('noun'),
        matching: find.byType(FushiPlainButton),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.text('plain'),
        matching: find.byType(FushiPlainButton),
      ),
      findsNothing,
      reason: '不可点的标签不包按钮',
    );
  });

  testWidgets('FushiSwipeActionBackground：Apple 图标在上、文字在下', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(
        const SizedBox(
          height: 64,
          child: FushiSwipeActionBackground(
            icon: Icons.delete,
            label: 'Delete',
            destructive: true,
          ),
        ),
        glass: true,
      ),
    );
    // Apple 下 FushiIcon 把 Material 字形映射成 SF 风格，按组件找而不是按字形。
    final Rect icon = tester.getRect(find.byType(FushiIcon));
    final Rect label = tester.getRect(find.text('Delete'));
    expect(icon.bottom, lessThanOrEqualTo(label.top));
    expect(icon.center.dx, closeTo(label.center.dx, 0.5));
  });
}

/// initState 时往 [log] 里记一笔 [tag]：用来断言「切换设计系统不重建子 State」。
class _InitProbe extends StatefulWidget {
  const _InitProbe({required this.tag, required this.log});

  final String tag;
  final List<String> log;

  @override
  State<_InitProbe> createState() => _InitProbeState();
}

class _InitProbeState extends State<_InitProbe> {
  @override
  void initState() {
    super.initState();
    widget.log.add(widget.tag);
  }

  @override
  Widget build(BuildContext context) => const SizedBox(width: 40, height: 40);
}
