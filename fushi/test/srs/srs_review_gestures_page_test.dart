// 「复习选项」→「手势」设置页（MD3 / Apple 两套设计系统）：
//
// - 两面各一组、每个手势一行，副标题是当前动作；
// - 选动作走整页选择，写回 AppModel（映射偏好）；问题面的选项里没有评分，答案面没有
//   「显示答案」；
// - 「只留重来 / 良好」时绑在困难 / 简单上的行注明不生效；
// - 重置回默认（默认时重置键禁用）；
// - 「复习选项」面板里的入口行打开本页。
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_gestures_page.dart';
import 'package:fushi/src/pages/implementations/srs/srs_review_layout_sheet.dart';
import 'package:fushi/src/srs/srs_review_gestures.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

import '../helpers/test_platform_services.dart';

/// 手势映射与「只留重来 / 良好」放内存里（不碰数据库）。
class _GesturesApp extends AppModel {
  _GesturesApp({this.hideHardEasy = false}) : super(testPlatformServices());

  SrsReviewGestureMap map = SrsReviewGestureMap.defaults;
  final bool hideHardEasy;

  @override
  SrsReviewGestureMap get srsReviewGestures => map;

  @override
  Future<void> setSrsReviewGestures(SrsReviewGestureMap value) async {
    map = value;
    notifyListeners();
  }

  @override
  bool get srsReviewHideHardEasy => hideHardEasy;
}

Future<void> _pump(
  WidgetTester tester,
  _GesturesApp app, {
  required bool apple,
  Widget home = const SrsReviewGesturesPage(),
}) async {
  tester.view.physicalSize = const Size(900, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[appProvider.overrideWith((Ref ref) => app)],
      child: TranslationProvider(
        child: MaterialApp(
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: home,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder _row(SrsReviewSide side, SrsReviewGesture g) =>
    find.byKey(ValueKey<String>('srs-gesture-${side.name}-${g.wire}'));

void main() {
  setUp(() => LocaleSettings.setLocale(AppLocale.en));

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('[$ds] 两面各一组、每个手势一行，带进场动效；副标题是当前动作', (
      WidgetTester tester,
    ) async {
      await _pump(tester, _GesturesApp(), apple: apple);
      expect(
        find.byKey(const ValueKey<String>('srs-gestures-note')),
        findsOneWidget,
      );
      for (final SrsReviewSide side in SrsReviewSide.values) {
        expect(
          find.byKey(ValueKey<String>('srs-gestures-section-${side.name}')),
          findsOneWidget,
        );
        for (final SrsReviewGesture g in SrsReviewGesture.values) {
          expect(_row(side, g), findsOneWidget, reason: '${side.name} $g');
        }
      }
      expect(find.byType(FushiEntranceScope), findsOneWidget);
      expect(find.byType(FushiStaggeredEntrance), findsNWidgets(3));
      // 默认：单击三区切换顶栏，其余什么都不做。
      expect(
        find.descendant(
          of: _row(SrsReviewSide.front, SrsReviewGesture.tapLeft),
          matching: find.text(t.srs_review_gestures_action_toggle_toolbar),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _row(SrsReviewSide.back, SrsReviewGesture.swipeLeft),
          matching: find.text(t.srs_review_gestures_action_none),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FushiIconButton>(
              find.byKey(const ValueKey<String>('srs-gestures-reset')),
            )
            .enabled,
        isFalse,
        reason: '默认映射时重置键禁用',
      );
    });

    testWidgets('[$ds] 选动作：整页选择写回映射；问题面选项里没有评分，答案面没有显示答案', (
      WidgetTester tester,
    ) async {
      final _GesturesApp app = _GesturesApp();
      await _pump(tester, app, apple: apple);

      await tester.tap(_row(SrsReviewSide.front, SrsReviewGesture.tapLeft));
      await tester.pumpAndSettle();
      expect(find.text(t.srs_rating_good), findsNothing);
      await tester.tap(
        find
            .text(
              srsReviewGestureActionLabel(SrsReviewGestureAction.showAnswer),
            )
            .last,
      );
      await tester.pumpAndSettle();
      expect(
        app.map.actionFor(SrsReviewSide.front, SrsReviewGesture.tapLeft),
        SrsReviewGestureAction.showAnswer,
      );

      await tester.tap(_row(SrsReviewSide.back, SrsReviewGesture.swipeLeft));
      await tester.pumpAndSettle();
      expect(
        find.text(
          srsReviewGestureActionLabel(SrsReviewGestureAction.showAnswer),
        ),
        findsNothing,
      );
      await tester.tap(find.text(t.srs_rating_good).last);
      await tester.pumpAndSettle();
      expect(
        app.map.actionFor(SrsReviewSide.back, SrsReviewGesture.swipeLeft),
        SrsReviewGestureAction.rateGood,
      );
      expect(
        find.descendant(
          of: _row(SrsReviewSide.back, SrsReviewGesture.swipeLeft),
          matching: find.text(t.srs_rating_good),
        ),
        findsOneWidget,
      );
      // 另一面同一手势不受影响。
      expect(
        app.map.actionFor(SrsReviewSide.front, SrsReviewGesture.swipeLeft),
        SrsReviewGestureAction.none,
      );

      // 重置回默认。
      await tester.tap(
        find.byKey(const ValueKey<String>('srs-gestures-reset')),
      );
      await tester.pumpAndSettle();
      expect(app.map, SrsReviewGestureMap.defaults);
    });

    testWidgets('[$ds] 只留重来 / 良好：绑在困难上的行注明不生效', (WidgetTester tester) async {
      final _GesturesApp app = _GesturesApp(hideHardEasy: true)
        ..map = SrsReviewGestureMap.defaults
            .withBinding(
              SrsReviewSide.back,
              SrsReviewGesture.swipeUp,
              SrsReviewGestureAction.rateHard,
            )
            .withBinding(
              SrsReviewSide.back,
              SrsReviewGesture.swipeDown,
              SrsReviewGestureAction.rateAgain,
            );
      await _pump(tester, app, apple: apple);
      final String hidden =
          '${srsReviewGestureActionLabel(SrsReviewGestureAction.rateHard)}'
          ' · ${t.srs_review_gestures_rating_hidden}';
      expect(
        find.descendant(
          of: _row(SrsReviewSide.back, SrsReviewGesture.swipeUp),
          matching: find.text(hidden),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _row(SrsReviewSide.back, SrsReviewGesture.swipeDown),
          matching: find.text(t.srs_rating_again),
        ),
        findsOneWidget,
      );
    });

    testWidgets('[$ds]「复习选项」面板的入口行打开手势页', (WidgetTester tester) async {
      await _pump(
        tester,
        _GesturesApp(),
        apple: apple,
        home: const Scaffold(
          body: SingleChildScrollView(child: SrsReviewLayoutSheet()),
        ),
      );
      final Finder entry = find.byKey(
        const ValueKey<String>('srs-review-layout-gestures'),
      );
      expect(entry, findsOneWidget);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.byType(SrsReviewGesturesPage), findsOneWidget);
    });
  }
}
