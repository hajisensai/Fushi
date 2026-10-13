import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_expressive_progress.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_press_scale.dart';
import 'package:fushi/src/utils/components/fushi_search.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';

// Apple 设计系统下共享组件不漏出 M3E 形态（用户「所有组件都要遵循原有的
// Cupertino」）：
// - 波浪进度 / 形变加载指示在组件内部改走 Apple 进度（细线 / 菊花 / 细圆环），
//   直接调用点也正确；MD3 照旧是波浪。
// - FushiSearchAnchor 是圆角 10 的 iOS 搜索框（按下高亮、不缩放、无水波纹），
//   展开的搜索视图没有从搜索栏出发的容器变换。
// - FushiIconButton(isWideTapArea) 在 Apple 下按 fushiAppleCompact 口径给触控区。
// - FushiDialogRoute 在 Apple 下只淡入淡出（不缩放、不回弹）。

Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  required bool glass,
}) async {
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: glass ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: glass,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: FushiGlassScope(
        child: Scaffold(
          body: Center(child: SizedBox(width: 300, child: child)),
        ),
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('Expressive progress', () {
    testWidgets('Apple：波浪线性进度改走 Apple 细线（线宽不超过 iOS 4）', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const FushiWavyLinearProgress(
          value: 0.4,
          strokeWidth: 6,
          color: Colors.blue,
          trackColor: Colors.grey,
        ),
        glass: true,
      );
      final FushiAppleLinearProgress apple = tester.widget(
        find.byType(FushiAppleLinearProgress),
      );
      expect(apple.height, 4);
      expect(apple.color, Colors.blue);
      expect(apple.trackColor, Colors.grey);
      expect(tester.getSize(find.byType(FushiAppleLinearProgress)).height, 4);
    });

    testWidgets('MD3：波浪线性进度保持自绘波浪', (WidgetTester tester) async {
      await _pump(
        tester,
        const FushiWavyLinearProgress(
          value: 0.4,
          color: Colors.blue,
          trackColor: Colors.grey,
        ),
        glass: false,
      );
      expect(find.byType(FushiAppleLinearProgress), findsNothing);
      expect(
        find.descendant(
          of: find.byType(FushiWavyLinearProgress),
          matching: find.byType(CustomPaint),
        ),
        findsWidgets,
      );
    });

    testWidgets('Apple：波浪圆形进度 不定态=菊花、确定态=细圆环，外框不变', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        const Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            FushiWavyCircularProgress(
              key: ValueKey<String>('indeterminate'),
              color: Colors.blue,
              trackColor: Colors.grey,
            ),
            FushiWavyCircularProgress(
              key: ValueKey<String>('determinate'),
              value: 0.5,
              color: Colors.blue,
              trackColor: Colors.grey,
            ),
          ],
        ),
        glass: true,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('indeterminate')),
          matching: find.byType(CupertinoActivityIndicator),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(const ValueKey<String>('determinate')),
          matching: find.byType(FushiAppleProgressRing),
        ),
        findsOneWidget,
      );
      expect(
        tester.getSize(find.byKey(const ValueKey<String>('determinate'))),
        const Size(40, 40),
      );
    });

    testWidgets('Apple：Expressive 加载指示是菊花（无 contained 圆底）', (
      WidgetTester tester,
    ) async {
      await _pump(
        tester,
        // 外壳给 300 宽紧约束；包一层 Center 量自然尺寸（与 MD3 同为 48×48）。
        const Center(child: FushiExpressiveLoadingIndicator(contained: true)),
        glass: true,
      );
      expect(find.byType(CupertinoActivityIndicator), findsOneWidget);
      expect(
        tester.getSize(find.byType(FushiExpressiveLoadingIndicator)),
        const Size(48, 48),
      );
    });

    testWidgets('MD3：Expressive 加载指示不是菊花', (WidgetTester tester) async {
      await _pump(
        tester,
        const FushiExpressiveLoadingIndicator(),
        glass: false,
      );
      expect(find.byType(CupertinoActivityIndicator), findsNothing);
    });
  });

  group('FushiSearchAnchor', () {
    Future<void> pumpAnchor(WidgetTester tester, {required bool glass}) async {
      tester.view.physicalSize = const Size(420, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await _pump(
        tester,
        FushiSearchAnchor(
          hintText: 'Search books',
          resultsBuilder: (BuildContext context, String query) =>
              ListView(children: <Widget>[Text('result:$query')]),
        ),
        glass: glass,
      );
    }

    testWidgets('Apple：圆角 10 搜索框，按下高亮、不缩放、无水波纹', (WidgetTester tester) async {
      await pumpAnchor(tester, glass: true);
      final FushiPlainButton button = tester.widget(
        find.descendant(
          of: find.byType(FushiSearchAnchor),
          matching: find.byType(FushiPlainButton),
        ),
      );
      expect(button.borderRadius, const BorderRadius.all(Radius.circular(10)));
      expect(button.fill, isNotNull);
      expect(
        find.descendant(
          of: find.byType(FushiSearchAnchor),
          matching: find.byType(InkWell),
        ),
        findsNothing,
      );
      expect(
        find.descendant(
          of: find.byType(FushiSearchAnchor),
          matching: find.byType(FushiPressScale),
        ),
        findsNothing,
      );
    });

    testWidgets('Apple：搜索视图直接落在全屏目标，无容器变换', (WidgetTester tester) async {
      await pumpAnchor(tester, glass: true);
      await tester.tap(find.text('Search books'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final Finder surface = find
          .ancestor(
            of: find.byType(OverflowBox),
            matching: find.byType(Positioned),
          )
          .first;
      // 动画进行中表面已经是整屏（MD3 此时还在从搜索栏长出去）。
      expect(tester.getSize(surface), const Size(420, 900));
      await tester.pumpAndSettle();
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('MD3：仍是胶囊 + InkWell + 按压缩放', (WidgetTester tester) async {
      await pumpAnchor(tester, glass: false);
      expect(
        find.descendant(
          of: find.byType(FushiSearchAnchor),
          matching: find.byType(FushiPressScale),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(FushiSearchAnchor),
          matching: find.byType(FushiPlainButton),
        ),
        findsNothing,
      );
    });
  });

  testWidgets('Apple：isWideTapArea 图标按钮按 fushiAppleCompact 口径（移动 44）', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      Center(
        child: FushiIconButton(
          icon: FushiIcons.search,
          tooltip: 'search',
          isWideTapArea: true,
          onTap: () {},
        ),
      ),
      glass: true,
    );
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(InkWell), findsNothing);
    final Size size = tester.getSize(
      find
          .descendant(
            of: find.byType(FushiIconButton),
            matching: find.byType(GestureDetector),
          )
          .first,
    );
    expect(size.width, greaterThanOrEqualTo(44));
    expect(size.height, greaterThanOrEqualTo(44));
  });

  testWidgets('Apple：FushiDialogRoute 只淡入淡出（Apple effects 时长）', (
    WidgetTester tester,
  ) async {
    await _pump(
      tester,
      Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => showAppDialog<void>(
            context: context,
            builder: (_) => const Text('dialog body'),
          ),
          child: const Text('open'),
        ),
      ),
      glass: true,
    );
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 60));
    final ModalRoute<Object?> route = ModalRoute.of(
      tester.element(find.text('dialog body')),
    )!;
    expect(route, isA<FushiDialogRoute<void>>());
    expect(route.transitionDuration, fushiAppleDialogAnimationStyle.duration);
    // 进场中没有缩放：对话框内容的祖先里没有非单位缩放的 Transform。
    final Iterable<Transform> transforms = tester.widgetList<Transform>(
      find.ancestor(
        of: find.text('dialog body'),
        matching: find.byType(Transform),
      ),
    );
    for (final Transform t in transforms) {
      expect(t.transform.getMaxScaleOnAxis(), closeTo(1, 1e-6));
    }
    await tester.pumpAndSettle();
  });
}
