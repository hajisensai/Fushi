import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/custom_theme_page.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';

import '../helpers/test_platform_services.dart';

/// 自定义主题编辑页 2026-10 重设计（M3 Expressive / Apple 两套）的布局契约：
/// - 窄屏：紧凑预览吸顶——不在编辑列表里、列表滚动时位置不变；
/// - 宽屏：左栏预览 + 选色器、右栏编辑列表；
/// - 页头卡有名称框与导入 / 分享；AI 是独立卡片；颜色角色是色板格子；
/// - 编辑列表首屏错峰进场（FushiEntranceScope + FushiStaggeredEntrance）。
class _FakeAppModel extends AppModel {
  _FakeAppModel() : super(testPlatformServices());

  @override
  List<CustomThemeEntry> get customThemes => const <CustomThemeEntry>[];

  @override
  CustomThemeEntry? customThemeById(String id) => null;

  @override
  Future<void> setAudioHighlightColor(Color? color) async {}

  @override
  Color? get audioHighlightColor => null;

  @override
  String get brightnessMode => 'light';

  @override
  bool get isDarkMode => false;

  @override
  bool get einkMode => false;

  @override
  Color? get systemPrimaryColor => null;
}

Future<void> _pumpPage(
  WidgetTester tester, {
  required Size size,
  required bool apple,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final ThemeData theme = buildFushiThemeData(
    scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
    textTheme: Typography.material2021().black,
    glass: apple ? FushiGlassMaterial.liquid : FushiGlassMaterial.off,
    glassDesign: apple,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: <Override>[appProvider.overrideWith((ref) => _FakeAppModel())],
      child: TranslationProvider(
        child: MaterialApp(
          theme: theme,
          themeAnimationDuration: Duration.zero,
          home: const FushiGlassScope(child: CustomThemePage()),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Finder get _editorList =>
    find.byKey(const ValueKey<String>('custom-theme-editor-list'));

void main() {
  for (final bool apple in <bool>[false, true]) {
    final String ds = apple ? 'Apple' : 'MD3';

    testWidgets('$ds · 窄屏 420×900：紧凑预览吸顶，滚动编辑列表时位置不变', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester, size: const Size(420, 900), apple: apple);

      final Finder preview = find.byKey(
        const ValueKey<String>('custom-theme-preview-compact'),
      );
      expect(preview, findsOneWidget);
      expect(
        find.byKey(const ValueKey<String>('custom-theme-preview')),
        findsNothing,
      );
      expect(
        find.descendant(of: _editorList, matching: preview),
        findsNothing,
        reason: '预览不能在可滚动的编辑列表里，否则一滚就看不见改色效果',
      );
      final Rect before = tester.getRect(preview);
      expect(before.bottom, lessThanOrEqualTo(tester.getRect(_editorList).top));
      // 紧凑：不超过 420×900 视口高度的三分之一。
      expect(before.height, lessThan(900 / 3));

      await tester.drag(_editorList, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(tester.getRect(preview), before);
    });

    testWidgets('$ds · 宽屏 1600×900：左栏预览 + 选色器，右栏编辑列表', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester, size: const Size(1600, 900), apple: apple);

      final Finder preview = find.byKey(
        const ValueKey<String>('custom-theme-preview'),
      );
      expect(preview, findsOneWidget);
      final Rect previewRect = tester.getRect(preview);
      final Rect listRect = tester.getRect(_editorList);
      expect(previewRect.right, lessThanOrEqualTo(listRect.left + 1));
      expect(previewRect.left, lessThan(listRect.left));
      expect(listRect.width, greaterThan(previewRect.width));
    });

    testWidgets('$ds · 页头卡（名称 + 导入 / 分享）、AI 卡、色板格子都在', (
      WidgetTester tester,
    ) async {
      await _pumpPage(tester, size: const Size(1600, 900), apple: apple);

      final Finder header = find.byKey(
        const ValueKey<String>('custom-theme-header'),
      );
      expect(header, findsOneWidget);
      for (final String key in <String>[
        'custom-theme-name',
        'custom-theme-import',
        'custom-theme-share',
      ]) {
        expect(
          find.descendant(
            of: header,
            matching: find.byKey(ValueKey<String>(key)),
          ),
          findsOneWidget,
          reason: '$key 应在页头卡里',
        );
      }
      final Finder ai = find.byKey(
        const ValueKey<String>('custom-theme-ai-card'),
      );
      expect(ai, findsOneWidget);
      expect(
        find.descendant(
          of: ai,
          matching: find.byKey(
            const ValueKey<String>('custom-theme-ai-request'),
          ),
        ),
        findsOneWidget,
      );
      // 页头在 AI 卡上面。
      expect(
        tester.getRect(header).bottom,
        lessThanOrEqualTo(tester.getRect(ai).top),
      );
      expect(
        find.byKey(const ValueKey<String>('custom-theme-role-accent')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('custom-theme-role-surface')),
        findsOneWidget,
      );
      // 主题色与界面背景两格在同一行（色板网格，而不是一行一个的长列表）。
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('custom-theme-role-accent')),
            )
            .top,
        tester
            .getRect(
              find.byKey(const ValueKey<String>('custom-theme-role-surface')),
            )
            .top,
      );
    });

    testWidgets('$ds · 编辑列表在进场窗口内错峰进场', (WidgetTester tester) async {
      await _pumpPage(tester, size: const Size(420, 900), apple: apple);
      expect(
        find.ancestor(
          of: _editorList,
          matching: find.byType(FushiEntranceScope),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: _editorList,
          matching: find.byType(FushiStaggeredEntrance),
        ),
        findsWidgets,
      );
    });
  }
}
