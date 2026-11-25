// 横屏窗口（播视频时的手机横屏）打开 AI 助手：必须用吃满窗口高度的靠边侧栏，
// 而不是只拿 55% 高度的底部半屏面板（反馈 cP3rFztWT2 / BUG-4376）。
//
// 现象：792×360dp 的横屏手机上，底部面板高 0.55 × 360 ≈ 198dp，一打开就低于
// kAiAgentTightHeight（200），被压成标题 + 输入框，对话几乎看不见。
//
// 断言：
// - 横屏窗口（宽 > 高）一律走侧栏，竖屏窄窗口仍走底部面板，宽窗口仍走侧栏；
// - 侧栏宽度不超过窗口宽减外边距；
// - 侧栏外框在 792×360 下高度 = 窗口高度减两侧外边距，> kAiAgentTightHeight，
//   MD3 与 Apple 两套表面都如此。
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/ai_agent_page.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  group('aiAgentUsesSidePanel', () {
    test('横屏手机（792×360）用侧栏', () {
      expect(aiAgentUsesSidePanel(const Size(792, 360)), isTrue);
    });

    test('小横屏手机（640×360）用侧栏', () {
      expect(aiAgentUsesSidePanel(const Size(640, 360)), isTrue);
    });

    test('竖屏手机（360×792）用底部面板', () {
      expect(aiAgentUsesSidePanel(const Size(360, 792)), isFalse);
    });

    test('竖屏平板（800×1280）用底部面板', () {
      expect(aiAgentUsesSidePanel(const Size(800, 1280)), isFalse);
    });

    test('宽窗口（≥ 断点）用侧栏，即便竖着', () {
      expect(
        aiAgentUsesSidePanel(const Size(kAiAgentSidePanelBreakpoint, 1400)),
        isTrue,
      );
      expect(aiAgentUsesSidePanel(const Size(1280, 800)), isTrue);
    });

    test('横屏下底部面板高度本会低于紧凑阈值（守住改动的前提）', () {
      expect(
        360 * kAiAgentBottomSheetHeightFactor,
        lessThan(kAiAgentTightHeight),
      );
    });
  });

  group('aiAgentSidePanelWidth', () {
    test('宽窗口给满 kAiAgentSidePanelWidth', () {
      expect(
        aiAgentSidePanelWidth(const Size(1280, 800)),
        kAiAgentSidePanelWidth,
      );
      expect(
        aiAgentSidePanelWidth(const Size(792, 360)),
        kAiAgentSidePanelWidth,
      );
    });

    test('窄横屏窗口收到窗口宽减两侧外边距', () {
      expect(
        aiAgentSidePanelWidth(const Size(400, 300)),
        400 - kAiAgentSidePanelMargin * 2,
      );
    });

    test('极窄窗口不给负宽', () {
      expect(aiAgentSidePanelWidth(const Size(10, 5)), 0);
    });
  });

  ThemeData theme({required bool apple}) => buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    designSystem: apple
        ? FushiDesignSystem.cupertino
        : FushiDesignSystem.material,
    glass: FushiGlassMaterial.off,
    glassDesign: apple,
  );

  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds：横屏 792×360 侧栏吃满窗口高度', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(792, 360);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(apple: apple),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: const Scaffold(
            body: AiAgentSidePanelFrame(child: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Size panel = tester.getSize(find.byKey(kAiAgentSidePanelKey));
      expect(panel.width, kAiAgentSidePanelWidth);
      expect(panel.height, 360 - kAiAgentSidePanelMargin * 2);
      expect(panel.height, greaterThan(kAiAgentTightHeight));
      expect(
        find.byType(FushiAppleDialogPanel),
        apple ? findsOneWidget : findsNothing,
      );
    });

    testWidgets('$ds：横屏刘海 / Home 指示条安全区不压住侧栏', (WidgetTester tester) async {
      tester.view.physicalSize = const Size(844, 390);
      tester.view.devicePixelRatio = 1;
      tester.view.padding = const FakeViewPadding(
        left: 47,
        right: 47,
        bottom: 21,
      );
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme(apple: apple),
          builder: (BuildContext context, Widget? child) =>
              FushiGlassScope(child: child!),
          home: const Scaffold(
            body: AiAgentSidePanelFrame(child: SizedBox.expand()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final Rect panel = tester.getRect(find.byKey(kAiAgentSidePanelKey));
      expect(panel.right, 844 - 47 - kAiAgentSidePanelMargin);
      expect(panel.bottom, 390 - 21 - kAiAgentSidePanelMargin);
      expect(panel.height, greaterThan(kAiAgentTightHeight));
    });
  }
}
