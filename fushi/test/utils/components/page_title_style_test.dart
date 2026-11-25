// 页面大标题样式三项（拍板台 DN2p82rNPg：字号比例 / 粗细 / 颜色）的生效链：
// 偏好 → ThemeNotifier → [FushiShellTheme.pageTitle] → MD3 页头大字
// （fushiMastheadTitleStyle / FushiPageTitleMetrics.titleScaleOf）与 Apple 大标题
// （fushiAppleNavTitleStyle、页头几何的收起比例）。设置页 harness 里没有外壳页头，
// effect 由本文件咬住（settings_schema_coverage 的 kCoveredElsewhere 指到这里）。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/theme_notifier.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show FushiGlassMaterial;
import 'package:fushi/src/utils/adaptive/shell_style.dart';
import 'package:fushi/src/utils/components/fushi_page_masthead.dart';
import 'package:fushi/src/utils/components/fushi_page_title_metrics.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:material_ui/material_ui.dart';

ThemeData _theme({
  required bool apple,
  FushiPageTitleStyle pageTitle = const FushiPageTitleStyle(),
}) => buildFushiThemeData(
  scheme: ColorScheme.fromSeed(seedColor: Colors.teal),
  textTheme: Typography.material2021().black,
  glass: FushiGlassMaterial.off,
  glassDesign: apple,
  shell: FushiShellTheme(pageTitle: pageTitle),
);

/// 在手机尺寸（compact）下按 [theme] 取一个 context 交给 [read]。
Future<T> _read<T>(
  WidgetTester tester,
  ThemeData theme,
  T Function(BuildContext context) read,
) async {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  late T result;
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      home: Builder(
        builder: (BuildContext context) {
          result = read(context);
          return const SizedBox.shrink();
        },
      ),
    ),
  );
  // 同一测试里换主题时 MaterialApp 走主题过渡（AnimatedTheme）：等过渡走完再读。
  await tester.pumpAndSettle();
  return result;
}

void main() {
  group('偏好 → 主题扩展', () {
    late FushiDatabase database;
    late ThemeNotifier notifier;

    setUp(() {
      database = FushiDatabase.forTesting(NativeDatabase.memory());
      notifier = ThemeNotifier(database, () => const TextTheme())
        ..loadFromPrefsSnapshot(<String, String>{
          'design_system': PrefCodec.encode('material'),
          'brightness_mode': PrefCodec.encode('light'),
        });
    });

    tearDown(() async {
      notifier.dispose();
      await database.close();
    });

    FushiPageTitleStyle titleOfTheme() =>
        notifier.theme.extension<FushiShellTheme>()!.pageTitle;

    test('出厂：比例 1、粗细没选过、正文色', () {
      expect(titleOfTheme(), const FushiPageTitleStyle());
      expect(titleOfTheme().weight, isNull);
      expect(titleOfTheme().color, PageTitleColor.body);
    });

    test('三项改了主题扩展跟着变，字号越界夹到范围内', () async {
      await notifier.setPageTitleFontScale(0.8);
      await notifier.setPageTitleWeight(PageTitleWeight.regular);
      await notifier.setPageTitleColor(PageTitleColor.accent);
      expect(
        titleOfTheme(),
        const FushiPageTitleStyle(
          fontScale: 0.8,
          weight: PageTitleWeight.regular,
          color: PageTitleColor.accent,
        ),
      );

      await notifier.setPageTitleFontScale(5);
      expect(titleOfTheme().fontScale, FushiPageTitleStyle.maxFontScale);
      await notifier.setPageTitleFontScale(0.1);
      expect(titleOfTheme().fontScale, FushiPageTitleStyle.minFontScale);
    });

    test('粗细清掉回到没选过（跟出厂字重走）', () async {
      await notifier.setPageTitleWeight(PageTitleWeight.bold);
      expect(notifier.hasStoredPageTitleWeight, isTrue);
      await notifier.setPageTitleWeight(null);
      expect(notifier.pageTitleWeight, isNull);
      expect(titleOfTheme().weight, isNull);
    });

    test('三个偏好键随 Profile 走', () {
      expect(
        ThemeNotifier.isProfileThemePrefKey(
          ThemeNotifier.pageTitleFontScalePrefKey,
        ),
        isTrue,
      );
      expect(
        ThemeNotifier.isProfileThemePrefKey(
          ThemeNotifier.pageTitleWeightPrefKey,
        ),
        isTrue,
      );
      expect(
        ThemeNotifier.isProfileThemePrefKey(
          ThemeNotifier.pageTitleColorPrefKey,
        ),
        isTrue,
      );
    });
  });

  group('MD3 页头大字', () {
    testWidgets('出厂：手机 46 / w900 / 正文色，字阶与改前一致', (WidgetTester tester) async {
      final ThemeData theme = _theme(apple: false);
      final ({TextStyle style, Color ink}) r = await _read(
        tester,
        theme,
        (BuildContext context) => (
          style: fushiMastheadTitleStyle(context, compact: true),
          ink: fushiMastheadPaletteOf(context).ink,
        ),
      );
      expect(r.style.fontSize, 46);
      expect(r.style.fontWeight, FontWeight.w900);
      expect(r.style.color, r.ink);
    });

    testWidgets('比例 / 粗细 / 强调色：展开与收起一起缩，收缩比例不变', (WidgetTester tester) async {
      final ThemeData theme = _theme(
        apple: false,
        pageTitle: const FushiPageTitleStyle(
          fontScale: 0.7,
          weight: PageTitleWeight.bold,
          color: PageTitleColor.accent,
        ),
      );
      final ({
        TextStyle page,
        TextStyle section,
        FushiPageTitleScale scale,
        Color strong,
      })
      r = await _read(
        tester,
        theme,
        (BuildContext context) => (
          page: fushiMastheadTitleStyle(context, compact: true),
          section: fushiMastheadTitleStyle(
            context,
            compact: true,
            tier: FushiPageTitleTier.section,
          ),
          scale: FushiPageTitleMetrics.titleScaleOf(context, compact: true),
          strong: fushiMastheadPaletteOf(context).strong,
        ),
      );
      expect(r.page.fontSize, closeTo(46 * 0.7, 1e-9));
      expect(r.page.fontWeight, FontWeight.w700);
      expect(r.page.color, r.strong);
      expect(r.section.fontSize, closeTo(34 * 0.7, 1e-9));
      expect(r.scale.collapsedFontSize, closeTo(28 * 0.7, 1e-9));
      expect(
        r.scale.collapsedFontSize / r.scale.fontSize,
        closeTo(28 / 46, 1e-9),
      );
    });

    testWidgets('没选粗细时各档保留自己的出厂字重（设置分类页 w700）', (WidgetTester tester) async {
      final ThemeData theme = _theme(
        apple: false,
        pageTitle: const FushiPageTitleStyle(fontScale: 0.8),
      );
      final TextStyle section = await _read(
        tester,
        theme,
        (BuildContext context) => fushiMastheadTitleStyle(
          context,
          compact: true,
          tier: FushiPageTitleTier.section,
        ),
      );
      expect(section.fontWeight, FontWeight.w700);
    });
  });

  group('Apple 大标题', () {
    testWidgets('出厂 34 / w700 / label 色；调过后跟着变', (WidgetTester tester) async {
      final TextStyle stock = await _read(
        tester,
        _theme(apple: true),
        (BuildContext context) =>
            fushiAppleNavTitleStyle(context, compact: true),
      );
      expect(stock.fontSize, 34);
      expect(stock.fontWeight, FontWeight.w700);

      final ({TextStyle style, Color strong}) r = await _read(
        tester,
        _theme(
          apple: true,
          pageTitle: const FushiPageTitleStyle(
            fontScale: 0.75,
            weight: PageTitleWeight.heavy,
            color: PageTitleColor.accent,
          ),
        ),
        (BuildContext context) => (
          style: fushiAppleNavTitleStyle(context, compact: true),
          strong: fushiMastheadPaletteOf(context).strong,
        ),
      );
      expect(r.style.fontSize, closeTo(34 * 0.75, 1e-9));
      expect(r.style.fontWeight, FontWeight.w900);
      expect(r.style.color, r.strong);
    });

    test('收起态小标题恒为 17pt：缩放终点按调过的大标题字号算', () {
      FushiMastheadGeometry geometry(double font) => FushiMastheadGeometry(
        compact: true,
        width: 390,
        leading: Size.zero,
        title: const Size(120, 41),
        titleBaseline: 8,
        badge: Size.zero,
        switcher: Size.zero,
        switchBaseline: 0,
        actions: Size.zero,
        primary: Size.zero,
        secondary: Size.zero,
        apple: true,
        appleTitleFontSize: font,
      );
      expect(geometry(34).titleScaleAt(1), closeTo(17 / 34, 1e-9));
      expect(
        geometry(34 * 0.6).titleScaleAt(1),
        closeTo(17 / (34 * 0.6), 1e-9),
      );
      // 大标题调到比 17 还小也不放大回去。
      expect(geometry(15).titleScaleAt(1), 1);
    });
  });

  test('主题过渡：字号比例连续插值，粗细 / 颜色过半切换', () {
    final ThemeData a = _theme(apple: false);
    final ThemeData b = _theme(
      apple: false,
      pageTitle: const FushiPageTitleStyle(
        fontScale: 0.6,
        weight: PageTitleWeight.regular,
        color: PageTitleColor.accent,
      ),
    );
    final FushiPageTitleStyle mid = ThemeData.lerp(
      a,
      b,
      0.25,
    ).extension<FushiShellTheme>()!.pageTitle;
    expect(mid.fontScale, closeTo(0.9, 1e-9));
    expect(mid.weight, isNull);
    expect(mid.color, PageTitleColor.body);
  });
}
