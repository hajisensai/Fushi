// R0 复核：迁移页「开始升级」的键盘可达性（焦点驱动，只发合成按键，不点坐标）。
//
// 接线与正式版同构：MaterialApp.builder 里 wrapWithGlobalNavigation 包 FushiFocusRoot（main.dart），页面外面
// 套一层首页外壳那样的整页键事件 sink（HomePage 的 `Focus(autofocus: true, skipTraversal: true)`），焦点从 sink 出发。
// - 开了「键盘/手柄焦点导航」：Tab 能从首页 sink 走到「开始升级」，Enter 就开始迁移（MD3 与 Apple 两套）；
// - 没开（默认）：Tab 被全局中和成 DoNothingIntent（用户裁定 TODO-112），一步都不动——R0 itest 里「Tab 60 次
//   焦点停在首页外壳的无标签 Focus 上」就是这个，itest 没先开开关（BUG-1106 同根因），不是迁移页的缺陷。
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/focus/fushi_focus_controller.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/srs/srs_generation_view.dart';
import 'package:fushi/src/pages/implementations/srs/srs_load_error.dart';
import 'package:fushi/src/shortcuts/global_navigation.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/srs/srs_gen4_migration_controller.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_scope.dart';
import 'package:fushi_srs/fushi_srs.dart';
import 'package:material_ui/material_ui.dart';

import 'srs_gen4_migration_controller_test.dart' show FakeGen4Backend;

const SrsStoreNotMigrated _needs = SrsStoreNotMigrated(
  'x',
  SrsGenState.needsMigration,
);

/// 首页外壳那样的整页 sink 的节点：测试据此判断焦点还停在 sink 上。
final FocusNode _homeSink = FocusNode(debugLabel: 'test home sink');

Future<void> _pumpApp(
  WidgetTester tester, {
  required bool apple,
  required bool focusNavigationEnabled,
  required SrsGen4MigrationController controller,
}) async {
  LocaleSettings.setLocale(AppLocale.en);
  final GlobalKey<NavigatorState> navKey = GlobalKey<NavigatorState>();
  final FushiShortcutRegistry registry = FushiShortcutRegistry()
    ..loadDefaults(TargetPlatform.windows);
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[
        srsGen4IsMainProcessProvider.overrideWithValue(true),
        srsGen4MigrationProvider.overrideWithValue(controller),
      ],
      child: TranslationProvider(
        child: MaterialApp(
          navigatorKey: navKey,
          theme: buildFushiThemeData(
            scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
            textTheme: Typography.material2021().black,
            designSystem: apple
                ? FushiDesignSystem.cupertino
                : FushiDesignSystem.material,
            glass: FushiGlassMaterial.off,
            glassDesign: apple,
          ),
          builder: (BuildContext context, Widget? child) => FushiGlassScope(
            child: wrapWithGlobalNavigation(
              navigatorKey: navKey,
              focusNavigationEnabled: focusNavigationEnabled,
              registry: registry,
              child: FushiFocusRoot(
                enabled: focusNavigationEnabled,
                child: child!,
              ),
            ),
          ),
          home: Scaffold(
            body: Focus(
              focusNode: _homeSink,
              autofocus: true,
              skipTraversal: true,
              child: const SrsLoadErrorView(error: _needs, onRetry: null),
            ),
          ),
        ),
      ),
    ),
  );
  // 进场动画（有界 pump；不定进度条等可能一直在动，不用 pumpAndSettle）。
  for (int i = 0; i < 8; i++) {
    await tester.pump(const Duration(milliseconds: 250));
  }
}

/// 主焦点落在「开始升级」按钮上或它的子树里。
bool _focusOnStart() {
  final BuildContext? ctx = FocusManager.instance.primaryFocus?.context;
  final List<Element> start = find
      .byKey(SrsGenerationView.startKey)
      .evaluate()
      .toList();
  if (ctx == null || start.isEmpty) return false;
  if (identical(ctx, start.single)) return true;
  bool inside = false;
  (ctx as Element).visitAncestorElements((Element e) {
    if (identical(e, start.single)) {
      inside = true;
      return false;
    }
    return true;
  });
  return inside;
}

/// 按 Tab 直到焦点到「开始升级」，最多 [maxSteps] 步；返回实际按了几次（没到返回 -1）。
Future<int> _tabToStart(WidgetTester tester, {int maxSteps = 20}) async {
  for (int i = 0; i < maxSteps; i++) {
    if (_focusOnStart()) return i;
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump(const Duration(milliseconds: 60));
  }
  return _focusOnStart() ? maxSteps : -1;
}

SrsGen4MigrationController _controller(FakeGen4Backend b) =>
    SrsGen4MigrationController(
      directory: 'dir',
      profileUids: () async => <String>['p1'],
      onCommitted: () async {},
      backend: b,
      pollInterval: const Duration(milliseconds: 50),
      nowMs: () => 1,
    );

void main() {
  for (final bool apple in <bool>[false, true]) {
    final String design = apple ? 'Apple' : 'MD3';

    testWidgets('焦点导航开着：Tab 从首页 sink 走到「开始升级」，Enter 开始迁移（$design）', (
      WidgetTester tester,
    ) async {
      final FakeGen4Backend b = FakeGen4Backend();
      final SrsGen4MigrationController c = _controller(b);
      addTearDown(c.dispose);
      await _pumpApp(
        tester,
        apple: apple,
        focusNavigationEnabled: true,
        controller: c,
      );
      expect(find.byKey(SrsGenerationView.startKey), findsOneWidget);
      // 开了焦点导航时 FushiFocusRoot 会把焦点停到它的兜底节点上（与正式版同构），总之不在按钮上。
      expect(_focusOnStart(), isFalse, reason: '起点：焦点不在按钮上，要靠 Tab 走过去');

      final int steps = await _tabToStart(tester);
      expect(steps, greaterThan(0), reason: 'Tab 应把焦点从 sink 走到「开始升级」');
      expect(c.phase, SrsGen4MigrationPhase.idle);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 120));
      expect(c.phase, isNot(SrsGen4MigrationPhase.idle), reason: 'Enter 应开始迁移');
      expect(b.runs, hasLength(1));
      b.finish(<String, Object?>{'verdict': 'cancelled'});
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('焦点导航关着（默认）：Tab 被中和，焦点不离开首页 sink（$design）', (
      WidgetTester tester,
    ) async {
      final FakeGen4Backend b = FakeGen4Backend();
      final SrsGen4MigrationController c = _controller(b);
      addTearDown(c.dispose);
      await _pumpApp(
        tester,
        apple: apple,
        focusNavigationEnabled: false,
        controller: c,
      );
      expect(FocusManager.instance.primaryFocus, same(_homeSink));
      expect(await _tabToStart(tester, maxSteps: 10), -1);
      expect(FocusManager.instance.primaryFocus, same(_homeSink));
      expect(c.phase, SrsGen4MigrationPhase.idle);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
