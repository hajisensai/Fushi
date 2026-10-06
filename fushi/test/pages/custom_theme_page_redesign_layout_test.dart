import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/models.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/pages/implementations/custom_theme_page.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/utils.dart';
import 'package:fushi/src/utils/adaptive/legacy_design_compat.dart';

import '../helpers/test_platform_services.dart';

/// 自定义主题编辑页 2026-10 M3E 重设计（Apple 共用骨架）的布局契约：
/// - 窄屏：紧凑预览吸顶——不在编辑列表里、列表滚动时不被滚走；
/// - 宽屏：左栏 sticky 预览、右栏编辑列表（取色器按需弹出，不常驻）；
/// - hero 有名称、导入 / 分享 / 更多、预览明暗切换；AI 是独立紧凑卡；
///   主题色是一行种子色块，其余色槽是统一网格 tile；
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

  // 4c32e76e6e4：编辑页把「纯黑深色背景」开关计入配色缓存键。
  @override
  bool get pureBlackDark => false;

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
          // 与生产根同构：取色器（flutter_colorpicker）的 hex 输入框仍是 SDK 旧
          // Material TextField，靠根上的 LegacyDesignCompatibility（446e7b695a2）。
          builder: (BuildContext context, Widget? child) =>
              LegacyDesignCompatibility(child: child!),
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

    testWidgets('$ds · 窄屏 420×900：紧凑预览吸顶，滚动编辑列表时不被滚走', (
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
      // c981bcf1533：编辑列表铺满整页、内容滚到吸顶预览与浮动页头底下；
      // 预览按实测高度给列表让出顶部内边距——未滚动时第一张卡（页头卡）
      // 必须完整落在预览下方，不能一开页就被预览压住。
      final Finder header = find.byKey(
        const ValueKey<String>('custom-theme-header'),
      );
      final Rect before = tester.getRect(preview);
      expect(
        tester.getRect(header).top,
        greaterThanOrEqualTo(before.bottom),
        reason: '列表顶部内边距必须让开吸顶预览',
      );
      // 紧凑：不超过 420×900 视口高度的三分之一。
      expect(before.height, lessThan(900 / 3));

      final ScrollPosition editorPosition = tester
          .widget<SingleChildScrollView>(_editorList)
          .controller!
          .position;
      final double pixelsBefore = editorPosition.pixels;
      await tester.drag(_editorList, const Offset(0, -600));
      await tester.pumpAndSettle();
      expect(
        editorPosition.pixels,
        greaterThan(pixelsBefore),
        reason: '真实拖动必须滚动编辑列表，不能让吸顶预览拦截手势后原地假通过',
      );
      // 浮动页头随滚动收缩会让预览整体上移几像素，但它不随列表滚走、尺寸不变。
      final Rect after = tester.getRect(preview);
      expect(after.height, before.height);
      expect((after.top - before.top).abs(), lessThan(48));
      expect(preview, findsOneWidget);
    });

    testWidgets('$ds · 宽屏 1600×900：左栏 sticky 预览，右栏编辑列表', (
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

    testWidgets('$ds · hero（名称 + 导入 / 分享 / 更多 + 明暗）、AI 卡、色槽网格都在', (
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
        'custom-theme-more',
        'custom-theme-preview-brightness',
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
        find.byKey(const ValueKey<String>('custom-theme-tonal-palette')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey<String>('custom-theme-role-surface')),
        findsOneWidget,
      );
      // 界面背景与次要强调色两格在同一行（统一网格 tile，而不是一行一个）。
      expect(
        tester
            .getRect(
              find.byKey(const ValueKey<String>('custom-theme-role-surface')),
            )
            .top,
        tester
            .getRect(
              find.byKey(const ValueKey<String>('custom-theme-role-secondary')),
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
